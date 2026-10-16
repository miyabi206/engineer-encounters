import Combine
import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class SessionRelaunchTests: XCTestCase {
    func testActiveRelaunchWaitsForAccountSetupThenPublishesServerSessionWithoutOpeningS08() async throws {
        let transport = relaunchTransport(["register_time_zone": [.held],
            "get_own_session": [.response(relaunchSession)]])
        let controller = RelaunchActivityController()
        let lifecycle = ProductSceneLifecycle(phase: .active, notifications: NotificationCenter())
        let composition = try relaunchComposition(transport, lifecycle: lifecycle, controller: controller)
        try await appBackendEventually { await transport.isHeld("register_time_zone") }
        let before = await transport.count("get_own_session")
        XCTAssertEqual(before, 0)
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        await transport.release("register_time_zone", with: appAccountOK())
        await composition.waitForRestoration()
        try await appBackendEventually { composition.sessionActivity.payload?.sessionID == relaunchSessionID }
        await composition.sessionActivity.flush()
        guard case .active = composition.sessionAdapter.state else { return XCTFail("Server session must be published") }
        XCTAssertEqual(controller.calls.compactMap { $0 }.last?.sessionID, relaunchSessionID)
        XCTAssertTrue(composition.productNavigation.discover.isEmpty)
        let paths = await relaunchPaths(transport)
        // Activation intentionally adds the get after restoration's existing setup request.
        XCTAssertEqual(paths, ["register_time_zone", "get_own_session"])
    }

    func testRelaunchWithoutServerSessionReconcilesSurvivingActivityToNone() async throws {
        let transport = relaunchTransport(["get_own_session": [.response(relaunchNull)]])
        let controller = RelaunchActivityController()
        let composition = try relaunchComposition(transport,
            lifecycle: ProductSceneLifecycle(phase: .active, notifications: NotificationCenter()), controller: controller)
        await composition.waitForRestoration()
        // No local claim can dismiss a surviving activity until this first get answers.
        try await appBackendEventually { !controller.calls.isEmpty }
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        XCTAssertNil(composition.sessionActivity.payload)
        XCTAssertTrue(controller.calls.allSatisfy { $0 == nil })
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 1)
    }

    func testForegroundFlushesQueuedLocalStopBeforeGettingServerState() async throws {
        let transport = relaunchTransport(["start_session": [.response(relaunchSession)],
            "stop_session": [.failure, .response(relaunchNull)], "get_own_session": [.response(relaunchNull)]])
        let lifecycle = ProductSceneLifecycle(phase: .background, notifications: NotificationCenter())
        let controller = RelaunchActivityController()
        let composition = try relaunchComposition(transport, lifecycle: lifecycle, controller: controller)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        do { try await composition.sessionAdapter.actions().stopSession(); XCTFail("Lost stop must stay queued") } catch {}
        XCTAssertTrue(composition.sessionAdapter.stopPending)
        controller.calls.removeAll()
        lifecycle.receive(.active)
        try await appBackendEventually { await transport.count("get_own_session") == 1 }
        try await appBackendEventually { composition.sessionAdapter.state == .none && !composition.sessionAdapter.stopPending }
        await composition.sessionActivity.flush()
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        XCTAssertTrue(controller.calls.allSatisfy { $0 == nil })
        let paths = await relaunchPaths(transport)
        XCTAssertEqual(paths, ["register_time_zone", "start_session", "stop_session", "stop_session", "get_own_session"])
    }

    func testRelaunchedStopMarkerUsesTheExistingGetFenceBeforeUploadingStop() async throws {
        let defaults = appBackendDefaults()
        let owner = try relaunchOwner(defaults)
        try PendingSessionStopStore(defaults: defaults).save(.init(sessionID: UUID(uuidString: relaunchSessionID)!,
            expiresAt: appBackendTestNow.addingTimeInterval(7200)), owner: owner)
        let transport = relaunchTransport(["get_own_session": [.response(relaunchSession)], "stop_session": [.held]])
        let controller = RelaunchActivityController()
        let composition = try relaunchComposition(transport,
            lifecycle: ProductSceneLifecycle(phase: .active, notifications: NotificationCenter()),
            defaults: defaults, controller: controller)
        await composition.waitForRestoration()
        try await appBackendEventually { await transport.isHeld("stop_session") }
        XCTAssertEqual(composition.sessionAdapter.state, .stopping)
        XCTAssertNil(composition.sessionActivity.payload)
        await transport.release("stop_session", with: relaunchNull)
        try await appBackendEventually { !composition.sessionAdapter.stopPending }
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        XCTAssertTrue(controller.calls.allSatisfy { $0 == nil })
        let paths = await relaunchPaths(transport)
        XCTAssertEqual(paths, ["register_time_zone", "get_own_session", "stop_session"])
    }

    func testEachActivationRefreshesOnceDespiteDuplicateNotificationsAndAccountRefresh() async throws {
        let transport = relaunchTransport(["get_own_session": [.held, .response(relaunchNull)],
            "register_time_zone": [.response(appAccountOK()), .failure, .response(appAccountOK())]])
        let zone = AppTestTimeZone("Asia/Tokyo")
        let lifecycle = ProductSceneLifecycle(phase: .background, notifications: NotificationCenter())
        let controller = RelaunchActivityController()
        let composition = try relaunchComposition(transport, lifecycle: lifecycle, controller: controller,
            timeZone: { zone.value })
        await composition.waitForRestoration()
        lifecycle.receive(.active)
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        lifecycle.receive(.active)
        zone.value = "Europe/London"
        let refreshed = RelaunchProgress()
        let refreshing = Task { await composition.refresh(); refreshed.completed = true }
        try await appBackendEventually { refreshed.completed }
        await refreshing.value
        XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
        await composition.refresh()
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        let heldGets = await transport.count("get_own_session")
        XCTAssertEqual(heldGets, 1)
        await transport.release("get_own_session", with: relaunchSession)
        await composition.waitForSessionActivationRefresh()
        XCTAssertNotNil(composition.sessionActivity.payload)
        await composition.refresh()
        let completedGets = await transport.count("get_own_session")
        XCTAssertEqual(completedGets, 1)
        lifecycle.receive(.inactive)
        lifecycle.receive(.active)
        try await appBackendEventually { composition.sessionAdapter.state == .none }
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 2)
    }

    func testFailedActivationGetKeepsAcknowledgedStateAndCredentials() async throws {
        let transport = relaunchTransport(["start_session": [.response(relaunchSession)], "get_own_session": [.failure]])
        let lifecycle = ProductSceneLifecycle(phase: .background, notifications: NotificationCenter())
        let store = InMemorySessionStore(session: try appBackendTestSession())
        let composition = try relaunchComposition(transport, lifecycle: lifecycle, store: store)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        let state = composition.sessionAdapter.state
        lifecycle.receive(.active)
        try await appBackendEventually { composition.sessionAdapter.failure == .transport }
        XCTAssertEqual(composition.sessionAdapter.state, state)
        XCTAssertNotNil(composition.sessionActivity.payload)
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        let stored = try await store.load()
        XCTAssertNotNil(stored)
        let paths = await relaunchPaths(transport)
        XCTAssertEqual(paths, ["register_time_zone", "start_session", "get_own_session"])
    }

    func testOfflineActivationKeepsLocalStateWithoutSigningOut() async throws {
        let network = SessionNetworkAvailability(monitorsSystemPath: false)
        let transport = relaunchTransport(["start_session": [.response(relaunchSession)],
            "get_own_session": [.response(relaunchNull)]])
        let lifecycle = ProductSceneLifecycle(phase: .background, notifications: NotificationCenter())
        let composition = try relaunchComposition(transport, lifecycle: lifecycle, network: network)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        let state = composition.sessionAdapter.state
        network.receive(isOnline: false)
        lifecycle.receive(.active)
        await composition.waitForSessionActivationRefresh()
        XCTAssertEqual(composition.sessionAdapter.state, state)
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        let before = await transport.count("get_own_session")
        XCTAssertEqual(before, 0)
        network.receive(isOnline: true)
        try await appBackendEventually { composition.sessionAdapter.state == .none }
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 1)
    }

    func testOfflineRelaunchRecoversOnNetworkReturnWithoutAnotherActivation() async throws {
        let network = SessionNetworkAvailability(monitorsSystemPath: false)
        network.receive(isOnline: false)
        let transport = relaunchTransport(["get_own_session": [.response(relaunchSession)]])
        let composition = try relaunchComposition(transport, lifecycle: appBackendTestLifecycle(phase: .active), network: network)
        await composition.waitForRestoration()
        await composition.waitForSessionActivationRefresh()
        let before = await transport.count("get_own_session")
        XCTAssertEqual(before, 0)
        network.receive(isOnline: true)
        try await appBackendEventually { composition.sessionActivity.payload?.sessionID == relaunchSessionID }
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 1)
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
    }

    func testUnansweredColdGetKeepsNoneAndReleasesTheActivationClaimForRetry() async throws {
        let transport = relaunchTransport(["get_own_session": [.failure, .response(relaunchSession)]])
        let composition = try relaunchComposition(transport, lifecycle: appBackendTestLifecycle(phase: .active))
        await composition.waitForRestoration()
        await composition.waitForSessionActivationRefresh()
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        XCTAssertEqual(composition.sessionAdapter.failure, .transport)
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        await composition.refresh()
        try await appBackendEventually { composition.sessionActivity.payload != nil }
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 2)
    }

    func testActivationWaitsForFailedAccountSetupToRecover() async throws {
        let transport = relaunchTransport(["register_time_zone": [.failure, .held],
            "get_own_session": [.response(relaunchSession)]])
        let composition = try relaunchComposition(transport,
            lifecycle: ProductSceneLifecycle(phase: .active, notifications: NotificationCenter()))
        await composition.waitForRestoration()
        XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
        let refreshing = Task { await composition.refresh() }
        try await appBackendEventually { await transport.isHeld("register_time_zone") }
        let before = await transport.count("get_own_session")
        XCTAssertEqual(before, 0)
        await transport.release("register_time_zone", with: appAccountOK())
        await refreshing.value
        try await appBackendEventually { composition.sessionActivity.payload != nil }
        let paths = await relaunchPaths(transport)
        XCTAssertEqual(paths, ["register_time_zone", "register_time_zone", "get_own_session"])
    }

    func testActivationDoesNotReleaseRestoredCancellationQuarantine() async throws {
        let defaults = appBackendDefaults()
        let owner = try relaunchOwner(defaults)
        let stops = PendingSessionStopStore(defaults: defaults)
        try stops.saveCancelledStart(.init(requestID: UUID()), owner: owner)
        let transport = relaunchTransport(["get_own_session": [.response(relaunchSession)],
            "stop_session": [.response(relaunchNull)]])
        let composition = try relaunchComposition(transport,
            lifecycle: ProductSceneLifecycle(phase: .active, notifications: NotificationCenter()), defaults: defaults)
        await composition.waitForRestoration()
        try await appBackendEventually {
            let uploaded = await transport.count("stop_session") == 1
            let marker = try stops.load(owner: owner)
            return uploaded && marker == nil
        }
        XCTAssertEqual(composition.sessionAdapter.state, .stopping)
        XCTAssertNotNil(try stops.loadCancelledStart(owner: owner))
        XCTAssertNil(composition.sessionActivity.payload)
        let paths = await relaunchPaths(transport)
        XCTAssertEqual(paths, ["register_time_zone", "get_own_session", "stop_session"])
    }

    func testActivationThatLeavesTheForegroundDuringRestorationWaitsForTheNextActivation() async throws {
        let transport = relaunchTransport(["register_time_zone": [.held],
            "get_own_session": [.response(relaunchSession)]])
        let lifecycle = ProductSceneLifecycle(phase: .active, notifications: NotificationCenter())
        let composition = try relaunchComposition(transport, lifecycle: lifecycle)
        try await appBackendEventually { await transport.isHeld("register_time_zone") }
        lifecycle.receive(.background)
        await transport.release("register_time_zone", with: appAccountOK())
        await composition.waitForRestoration()
        await composition.refresh()
        let before = await transport.count("get_own_session")
        XCTAssertEqual(before, 0)
        lifecycle.receive(.active)
        try await appBackendEventually { composition.sessionActivity.payload != nil }
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 1)
    }

    func testDeletionSuspensionRefusesActivationGet() async throws {
        for suspended in [false, true] {
            let transport = relaunchTransport(["get_own_session": [.response(relaunchSession)],
                "delete_own_account": [.held]])
            let lifecycle = appBackendTestLifecycle()
            let composition = try relaunchComposition(transport, lifecycle: lifecycle)
            await composition.waitForRestoration()
            if suspended {
                composition.startAccountDeletion()
                try await appBackendEventually { await transport.isHeld("delete_own_account") }
            }
            lifecycle.receive(.active)
            let answered = await composition.waitForSessionActivationRefresh()
            XCTAssertEqual(answered, !suspended)
            let gets = await transport.count("get_own_session")
            XCTAssertEqual(gets, suspended ? 0 : 1)
            if suspended {
                XCTAssertNil(composition.sessionActivity.payload)
                await transport.releaseFailure("delete_own_account")
                try await appBackendEventually { composition.deletionState == .failed }
            } else { XCTAssertNotNil(composition.sessionActivity.payload) }
        }
    }

    func testS08RefreshWaitsForHeldActivationGet() async throws {
        let transport = relaunchTransport(["get_own_session": [.held, .response(relaunchSession)]])
        let composition = try relaunchComposition(transport, lifecycle: appBackendTestLifecycle(phase: .active))
        await composition.waitForRestoration()
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        let model = relaunchModel(composition)
        let completed = RelaunchProgress()
        let refreshing = Task { completed.started = true; await model.refresh(); completed.completed = true }
        try await appBackendEventually { completed.started }
        await composition.refresh()
        XCTAssertFalse(completed.completed)
        XCTAssertNil(composition.sessionAdapter.failure)
        await transport.release("get_own_session", with: relaunchSession)
        await refreshing.value
        XCTAssertTrue(model.isActive)
        XCTAssertFalse(model.refreshFailed)
        XCTAssertNil(composition.sessionAdapter.failure)
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 2)
    }

    func testS08StartWaitsForHeldActivationGet() async throws {
        let transport = relaunchTransport(["get_own_session": [.held], "start_session": [.response(relaunchSession)]])
        let composition = try relaunchComposition(transport, lifecycle: appBackendTestLifecycle(phase: .active))
        await composition.waitForRestoration()
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        let model = relaunchModel(composition)
        let starting = Task { await model.start() }
        try await appBackendEventually { model.state == .starting }
        XCTAssertNil(composition.sessionAdapter.failure)
        await transport.release("get_own_session", with: relaunchNull)
        await starting.value
        XCTAssertTrue(model.isActive)
        XCTAssertNil(composition.sessionAdapter.failure)
        let starts = await transport.count("start_session")
        XCTAssertEqual(starts, 1)
    }

    func testControlCenterStartWaitsForHeldActivationGet() async throws {
        let defaults = appBackendDefaults()
        OnboardingCompletionStore(defaults: defaults).finish(appBackendTestUser)
        var profile = appLinkedPresentationProfile(); profile.discoveryOn = true
        let transport = relaunchTransport(["get_own_session": [.held, .response(relaunchNull)],
            "get_own_profile": [.response(appOwnProfileResponse(profile))],
            "start_session": [.response(relaunchSession)]])
        let composition = try relaunchComposition(transport, lifecycle: appBackendTestLifecycle(phase: .active), defaults: defaults)
        await composition.accountFlow.start()
        composition.runtime?.receive(.radioAvailability(.available))
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        let completed = RelaunchProgress()
        let starting = Task { await composition.startSessionFromControl(); completed.completed = true }
        try await appBackendEventually { composition.sessionAdapter.controlStartInProgress }
        XCTAssertFalse(completed.completed)
        XCTAssertNil(composition.sessionAdapter.controlStartFailure)
        await transport.release("get_own_session", with: relaunchNull)
        await starting.value
        XCTAssertNotNil(composition.sessionActivity.payload)
        XCTAssertNil(composition.sessionAdapter.controlStartFailure)
        XCTAssertNil(composition.sessionAdapter.failure)
        XCTAssertEqual(composition.productNavigation.discover, [.session])
        let starts = await transport.count("start_session")
        XCTAssertEqual(starts, 1)
    }

    func testActivationSkipsAnInFlightInteractiveGetWithoutPublishingFailure() async throws {
        let lifecycle = appBackendTestLifecycle()
        let transport = relaunchTransport(["get_own_session": [.held, .response(relaunchNull)]])
        let composition = try relaunchComposition(transport, lifecycle: lifecycle)
        await composition.waitForRestoration()
        let reading = Task { try await composition.sessionAdapter.actions().refreshSession() }
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        lifecycle.receive(.active)
        let answered = await composition.waitForSessionActivationRefresh()
        XCTAssertFalse(answered)
        XCTAssertNil(composition.sessionAdapter.failure)
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        await transport.release("get_own_session", with: relaunchSession)
        _ = try await reading.value
        XCTAssertNotNil(composition.sessionActivity.payload)
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 1)
        // The skipped attempt did not consume the activation's claim.
        await composition.refresh()
        try await appBackendEventually { composition.sessionAdapter.state == .none }
        let retriedGets = await transport.count("get_own_session")
        XCTAssertEqual(retriedGets, 2)
    }

    func testReplacedActivationRetryReleasesItsClaimWithoutPublishingTheObsoleteAnswer() async throws {
        let newSessionID = "00000000-0000-0000-0000-000000000445"
        let transport = relaunchTransport(["get_own_session": [.held, .response(relaunchSessionResponse(id: newSessionID))]])
        let composition = try relaunchComposition(transport, lifecycle: appBackendTestLifecycle(phase: .active))
        await composition.waitForRestoration()
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        let services = try XCTUnwrap(composition.sessionServices)
        await composition.sessionAdapter.configure(nil)
        await composition.sessionAdapter.configure(services)
        await transport.release("get_own_session", with: relaunchSession)
        let answered = await composition.waitForSessionActivationRefresh()
        XCTAssertFalse(answered)
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        XCTAssertNil(composition.sessionAdapter.failure)
        await composition.refresh()
        try await appBackendEventually { composition.sessionActivity.payload?.sessionID == newSessionID }
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 2)
    }

    func testActivationRejectsCredentialsOnlyAfterARealAuthenticationRejection() async throws {
        let transport = relaunchTransport([
            "get_own_session": [.response(HTTPResponse(data: Data(#"{"message":"not_authenticated"}"#.utf8), statusCode: 401))],
            "token": [.response(HTTPResponse(data: Data(#"{"error":"invalid_grant"}"#.utf8), statusCode: 400))]])
        let store = InMemorySessionStore(session: try appBackendTestSession())
        let composition = try relaunchComposition(transport, lifecycle: appBackendTestLifecycle(phase: .active), store: store)
        await composition.waitForRestoration()
        await composition.waitForSessionActivationRefresh()
        XCTAssertEqual(composition.account.state, .signedOut)
        let stored = try await store.load()
        XCTAssertNil(stored)
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        let stops = await transport.count("stop_session")
        XCTAssertEqual(stops, 0)
    }

    func testActivationSkipsAPendingStartWithoutTakingItsReadSlot() async throws {
        let lifecycle = appBackendTestLifecycle()
        let transport = relaunchTransport(["start_session": [.held]])
        let composition = try relaunchComposition(transport, lifecycle: lifecycle)
        await composition.waitForRestoration()
        let starting = Task { try await composition.sessionAdapter.actions().startSession() }
        try await appBackendEventually { await transport.isHeld("start_session") }
        lifecycle.receive(.active)
        let answered = await composition.waitForSessionActivationRefresh()
        XCTAssertFalse(answered)
        XCTAssertNil(composition.sessionAdapter.failure)
        XCTAssertEqual(composition.sessionAdapter.state, .starting)
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 0)
        await transport.release("start_session", with: relaunchSession)
        _ = try await starting.value
        XCTAssertNotNil(composition.sessionActivity.payload)
    }

    func testHeldActivationGetCannotPublishAfterSignOutOrAccountSwitch() async throws {
        for switching in [false, true] {
            let other = UUID()
            let newSessionID = "00000000-0000-0000-0000-000000000445"
            let transport = relaunchTransport(["get_own_session": [.held, .response(relaunchSessionResponse(id: newSessionID))],
                "stop_session": [.response(relaunchNull)],
                "register_time_zone": [.response(appAccountOK()), .response(appAccountOK())],
                "signin": [.response(appBackendAuthResponse(userID: other))],
                "accept_declarations": [.response(appAccountOK())]])
            let composition = try relaunchComposition(transport, lifecycle: appBackendTestLifecycle(phase: .active))
            await composition.waitForRestoration()
            try await appBackendEventually { await transport.isHeld("get_own_session") }
            let claims = RelaunchClaims()
            let observation = composition.sessionAdapter.$state.sink {
                if case .active(let value) = $0, value.sessionID == relaunchSessionID { claims.oldSessionAccepted = true }
            }
            let entered = RelaunchProgress()
            let draining = Task { entered.completed = true; return await composition.waitForSessionActivationRefresh() }
            try await appBackendEventually { entered.completed }
            try await composition.account.signOut()
            let stops = await transport.count("stop_session")
            XCTAssertEqual(stops, 1) // The bounded outgoing stop also completes while the get remains held.
            if switching {
                try await composition.account.signIn(using: AuthRequest(path: "signin", body: Data()),
                    isAdult: true, acceptsTermsAndPrivacy: true, termsVersion: "fixture", privacyVersion: "fixture")
                try await appBackendEventually { composition.sessionActivity.payload?.sessionID == newSessionID }
            }
            await transport.release("get_own_session", with: relaunchSession)
            let answered = await draining.value
            XCTAssertFalse(answered)
            XCTAssertFalse(claims.oldSessionAccepted)
            if switching {
                XCTAssertEqual(composition.account.state, .signedIn(other))
                XCTAssertEqual(composition.sessionActivity.payload?.sessionID, newSessionID)
            } else {
                XCTAssertEqual(composition.account.state, .signedOut)
                XCTAssertEqual(composition.sessionAdapter.state, .none)
                XCTAssertNil(composition.sessionActivity.payload)
            }
            withExtendedLifetime(observation) {}
        }
    }

    func testHeldActivationGetCannotRestoreASessionAfterDeletionStarts() async throws {
        let transport = relaunchTransport(["get_own_session": [.held], "delete_own_account": [.held]])
        let composition = try relaunchComposition(transport, lifecycle: appBackendTestLifecycle(phase: .active))
        await composition.waitForRestoration()
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        composition.startAccountDeletion()
        try await appBackendEventually { await transport.isHeld("delete_own_account") }
        XCTAssertTrue(composition.deletionSuspended)
        await transport.release("get_own_session", with: relaunchSession)
        let answered = await composition.waitForSessionActivationRefresh()
        XCTAssertFalse(answered)
        XCTAssertNil(composition.sessionActivity.payload)
        if case .active = composition.sessionAdapter.state { XCTFail("A fenced get must never revive the deleted account's local claim") }
        await transport.releaseFailure("delete_own_account")
        try await appBackendEventually { composition.deletionState == .failed }
    }
}

@MainActor
private final class RelaunchProgress { var started = false; var completed = false }

@MainActor
private final class RelaunchClaims { var oldSessionAccepted = false }

@MainActor
private final class RelaunchActivityController: SessionActivityControlling {
    var calls: [SessionActivityPayload?] = []
    func apply(_ payload: SessionActivityPayload?) async { calls.append(payload) }
}

private let relaunchSessionID = "00000000-0000-0000-0000-000000000444"
private let relaunchSession = relaunchSessionResponse(id: relaunchSessionID)
private let relaunchNull = HTTPResponse(data: Data("null".utf8), statusCode: 200)

private func relaunchSessionResponse(id: String) -> HTTPResponse {
    HTTPResponse(data: Data("""
    {"session_id":"\(id)","starts_at":1000,"expires_at":8200,"server_time":1000}
    """.utf8), statusCode: 200)
}

private func relaunchTransport(_ supplied: [String: [ControlledAppBackendTransport.Reply]]) -> ControlledAppBackendTransport {
    var plans = supplied
    if plans["register_time_zone"] == nil { plans["register_time_zone"] = [.response(appAccountOK())] }
    return ControlledAppBackendTransport(plans)
}

private func relaunchPaths(_ transport: ControlledAppBackendTransport) async -> [String] {
    await transport.recorded().compactMap { $0.url?.lastPathComponent }
}

@MainActor
private func relaunchOwner(_ defaults: UserDefaults) throws -> BackendStorageOwner {
    try JSONDecoder().decode(BackendStorageOwner.self,
        from: XCTUnwrap(defaults.data(forKey: BackendStorageBinding.ownerKey)))
}

@MainActor
private func relaunchComposition(_ transport: ControlledAppBackendTransport, lifecycle: ProductSceneLifecycle = appBackendTestLifecycle(),
    defaults: UserDefaults? = nil, store: (any SessionStore)? = nil,
    controller: (any SessionActivityControlling)? = nil,
    network: SessionNetworkAvailability? = nil,
    timeZone: @escaping @MainActor () -> String = { "Asia/Tokyo" }) throws -> AppComposition {
    let clock = ManualEncounterClock()
    return AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults ?? appBackendDefaults(),
        notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(), transport: transport,
        keychain: AppMemoryKeychain(), sessionStore: try store ?? InMemorySessionStore(session: appBackendTestSession()),
        serverTokenStore: InMemoryTokenBatchStore(), signedOutTokenStore: InMemoryTokenBatchStore(),
        queueOpener: { InMemoryReceiptQueue() }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), productLifecycle: lifecycle,
        now: { appBackendTestNow }, sessionNetwork: network ?? SessionNetworkAvailability(monitorsSystemPath: false),
        activityController: controller, timeZone: timeZone)
}

@MainActor
private func relaunchModel(_ composition: AppComposition) -> SessionModel {
    SessionModel(actions: composition.sessionAdapter.actions(),
        navigation: .init(openQR: {}, openEncounter: { _ in }, close: {}, openDiscoveryOff: {}), monotonicNow: { 0 })
}
