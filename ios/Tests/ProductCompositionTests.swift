import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class ProductCompositionTests: XCTestCase {
    func testTabHistoriesAreIndependentAndReselectReturnsOnlyThatTabToRoot() {
        let navigation = ProductNavigationModel()
        navigation.push(.favorites, in: .discover)
        navigation.push(.encounter(productEncounterID), in: .discover)
        navigation.select(.profile)
        navigation.push(.visibility, in: .profile)
        navigation.select(.settings)
        navigation.push(.discovery, in: .settings)
        navigation.select(.discover)
        XCTAssertEqual(navigation.discover, [.favorites, .encounter(productEncounterID)])
        navigation.select(.discover)
        XCTAssertTrue(navigation.discover.isEmpty)
        XCTAssertEqual(navigation.profile, [.visibility])
        XCTAssertEqual(navigation.settings, [.discovery])
        navigation.select(.profile); navigation.select(.profile)
        XCTAssertTrue(navigation.profile.isEmpty)
        navigation.select(.settings); navigation.select(.settings)
        XCTAssertTrue(navigation.settings.isEmpty)
    }

    func testMissingCardReturnsToFeedOrOriginatingFavoritesIncludingQR() {
        let navigation = ProductNavigationModel()
        navigation.push(.favorites, in: .discover)
        navigation.push(.encounter(productEncounterID), in: .discover)
        navigation.encounterRemoved(in: .discover)
        XCTAssertEqual(navigation.discover, [.favorites])
        navigation.reset()
        navigation.push(.qr, in: .discover)
        navigation.showEncounter(productEncounterID, in: .discover)
        XCTAssertEqual(navigation.discover, [.encounter(productEncounterID)])
        navigation.encounterRemoved(in: .discover)
        XCTAssertTrue(navigation.discover.isEmpty)
    }

    func testEveryDiscoverActionMapsExactWireFieldsAndParameters() async throws {
        let transport = productTransport([
            "get_encounter_feed": [.response(productFeed())],
            "get_encounter_card": [.response(productResponse(productCard(detail: true)))],
            "list_encounter_favorites": [.response(productFeed())],
            "list_saved_links": [.response(productResponse(["links": [["encounter_id": productEncounterID,
                "day": "2026-10-13", "kind": "session", "link": productLink()]], "truncated": true]))],
            "set_encounter_favorite": [.response(productResponse(["encounter_id": productEncounterID, "favorite": false]))],
            "save_link": [.response(productSaved(true))], "unsave_link": [.response(productSaved(false))]
        ])
        let composition = try productComposition(transport)
        await composition.waitForRestoration()
        productAuthorize(composition)
        composition.discoverAdapter.interests = [.init(id: "swift", labelJapanese: "Swift", labelEnglish: "Swift")]
        let actions = composition.discoverAdapter.actions()
        let feed = try await actions.loadFeed()
        let loadedDetail = try await actions.loadCard(productEncounterID)
        let detail = try XCTUnwrap(loadedDetail)
        let favorites = try await actions.loadFavorites()
        let saved = try await actions.loadSavedLinks()
        let favoriteResult = try await actions.setFavorite(productEncounterID.uppercased(), false)
        let saveResult = try await actions.saveLink(productEncounterID, productLinkID)
        let unsaveResult = try await actions.unsaveLink(productEncounterID, productLinkID)
        XCTAssertEqual(feed, favorites)
        XCTAssertTrue(feed.truncated)
        XCTAssertEqual(feed.cards.first?.card, detail.card)
        XCTAssertEqual(feed.cards.first?.sharedInterestIDs, ["swift"])
        XCTAssertEqual(detail.card.kind, .session)
        XCTAssertEqual(detail.card.day, EncounterDay(year: 2026, month: 10, day: 13))
        XCTAssertEqual(detail.card.displayName, "Person")
        XCTAssertEqual(detail.card.introduction, "Introduction")
        XCTAssertEqual(detail.card.contactDetail, "Contact")
        XCTAssertEqual(detail.card.purposes, [.collaboration])
        XCTAssertEqual(detail.card.links.first?.title, "Work")
        XCTAssertEqual(detail.card.links.first?.verified, true)
        XCTAssertTrue(detail.favorite)
        XCTAssertEqual(detail.savedLinkIDs, [productLinkID])
        XCTAssertTrue(saved.truncated)
        XCTAssertEqual(saved.links.first?.link, detail.card.links.first)
        XCTAssertEqual(favoriteResult, .init(encounterID: productEncounterID, favorite: false))
        XCTAssertEqual(saveResult, .init(encounterID: productEncounterID, linkID: productLinkID, saved: true))
        XCTAssertFalse(unsaveResult.saved)
        XCTAssertNil(actions.deleteEncounter)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.compactMap { $0.url?.lastPathComponent }, ["register_time_zone", "get_encounter_feed",
            "get_encounter_card", "list_encounter_favorites", "list_saved_links", "set_encounter_favorite", "save_link", "unsave_link"])
        let favoriteBody = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[5].httpBody)) as? NSDictionary
        XCTAssertEqual(favoriteBody, ["encounter_id": productEncounterID, "favorite": false] as NSDictionary)
        for request in requests.suffix(2) {
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary
            XCTAssertEqual(body, ["encounter_id": productEncounterID, "link_id": productLinkID] as NSDictionary)
        }
    }

    func testEachDiscoverActionMapsApplicationErrorsAndTransportFailures() async throws {
        let operations: [(String, @MainActor (DiscoverActions) async throws -> Void)] = [
            ("get_encounter_feed", { _ = try await $0.loadFeed() }),
            ("get_encounter_card", { _ = try await $0.loadCard(productEncounterID) }),
            ("list_encounter_favorites", { _ = try await $0.loadFavorites() }),
            ("list_saved_links", { _ = try await $0.loadSavedLinks() }),
            ("set_encounter_favorite", { _ = try await $0.setFavorite(productEncounterID, true) }),
            ("save_link", { _ = try await $0.saveLink(productEncounterID, productLinkID) }),
            ("unsave_link", { _ = try await $0.unsaveLink(productEncounterID, productLinkID) })
        ]
        let failures: [(ControlledAppBackendTransport.Reply, ProfileActionError)] = [
            (.response(productError("prerequisite_missing", details: "discovery")), .init(code: .prerequisiteMissing, fields: ["discovery"])),
            (.response(productError("prerequisite_missing", details: "link")), .init(code: .prerequisiteMissing, fields: ["link"])),
            (.response(productError("not_authenticated")), .init(code: .notAuthenticated)),
            (.response(productError("not_found")), .init(code: .notFound)),
            (.response(productError("rate_limited")), .init(code: .rateLimited)),
            (.response(productError("account_not_ready")), .init(code: .accountNotReady)),
            (.failure, .init(code: .unavailable)),
            (.response(HTTPResponse(data: Data(), statusCode: 503)), .init(code: .unavailable))
        ]
        for (path, operation) in operations {
            for (reply, expected) in failures {
                var plans = [path: expected.code == .notAuthenticated ? [reply, reply] : [reply]]
                plans["token"] = [.response(appBackendAuthResponse())]
                let composition = try productComposition(productTransport(plans))
                await composition.waitForRestoration()
                productAuthorize(composition)
                do { try await operation(composition.discoverAdapter.actions()); XCTFail("Expected sanitized failure") }
                catch { XCTAssertEqual(error as? ProfileActionError, expected, path) }
                if expected.code == .notAuthenticated {
                    XCTAssertEqual(composition.account.state, .signedOut)
                } else { XCTAssertEqual(composition.discoverAdapter.failure, expected) }
            }
        }
    }

    func testDiscoveryPrerequisiteShowsOffPanelAndNotFoundRemovesOpenCard() async throws {
        let transport = productTransport([
            "get_encounter_feed": [.response(productFeed()), .response(productError("prerequisite_missing", details: "discovery"))],
            "get_encounter_card": [.response(productResponse(productCard(detail: true))), .response(productError("not_found"))]
        ])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let model = try XCTUnwrap(composition.discoverAdapter.model)
        await model.loadFeed(); await model.loadCard(productEncounterID)
        await model.loadCard(productEncounterID)
        XCTAssertEqual(model.detailState, .missing)
        XCTAssertNil(model.card)
        XCTAssertTrue(model.feed.isEmpty)
        await model.loadFeed()
        XCTAssertFalse(model.discoveryOn)
        XCTAssertEqual(DiscoverFeedContent.select(discoveryOn: model.discoveryOn, isAuthorized: model.isAuthorized,
            state: model.feedState, hasCards: !model.feed.isEmpty), .discoveryOff)
    }

    func testSignOutClearsAllCardsAndPreservesInstallationSampleDismissal() async throws {
        let defaults = appBackendDefaults()
        let transport = productTransport(["get_encounter_feed": [.response(productFeed())],
            "get_encounter_card": [.response(productResponse(productCard(detail: true)))],
            "list_encounter_favorites": [.response(productFeed())],
            "list_saved_links": [.response(productResponse(["links": [["encounter_id": productEncounterID,
                "day": "2026-10-13", "kind": "session", "link": productLink()]], "truncated": false]))]])
        let composition = try productComposition(transport, defaults: defaults)
        await composition.waitForRestoration(); productAuthorize(composition)
        let model = try XCTUnwrap(composition.discoverAdapter.model)
        await model.loadFeed(); await model.loadCard(productEncounterID); await model.loadFavorites(); await model.loadSavedLinks()
        composition.sampleEncounter.dismiss()
        composition.productNavigation.push(.favorites, in: .discover)
        try await composition.account.signOut()
        XCTAssertTrue(model.feed.isEmpty); XCTAssertTrue(model.favorites.isEmpty); XCTAssertTrue(model.savedLinks.isEmpty)
        XCTAssertNil(model.card); XCTAssertFalse(model.isAuthorized)
        XCTAssertNil(composition.discoverAdapter.model)
        XCTAssertTrue(composition.productNavigation.discover.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: InstallationSampleDismissalStore.key))
        let recreated = SampleEncounterModel(store: InstallationSampleDismissalStore(defaults: defaults), isNewUser: true)
        XCTAssertFalse(recreated.isVisible(in: .emptyFeed))
        XCTAssertFalse(InstallationSampleDismissalStore.key.contains(appBackendTestUser.uuidString.lowercased()))
    }

    func testAccountChangeFencesHeldResponseAndOldClosures() async throws {
        let other = UUID()
        let transport = productTransport(["get_encounter_feed": [.held], "signin": [.response(appBackendAuthResponse(userID: other))],
            "accept_declarations": [.response(appAccountOK())]])
        let store = InMemorySessionStore(session: try appBackendTestSession())
        let composition = try productComposition(transport, store: store)
        await composition.waitForRestoration(); productAuthorize(composition)
        let model = try XCTUnwrap(composition.discoverAdapter.model)
        let old = composition.discoverAdapter.actions()
        let loading = Task { await model.loadFeed() }
        try await appBackendEventually { await transport.isHeld("get_encounter_feed") }
        try await composition.account.signOut()
        try await composition.account.signIn(using: AuthRequest(path: "signin", body: Data()),
            isAdult: true, acceptsTermsAndPrivacy: true, termsVersion: "fixture-terms", privacyVersion: "fixture-privacy")
        XCTAssertEqual(composition.account.state, .signedIn(other))
        await transport.release("get_encounter_feed", with: productFeed())
        await loading.value
        XCTAssertTrue(model.feed.isEmpty)
        let before = await transport.recorded().count
        do { _ = try await old.loadFeed(); XCTFail("Old closure cannot cross accounts") }
        catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .notAuthenticated)) }
        let after = await transport.recorded().count
        XCTAssertEqual(before, after)
    }

    func testCapturedBackendFenceRejectsAllThreeAdaptersBeforeNetwork() async throws {
        let transport = productTransport([:])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let discover = composition.discoverAdapter.actions()
        let session = composition.sessionAdapter.actions()
        let qr = composition.qrAdapter.actions()
        let replacement = UUID()
        composition.account.bindingGeneration = { replacement }
        let before = await transport.recorded().count
        do { _ = try await discover.loadFeed(); XCTFail("Old Discover binding must fail") }
        catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .notAuthenticated)) }
        do { _ = try await session.startSession(); XCTFail("Old session binding must fail") }
        catch { XCTAssertEqual(error as? SessionActionError, .unavailable) }
        do { _ = try await qr.issueCode(); XCTFail("Old QR binding must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let after = await transport.recorded().count
        XCTAssertEqual(before, after)
    }

    func testAccountNotReadyClearsAuthorizedContentAndForegroundReloadsFeed() async throws {
        let transport = productTransport(["get_encounter_feed": [.response(productFeed()), .response(productFeed()),
            .response(productError("account_not_ready"))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let model = try XCTUnwrap(composition.discoverAdapter.model)
        await model.loadFeed()
        await composition.discoverAdapter.foreground()
        let reads = await transport.count("get_encounter_feed")
        XCTAssertEqual(reads, 2)
        await model.loadFeed()
        XCTAssertTrue(model.feed.isEmpty); XCTAssertNil(model.card); XCTAssertFalse(model.isAuthorized)
    }

    func testSessionStateDrivesButtonAndSessionChangesReloadTheFeed() async throws {
        let session = productResponse(["session_id": "00000000-0000-0000-0000-000000000777",
            "starts_at": 1000, "expires_at": 8200, "server_time": 1000])
        let transport = productTransport(["get_encounter_feed": [.response(productFeed()), .response(productFeed()), .response(productFeed())],
            "start_session": [.response(session)], "stop_session": [.response(productResponse(NSNull()))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let model = try XCTUnwrap(composition.discoverAdapter.model)
        await model.loadFeed()
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        _ = try await composition.sessionAdapter.actions().startSession()
        guard case .active = composition.sessionAdapter.state else { return XCTFail("View session must be available") }
        try await appBackendEventually { await transport.count("get_encounter_feed") == 2 }
        try await composition.sessionAdapter.actions().stopSession()
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        try await appBackendEventually { await transport.count("get_encounter_feed") == 3 }
    }
}

let productEncounterID = "00000000-0000-0000-0000-000000000abc"
let productLinkID = "00000000-0000-0000-0000-000000000def"
func productResponse(_ value: Any, status: Int = 200) -> HTTPResponse {
    HTTPResponse(data: try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), statusCode: status)
}
func productError(_ code: String, details: String = "") -> HTTPResponse {
    productResponse(["message": code, "details": details], status: 400)
}
func productLink() -> [String: Any] {
    ["link_id": productLinkID, "source": "github", "url": "https://github.com/person/work", "title": "Work",
     "description": "Description", "main_language": "Swift", "tags": ["ios"], "opening_text": "Opening", "verification_state": "verified"]
}
func productCard(detail: Bool = false) -> [String: Any] {
    var card: [String: Any] = ["encounter_id": productEncounterID, "kind": "session", "day": "2026-10-13",
        "display_name": "Person", "introduction": "Introduction", "contact_detail": "Contact", "interests": ["swift"],
        "purposes": ["collaboration"], "links": [productLink()], "favorite": true]
    if detail { card["saved_link_ids"] = [productLinkID] } else { card["shared_interest_ids"] = ["swift"] }
    return card
}
func productFeed() -> HTTPResponse { productResponse(["cards": [productCard()], "truncated": true]) }
func productSaved(_ saved: Bool) -> HTTPResponse {
    productResponse(["encounter_id": productEncounterID, "link_id": productLinkID, "saved": saved])
}
func productTransport(_ plans: [String: [ControlledAppBackendTransport.Reply]]) -> ControlledAppBackendTransport {
    var plans = plans
    plans["register_time_zone"] = [.response(appAccountOK()), .response(appAccountOK())]
    return ControlledAppBackendTransport(plans)
}
@MainActor
func productAuthorize(_ composition: AppComposition) {
    var profile = appLinkedPresentationProfile()
    profile.discoveryOn = true
    composition.account.publishProfile(profile, stale: false)
}
@MainActor
func productComposition(_ transport: any HTTPTransport, defaults: UserDefaults? = nil, store: (any SessionStore)? = nil,
                        clock: ManualEncounterClock = ManualEncounterClock()) throws -> AppComposition {
    AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults ?? appBackendDefaults(),
        transport: transport, keychain: AppMemoryKeychain(),
        sessionStore: try store ?? InMemorySessionStore(session: appBackendTestSession()),
        serverTokenStore: InMemoryTokenBatchStore(), signedOutTokenStore: InMemoryTokenBatchStore(),
        queueOpener: { InMemoryReceiptQueue() }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow },
        sessionNetwork: SessionNetworkAvailability(monitorsSystemPath: false), timeZone: { "Asia/Tokyo" })
}
