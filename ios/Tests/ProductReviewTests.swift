import CoreBluetooth
import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import EncounterUI
import Foundation
import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import EngineerEncounters

@MainActor
final class ProductReviewTests: XCTestCase {
    func testDiscoverStatesAndSessionRoutesFollowTheContracts() {
        XCTAssertEqual(ProductDiscoverState.bluetoothStatus(permission: .notRequested, requested: false), .failed)
        XCTAssertEqual(ProductDiscoverState.bluetoothStatus(permission: .notRequested, requested: true), .checking)
        for permission in [BluetoothPermissionState.poweredOff, .denied, .unavailable] {
            let bluetooth = ProductDiscoverState.bluetoothStatus(permission: permission, requested: true)
            let state = ProductDiscoverState.select(discoveryOn: true, isAuthorized: true, state: .loaded,
                hasCards: true, bluetooth: bluetooth, isNewUser: true, sampleDismissed: false)
            XCTAssertEqual(state.feed, .cards)
            XCTAssertEqual(state.bluetooth, .unavailable(bluetooth))
            XCTAssertFalse(state.showsSample)
            XCTAssertEqual(ProductDiscoverState.sessionRoute(discoveryOn: true, sessionActive: false, bluetooth: bluetooth), .bluetooth)
            XCTAssertEqual(ProductDiscoverState.sessionRoute(discoveryOn: true, sessionActive: true, bluetooth: bluetooth), .session)
        }
        XCTAssertNil(ProductDiscoverState.sessionRoute(discoveryOn: false, sessionActive: false, bluetooth: .available))
        for isNew in [false, true] {
            let off = ProductDiscoverState.select(discoveryOn: false, isAuthorized: true, state: .loaded,
                hasCards: true, bluetooth: .denied, isNewUser: isNew, sampleDismissed: false)
            XCTAssertEqual(off.feed, .discoveryOff)
            XCTAssertEqual(off.bluetooth, .hidden)
            XCTAssertEqual(off.showsSample, isNew)
        }
        for load in [DiscoverLoadState.idle, .loading, .failed, .loaded] {
            let state = ProductDiscoverState.select(discoveryOn: true, isAuthorized: true, state: load,
                hasCards: false, bluetooth: .available, isNewUser: false, sampleDismissed: false)
            XCTAssertEqual(state.feed, load == .loaded ? .empty : load == .failed ? .failure : .loading)
            XCTAssertEqual(state.showsSample, load == .loaded || load == .failed)
        }
    }

    func testRecoveryDestinationAndItsOriginAndNeverStartedRadioAction() async throws {
        let transport = productTransport([:])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let settings = reviewSettings(composition)
        let presentation = ProductPresentationModel(composition: composition, settings: settings, bluetoothAuthorization: { .notDetermined })
        XCTAssertNotEqual(presentation.bluetooth, .checking)
        presentation.discoverNavigation(.discover).openSession()
        XCTAssertEqual(composition.productNavigation.discover, [.bluetooth])
        let starts = await transport.count("start_session")
        XCTAssertEqual(starts, 0)
        await presentation.retryBluetooth(in: .discover)
        XCTAssertTrue(presentation.requiresBluetoothCheck)
        XCTAssertFalse(composition.runtime?.hasRequestedBluetooth == true) // A foreground recheck cannot prompt.
        await presentation.requestBluetooth(in: .discover)
        XCTAssertTrue(composition.runtime?.hasRequestedBluetooth == true)
        composition.productNavigation.bluetoothRecovered(in: .discover)
        XCTAssertEqual(composition.productNavigation.discover, [.session])
        composition.productNavigation.reset()
        presentation.settingsNavigation(.settings).bluetoothRecovery()
        XCTAssertEqual(composition.productNavigation.settings, [.bluetooth])
        composition.productNavigation.bluetoothRecovered(in: .settings)
        XCTAssertTrue(composition.productNavigation.settings.isEmpty)
        settings.receive(profile: appLinkedPresentationProfile(), bluetooth: .available)
        var off = settings.profile; off.discoveryOn = false
        settings.receive(profile: off)
        composition.account.publishProfile(off, stale: false)
        presentation.discoverNavigation(.discover).openSession()
        XCTAssertTrue(composition.productNavigation.discover.isEmpty)
        presentation.discoverNavigation(.discover).openQR()
        XCTAssertTrue(composition.productNavigation.discover.isEmpty)
    }

    func testS24RetryRereadsOwnProfileAndRestoresEnableGuidance() async throws {
        var off = appLinkedPresentationProfile(); off.discoveryOn = false
        let transport = productTransport(["get_own_profile": [.failure, .response(appOwnProfileResponse(off))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration()
        composition.account.publishProfile(off, stale: true)
        let settings = reviewSettings(composition)
        let presentation = ProductPresentationModel(composition: composition, settings: settings, bluetoothAuthorization: { .notDetermined })
        XCTAssertEqual(presentation.ownState, .failed)
        await presentation.retryOwnState()
        XCTAssertEqual(presentation.ownState, .failed)
        await presentation.retryOwnState()
        XCTAssertEqual(presentation.ownState, .loaded)
        XCTAssertFalse(settings.profile.discoveryOn)
        XCTAssertEqual(DiscoverPrerequisiteContent.select(state: presentation.ownState, prerequisites: settings.profile.prerequisites),
            .guidance(editProfile: false, editLinks: false))
        let count = await transport.count("get_own_profile")
        XCTAssertEqual(count, 2)
    }

    func testSampleUsesHistoryBeforeFinishingThisVisitAndKeepsDismissal() async throws {
        let composition = try productComposition(productTransport([:]))
        await composition.waitForRestoration()
        composition.configureSample(for: appBackendTestUser, completedOnboarding: false)
        XCTAssertTrue(composition.sampleEncounter.isVisible(in: .discoveryOff))
        composition.configureSample(for: appBackendTestUser, completedOnboarding: true)
        XCTAssertTrue(composition.sampleEncounter.isVisible(in: .discoveryOff)) // Not now completed this first visit.
        composition.configureSample(for: UUID(), completedOnboarding: true)
        XCTAssertFalse(composition.sampleEncounter.isVisible(in: .discoveryOff))
        XCTAssertTrue(composition.sampleEncounter.isVisible(in: .emptyFeed))
        composition.sampleEncounter.dismiss()
        composition.configureSample(for: UUID(), completedOnboarding: false)
        XCTAssertFalse(composition.sampleEncounter.isVisible(in: .discoveryOff))
    }

    func testCataloguePrecedesFeedAndRefillsAfterInvalidation() async throws {
        let transport = productTransport(["list_interests": [.response(reviewCatalogue()), .response(reviewCatalogue())],
            "get_encounter_feed": [.response(productFeed()), .response(productFeed())]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        var model = try XCTUnwrap(composition.discoverAdapter.model)
        await model.loadFeed()
        XCTAssertEqual(model.feed.first?.card.interests.first?.labelEnglish, "Swift development")
        let paths = await transport.recorded().compactMap { $0.url?.lastPathComponent }
        XCTAssertLessThan(try XCTUnwrap(paths.firstIndex(of: "list_interests")), try XCTUnwrap(paths.firstIndex(of: "get_encounter_feed")))
        let services = try XCTUnwrap(composition.sessionServices)
        composition.discoverAdapter.invalidate()
        composition.discoverAdapter.configure(services)
        model = try XCTUnwrap(composition.discoverAdapter.model)
        await model.loadFeed()
        XCTAssertEqual(model.feed.first?.card.interests.first?.labelJapanese, "Swift開発")
        let count = await transport.count("list_interests")
        XCTAssertEqual(count, 2)
    }

    func testCardArrivingBeforeCatalogueOmitsIdentifiersAndRelabelsWhenItLoads() async throws {
        let transport = productTransport(["list_interests": [.failure],
            "get_encounter_feed": [.response(productFeed()), .response(productFeed())]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let model = try XCTUnwrap(composition.discoverAdapter.model)
        await model.loadFeed()
        XCTAssertTrue(try XCTUnwrap(model.feed.first).card.interests.isEmpty)
        composition.discoverAdapter.interests = reviewInterests
        try await appBackendEventually { model.feed.first?.card.interests == reviewInterests }
    }

    func testMalformedLinkIsDroppedAcrossFeedFavoritesAndSavedLinks() async throws {
        var broken = productLink(); broken["url"] = "https://%"
        broken["link_id"] = "00000000-0000-0000-0000-000000000123"
        var card = productCard(); card["links"] = [broken, productLink()]
        let feed = productResponse(["cards": [card], "truncated": false])
        let transport = productTransport(["get_encounter_feed": [.response(feed)], "list_encounter_favorites": [.response(feed)],
            "list_saved_links": [.response(productResponse(["links": [
                ["encounter_id": productEncounterID, "day": "2026-10-13", "kind": "session", "link": broken],
                ["encounter_id": productEncounterID, "day": "2026-10-13", "kind": "session", "link": productLink()]], "truncated": true]))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        composition.discoverAdapter.interests = reviewInterests
        let actions = composition.discoverAdapter.actions()
        let loaded = try await actions.loadFeed()
        let favorites = try await actions.loadFavorites()
        let saved = try await actions.loadSavedLinks()
        XCTAssertEqual(loaded.cards.first?.card.links.map(\.id), [productLinkID])
        XCTAssertEqual(favorites.cards.first?.card.links.map(\.id), [productLinkID])
        XCTAssertEqual(saved.links.map(\.link.id), [productLinkID])
        XCTAssertTrue(saved.truncated)
    }

    func testSessionAndQRAuthFailuresPermitRetryOfAllRequestedDiscoverScreens() async throws {
        for operation in ["start_session", "issue_qr_code"] {
            for code in ["account_not_ready", "declaration_required"] {
                let transport = productTransport([operation: [.response(productError(code))],
                    "get_own_profile": [.response(appOwnProfileResponse(reviewEnabledProfile()))],
                    "get_encounter_feed": [.response(productFeed()), .response(productFeed())],
                    "get_encounter_card": [.response(productResponse(productCard(detail: true))), .response(productResponse(productCard(detail: true)))],
                    "list_encounter_favorites": [.response(productFeed()), .response(productFeed())]])
                let composition = try productComposition(transport)
                await composition.waitForRestoration(); productAuthorize(composition)
                composition.discoverAdapter.interests = reviewInterests
                let model = try XCTUnwrap(composition.discoverAdapter.model)
                await model.loadFeed(); await model.loadCard(productEncounterID); await model.loadFavorites()
                do {
                    if operation == "start_session" { _ = try await composition.sessionAdapter.actions().startSession() }
                    else { _ = try await composition.qrAdapter.actions().issueCode() }
                    XCTFail("Expected authorization failure")
                } catch { }
                XCTAssertTrue(composition.discoverAdapter.needsAuthorizationRetry)
                XCTAssertFalse(model.isAuthorized)
                XCTAssertTrue(model.feed.isEmpty); XCTAssertNil(model.card); XCTAssertTrue(model.favorites.isEmpty)
                XCTAssertTrue(composition.account.state.isSignedIn)
                await composition.discoverAdapter.retryAuthorization()
                try await appBackendEventually { model.feedState == .loaded && model.detailState == .loaded && model.favoritesState == .loaded }
                XCTAssertFalse(composition.discoverAdapter.needsAuthorizationRetry)
                XCTAssertEqual(model.card?.card.id, productEncounterID)
            }
        }
    }

    func testShowingPhoneAdapterOpensNewQRAndClearsTheOutstandingCode() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        var old = productCard(); old["kind"] = "qr"
        old["day"] = reviewToday()
        old["encounter_id"] = "00000000-0000-0000-0000-000000000123"
        var new = productCard(); new["kind"] = "qr"
        new["day"] = reviewToday()
        let transport = productTransport([
            "get_encounter_feed": [.response(productResponse(["cards": [old], "truncated": false])),
                .response(productResponse(["cards": [new, old], "truncated": false]))],
            "issue_qr_code": [.response(productResponse(["code": String(repeating: "a", count: 32), "expires_at": 1120]))],
            "cancel_qr_code": [.response(productResponse(["cancelled": true]))]])
        let composition = try productComposition(transport, clock: clock, confirmationScheduler: scheduler,
            lifecycle: ProductSceneLifecycle(phase: .active, notifications: NotificationCenter()))
        await composition.waitForRestoration(); productAuthorize(composition)
        composition.discoverAdapter.interests = reviewInterests
        composition.productNavigation.push(.qr, in: .discover)
        let presentation = ProductPresentationModel(composition: composition, settings: reviewSettings(composition))
        let model = composition.qrAdapter.makeModel(navigation: presentation.qrNavigation(.discover))
        await composition.confirmationPoller.openQR(model)
        await model.appear()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        await clock.advance(by: 5)
        await scheduler.jobs[0].operation()
        XCTAssertEqual(composition.productNavigation.discover, [.encounter(productEncounterID)])
        XCTAssertTrue(model.hasConfirmed)
        XCTAssertNil(model.code)
        try await appBackendEventually { await transport.count("cancel_qr_code") == 1 }
        composition.confirmationPoller.closeQR(model)
    }

    func testHeldCatalogueAndAuthorizationRetryCannotRepopulateAfterSignOut() async throws {
        for resource in ["list_interests", "get_own_profile"] {
            let transport = productTransport([resource: [.held]])
            let composition = try productComposition(transport)
            await composition.waitForRestoration(); productAuthorize(composition)
            let model = try XCTUnwrap(composition.discoverAdapter.model)
            let loading: Task<Void, Never>
            if resource == "list_interests" { loading = Task { await model.loadFeed() } }
            else {
                composition.discoverAdapter.rejectAuthorization()
                loading = Task { await composition.discoverAdapter.retryAuthorization() }
            }
            try await appBackendEventually { await transport.isHeld(resource) }
            try await composition.account.signOut()
            await transport.release(resource, with: resource == "list_interests" ? reviewCatalogue() : appOwnProfileResponse(reviewEnabledProfile()))
            await loading.value
            XCTAssertNil(composition.discoverAdapter.model)
            XCTAssertTrue(composition.discoverAdapter.interests.isEmpty)
            XCTAssertTrue(model.feed.isEmpty)
            XCTAssertNil(composition.discoverAdapter.failure)
            XCTAssertFalse(composition.discoverAdapter.needsAuthorizationRetry)
            let feeds = await transport.count("get_encounter_feed")
            XCTAssertEqual(feeds, 0)
        }
    }

    func testRedemptionDoesNotWaitForFeedRead() async throws {
        let transport = productTransport(["get_encounter_feed": [.response(productFeed()), .held],
            "redeem_qr_code": [.response(productResponse(["encounter_id": productEncounterID]))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        composition.discoverAdapter.interests = reviewInterests
        await composition.discoverAdapter.model?.loadFeed()
        let id = try await composition.qrAdapter.actions().redeemCode(QRPayload(token: String(repeating: "b", count: 32))!)
        XCTAssertEqual(id, productEncounterID)
        try await appBackendEventually { await transport.isHeld("get_encounter_feed") }
        await transport.release("get_encounter_feed", with: productFeed())
    }

    func testCompositionPollsSessionCardsAndReloadsAfterResolvedReceipts() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        let lifecycle = ProductSceneLifecycle(phase: .active, notifications: NotificationCenter())
        let empty = productResponse(["cards": [], "truncated": false])
        let queue = InMemoryReceiptQueue()
        let receipt = appBackendFinalReceipt()
        let resolved = HTTPResponse(data: try JSONEncoder().encode([ReceiptStatusTransfer(id: receipt.id, status: .resolved)]), statusCode: 200)
        let transport = productTransport(["get_encounter_feed": [.response(empty), .response(productFeed()), .response(productFeed())],
            "submit_receipts": [.response(resolved)]])
        let composition = try productComposition(transport, clock: clock, confirmationScheduler: scheduler, lifecycle: lifecycle, queue: queue)
        await composition.waitForRestoration(); productAuthorize(composition)
        composition.discoverAdapter.interests = reviewInterests
        let model = try XCTUnwrap(composition.discoverAdapter.model)
        composition.confirmationPoller.receive(sessionActive: true)
        await composition.confirmationPoller.openSession()
        XCTAssertTrue(model.feed.isEmpty)
        try await appBackendEventually { scheduler.jobs.count == 1 }
        await clock.advance(by: 5)
        await scheduler.jobs[0].operation()
        XCTAssertEqual(model.feed.first?.card.kind, .session)
        try await queue.enqueue(receipt)
        await composition.runtime?.refresh()
        await composition.runtime?.uploadTask?.value
        try await appBackendEventually { scheduler.jobs.count >= 2 }
        await clock.advance(by: 5)
        try await appBackendEventually { scheduler.jobs.last?.cancelled == false }
        await scheduler.jobs.last?.operation()
        try await appBackendEventually { await transport.count("get_encounter_feed") == 3 }
        composition.confirmationPoller.closeSession()
        await composition.runtime?.receiptsDidResolve()
        let count = await transport.count("get_encounter_feed")
        XCTAssertEqual(count, 3)
    }

    func testQRScreenTabRoundTripRegistersPollingAndCancelsBothCodesOnLeaving() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        let empty = productResponse(["cards": [], "truncated": false])
        var card = productCard(); card["kind"] = "qr"; card["day"] = reviewToday()
        let transport = productTransport([
            "get_encounter_feed": [.response(empty), .response(empty),
                .response(productResponse(["cards": [card], "truncated": false]))],
            "issue_qr_code": [.response(productResponse(["code": String(repeating: "a", count: 32), "expires_at": 1120])),
                .response(productResponse(["code": String(repeating: "b", count: 32), "expires_at": 1125]))],
            "cancel_qr_code": [.response(productResponse(["cancelled": true])), .response(productResponse(["cancelled": true]))]])
        let lifecycle = ProductSceneLifecycle(phase: .active, notifications: NotificationCenter())
        let composition = try productComposition(transport, defaults: appBackendDefaults(defaults: AppInMemoryDefaults()),
            clock: clock, confirmationScheduler: scheduler, lifecycle: lifecycle)
        await composition.waitForRestoration(); productAuthorize(composition)
        composition.discoverAdapter.interests = reviewInterests
        let navigation = ProductNavigationModel()
        var opened: [String] = []
        let qrNavigation = QRNavigationActions(openEncounter: { opened.append($0) }, openIOSSettings: {}, close: {}, openDiscoveryOff: {})
        let container = ProductTabContainer(navigation: navigation, lifecycle: lifecycle,
            discover: ProductQRView(adapter: composition.qrAdapter, poller: composition.confirmationPoller, navigation: qrNavigation),
            profile: Text("Profile"), settings: Text("Settings"))
        let host = UIHostingController(rootView: container)
        let scene = try appBackendWindowScene()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await appBackendEventually {
            reviewPump(window)
            return await transport.count("issue_qr_code") == 1 && scheduler.jobs.count == 1
        }
        navigation.select(.profile)
        try await appBackendEventually {
            reviewPump(window)
            return await transport.count("cancel_qr_code") == 1 && scheduler.jobs[0].cancelled
        }
        await clock.advance(by: 5)
        navigation.select(.discover)
        try await appBackendEventually {
            reviewPump(window)
            return await transport.count("issue_qr_code") == 2 && scheduler.jobs.count == 2
        }
        await clock.advance(by: 5)
        await scheduler.jobs[1].operation()
        XCTAssertEqual(opened, [productEncounterID])
        try await appBackendEventually { await transport.count("cancel_qr_code") == 2 }
    }

    func testResumedDeletionReauthorizesSessionAndQRLoadsAndPolling() async throws {
        for qr in [false, true] {
            let clock = ManualEncounterClock()
            let scheduler = ManualReceiptUploadScheduler()
            let empty = productResponse(["cards": [], "truncated": false])
            let transport = productTransport([
                "delete_own_account": [.failure],
                "get_own_profile": [.response(appOwnProfileResponse(reviewEnabledProfile()))],
                "get_encounter_feed": [.response(empty), .response(empty)],
                "start_session": [.response(productResponse(["session_id": UUID().uuidString.lowercased(),
                    "starts_at": 1000, "expires_at": 8200, "server_time": 1000]))],
                "issue_qr_code": [.response(productResponse(["code": String(repeating: "a", count: 32), "expires_at": 1120]))],
                "cancel_qr_code": [.response(productResponse(["cancelled": true]))]])
            let composition = try productComposition(transport, defaults: appBackendDefaults(defaults: AppInMemoryDefaults()),
                clock: clock, confirmationScheduler: scheduler,
                lifecycle: ProductSceneLifecycle(phase: .active, notifications: NotificationCenter()))
            await composition.waitForRestoration(); productAuthorize(composition)
            await composition.retryAccountDeletion()
            XCTAssertTrue(composition.deletionSuspended)
            await composition.checkAccountAndResume()
            XCTAssertFalse(composition.deletionSuspended)
            XCTAssertTrue(composition.account.state.isSignedIn)
            composition.discoverAdapter.interests = reviewInterests
            var qrModel: QRModel?
            if qr {
                let model = composition.qrAdapter.makeModel(navigation: .init(openEncounter: { _ in },
                    openIOSSettings: {}, close: {}, openDiscoveryOff: {}))
                qrModel = model
                await composition.confirmationPoller.openQR(model); await model.appear()
                XCTAssertNotNil(model.code)
            } else {
                _ = try await composition.sessionAdapter.actions().startSession()
                await Task.yield()
                await composition.confirmationPoller.openSession()
            }
            let loaded = await transport.count("get_encounter_feed")
            XCTAssertEqual(loaded, 1)
            try await appBackendEventually { scheduler.jobs.count == 1 }
            await clock.advance(by: 5)
            await scheduler.jobs[0].operation()
            let polled = await transport.count("get_encounter_feed")
            XCTAssertEqual(polled, 2)
            if let qrModel { composition.confirmationPoller.closeQR(qrModel); qrModel.disappear() }
            else { composition.confirmationPoller.closeSession() }
        }
    }

    func testLifecycleTransitionsReachScreensInAllTabHostingControllers() async throws {
        let notifications = NotificationCenter()
        let lifecycle = ProductSceneLifecycle(phase: .active, notifications: notifications)
        let navigation = ProductNavigationModel()
        var phases: [ProductTab: ScenePhase] = [:]
        let container = ProductTabContainer(navigation: navigation, lifecycle: lifecycle,
            discover: ReviewPhaseProbe { phases[.discover] = $0 }, profile: ReviewPhaseProbe { phases[.profile] = $0 },
            settings: ReviewPhaseProbe { phases[.settings] = $0 })
        let host = UIHostingController(rootView: container)
        let scene = try appBackendWindowScene()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for tab in [ProductTab.discover, .profile, .settings] {
            navigation.select(tab)
            try await appBackendEventually {
                reviewPump(window)
                return phases[tab] == .active
            }
            for phase in [ScenePhase.background, .inactive, .active] {
                let notification: Notification.Name = switch phase {
                case .background: UIApplication.didEnterBackgroundNotification
                case .inactive: UIApplication.willResignActiveNotification
                case .active: UIApplication.didBecomeActiveNotification
                @unknown default: UIApplication.didEnterBackgroundNotification
                }
                notifications.post(name: notification, object: nil)
                try await appBackendEventually {
                    reviewPump(window)
                    return phases[tab] == phase
                }
            }
        }
        let tabs = try XCTUnwrap(host.children.first as? UITabBarController)
        XCTAssertEqual(tabs.viewControllers?.count, 3)
        let japanese = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: japanese))
        XCTAssertEqual(bundle.localizedString(forKey: "discoverTab", value: nil, table: "Account"), "見つける")
    }
}

private let reviewInterests = [InterestOption(id: "swift", labelJapanese: "Swift開発", labelEnglish: "Swift development")]
private func reviewToday() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: EncounterSamples.observationTime)
}
private func reviewCatalogue() -> HTTPResponse {
    productResponse([["interest_id": "swift", "label_ja": "Swift開発", "label_en": "Swift development", "display_order": 0]])
}
private func reviewEnabledProfile() -> OwnProfileState {
    var profile = appLinkedPresentationProfile(); profile.discoveryOn = true; return profile
}
@MainActor
private func reviewSettings(_ composition: AppComposition) -> SettingsModel {
    SettingsModel(profile: composition.account.profile ?? appLinkedPresentationProfile(),
        actions: composition.account.profileActions(requestBluetooth: { .available }), interests: reviewInterests, bluetooth: .available,
        onboardingExplanationCompleted: true)
}
@MainActor
private struct ReviewPhaseProbe: View {
    @Environment(\.scenePhase) private var phase
    let record: @MainActor (ScenePhase) -> Void
    var body: some View {
        Color.clear.onAppear { record(phase) }.onChange(of: phase) { _, phase in record(phase) }
    }
}
@MainActor
private func reviewPump(_ window: UIWindow) {
    window.layoutIfNeeded()
    CATransaction.flush()
    _ = RunLoop.main.run(mode: .default, before: Date())
}
