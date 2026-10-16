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
        let transport = relaunchTransport(["get_own_session": [.held, .response(relaunchNull)]])
        let lifecycle = ProductSceneLifecycle(phase: .background, notifications: NotificationCenter())
        let controller = RelaunchActivityController()
        let composition = try relaunchComposition(transport, lifecycle: lifecycle, controller: controller)
        await composition.waitForRestoration()
        lifecycle.receive(.active)
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        lifecycle.receive(.active)
        await composition.account.refresh()
        let heldGets = await transport.count("get_own_session")
        XCTAssertEqual(heldGets, 1)
        await transport.release("get_own_session", with: relaunchSession)
        try await appBackendEventually { composition.sessionActivity.payload != nil }
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
        var online = true
        let transport = relaunchTransport(["start_session": [.response(relaunchSession)],
            "get_own_session": [.response(relaunchNull)]])
        let lifecycle = ProductSceneLifecycle(phase: .background, notifications: NotificationCenter())
        let composition = try relaunchComposition(transport, lifecycle: lifecycle, online: { online })
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        let state = composition.sessionAdapter.state
        online = false
        lifecycle.receive(.active)
        await composition.refresh()
        XCTAssertEqual(composition.sessionAdapter.state, state)
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        let before = await transport.count("get_own_session")
        XCTAssertEqual(before, 0)
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
        let transport = relaunchTransport(["get_own_session": [.response(relaunchSession)]])
        let lifecycle = ProductSceneLifecycle(phase: .background, notifications: NotificationCenter())
        let composition = try relaunchComposition(transport, lifecycle: lifecycle)
        await composition.waitForRestoration()
        composition.account.isDeletionSuspended = { true }
        lifecycle.receive(.active)
        await composition.refresh()
        let gets = await transport.count("get_own_session")
        XCTAssertEqual(gets, 0)
        XCTAssertEqual(composition.sessionAdapter.state, .none)
    }
}

@MainActor
private final class RelaunchActivityController: SessionActivityControlling {
    var calls: [SessionActivityPayload?] = []
    func apply(_ payload: SessionActivityPayload?) async { calls.append(payload) }
}

private let relaunchSessionID = "00000000-0000-0000-0000-000000000444"
private let relaunchSession = HTTPResponse(data: Data("""
{"session_id":"00000000-0000-0000-0000-000000000444","starts_at":1000,"expires_at":8200,"server_time":1000}
""".utf8), statusCode: 200)
private let relaunchNull = HTTPResponse(data: Data("null".utf8), statusCode: 200)

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
private func relaunchComposition(_ transport: ControlledAppBackendTransport, lifecycle: ProductSceneLifecycle,
    defaults: UserDefaults? = nil, store: (any SessionStore)? = nil,
    controller: (any SessionActivityControlling)? = nil,
    online: @escaping @MainActor () -> Bool = { true }) throws -> AppComposition {
    let clock = ManualEncounterClock()
    return AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults ?? appBackendDefaults(),
        notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(), transport: transport,
        keychain: AppMemoryKeychain(), sessionStore: try store ?? InMemorySessionStore(session: appBackendTestSession()),
        serverTokenStore: InMemoryTokenBatchStore(), signedOutTokenStore: InMemoryTokenBatchStore(),
        queueOpener: { InMemoryReceiptQueue() }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), productLifecycle: lifecycle,
        now: { appBackendTestNow }, sessionIsOnline: online, activityController: controller,
        timeZone: { "Asia/Tokyo" })
}
