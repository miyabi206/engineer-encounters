import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class SessionActivityTests: XCTestCase {
    func testControlRoutesAllAccountAndRadioStatesWithoutSilentlyGrantingPrerequisites() {
        var context = readyControlContext()
        XCTAssertEqual(context.route, .start)
        for radio in [BluetoothPermissionState.notRequested, .denied, .poweredOff, .unavailable] {
            context.bluetooth = radio
            XCTAssertEqual(context.route, .bluetooth)
            context.sessionActive = true
            XCTAssertEqual(context.route, .session)
            context.sessionActive = false
        }
        context = readyControlContext(); context.discoveryOn = false
        XCTAssertEqual(context.route, .discoveryOff)
        context.onboardingComplete = false; context.accountReady = false
        XCTAssertEqual(context.route, .onboarding)
        context.profileReady = false
        XCTAssertEqual(context.route, .retry)
        context = readyControlContext(); context.accountReady = false
        XCTAssertEqual(context.route, .retry)
        context.signedIn = false; context.sessionActive = true
        XCTAssertEqual(context.route, .welcome)
        for active in [false, true] {
            context = readyControlContext(); context.sessionActive = active
            context.deletionSuspended = true
            XCTAssertEqual(context.route, .blocked)
        }
    }

    func testActivityStartsOnlyAfterAcknowledgementUpdatesOwnNameAndEndsBeforeServerStopCompletes() async throws {
        let controller = RecordingSessionActivityController()
        let clock = ManualEncounterClock(wall: appBackendTestNow.addingTimeInterval(400))
        let transport = surfaceTransport(["start_session": [.held], "stop_session": [.held]])
        let composition = try surfaceComposition(transport, clock: clock, controller: controller)
        await composition.accountFlow.start()
        let starting = Task { try await composition.sessionAdapter.actions().startSession() }
        try await appBackendEventually { await transport.isHeld("start_session") }
        XCTAssertNil(composition.sessionActivity.payload)
        await clock.advance(by: 5)
        await transport.release("start_session", with: surfaceSession(expiry: 1100))
        _ = try await starting.value
        await composition.sessionActivity.flush()
        let payload = try XCTUnwrap(composition.sessionActivity.payload)
        XCTAssertEqual(payload.content.displayName, "名前")
        // Network time is already consumed; a skewed device wall clock never changes the duration.
        XCTAssertEqual(payload.content.endsAt, appBackendTestNow.addingTimeInterval(500))
        XCTAssertTrue(payload.content.presentsActive(isStale: false))
        XCTAssertFalse(payload.content.presentsActive(isStale: true))
        var profile = try XCTUnwrap(composition.account.profile)
        profile.displayName = "New own name"
        composition.account.publishProfile(profile, stale: false)
        try await appBackendEventually { composition.sessionActivity.payload?.content.displayName == "New own name" }
        XCTAssertEqual(composition.sessionActivity.payload?.content.endsAt, payload.content.endsAt)
        let stopping = Task { await composition.stopSessionFromActivity(sessionID: surfaceSessionID) }
        try await appBackendEventually { await transport.isHeld("stop_session") }
        XCTAssertNil(composition.sessionActivity.payload)
        XCTAssertNil(controller.calls.last!)
        XCTAssertTrue(composition.sessionAdapter.stopPending)
        let active = await composition.sessionHolder.isActive()
        XCTAssertFalse(active)
        await transport.release("stop_session", with: surfaceNull)
        await stopping.value
        XCTAssertFalse(composition.sessionAdapter.stopPending)
    }

    func testExpiredActivityEndsOnTimerAndOnResumeWhenTimerWasSuspended() async throws {
        for timerDelivered in [true, false] {
            let controller = RecordingSessionActivityController(), clock = ManualEncounterClock()
            let composition = try surfaceComposition(surfaceTransport(["start_session": [.response(surfaceSession(expiry: 1010))]]),
                clock: clock, controller: controller)
            await composition.accountFlow.start()
            _ = try await composition.sessionAdapter.actions().startSession()
            await composition.sessionActivity.flush()
            XCTAssertNotNil(composition.sessionActivity.payload)
            await clock.advance(by: 10, deliverWakeUps: timerDelivered)
            if timerDelivered {
                try await appBackendEventually { composition.sessionActivity.payload == nil }
            } else {
                await composition.sessionAdapter.foreground()
            }
            await composition.sessionActivity.flush()
            XCTAssertNil(composition.sessionActivity.payload)
            XCTAssertNil(controller.calls.last!)
        }
    }

    func testActivityPayloadHasOnlyOwnRenderingFields() throws {
        let content = SessionActivityAttributes.ContentState(displayName: "Own name", endsAt: appBackendTestNow, isActive: true)
        let encoded = try JSONEncoder().encode(content)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["displayName", "endsAt", "isActive"])
        XCTAssertFalse(content.presentsActive(isStale: true))
        let ended = SessionActivityAttributes.ContentState(displayName: "Own name", endsAt: appBackendTestNow, isActive: false)
        XCTAssertFalse(ended.presentsActive(isStale: false))
    }

    func testControlStartsOnceAndRunningSessionOpensS08EvenWithBluetoothOff() async throws {
        let transport = surfaceTransport(["get_own_session": [.response(surfaceNull)],
            "start_session": [.response(surfaceSession())]])
        let composition = try surfaceComposition(transport)
        await composition.accountFlow.start()
        composition.runtime?.receive(.radioAvailability(.available))
        await composition.startSessionFromControl()
        XCTAssertEqual(composition.productNavigation.discover, [.session])
        XCTAssertNotNil(composition.sessionActivity.payload)
        composition.runtime?.receive(.radioAvailability(.unavailable))
        await composition.startSessionFromControl()
        let starts = await transport.count("start_session")
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(composition.productNavigation.discover, [.session])
    }

    func testSurfaceNavigationPreservesOtherTabHistories() {
        let navigation = ProductNavigationModel()
        navigation.push(.visibility, in: .profile)
        navigation.push(.account, in: .settings)
        navigation.push(.favorites, in: .discover)
        navigation.select(.settings)
        navigation.showSessionFromSurface()
        XCTAssertEqual(navigation.selection, .discover)
        XCTAssertEqual(navigation.discover, [.session])
        navigation.showBluetoothFromSurface()
        XCTAssertEqual(navigation.discover, [.bluetooth])
        navigation.bluetoothRecovered(in: .discover)
        XCTAssertEqual(navigation.discover, [.session])
        navigation.showDiscoveryOff(in: .discover)
        XCTAssertTrue(navigation.discover.isEmpty)
        XCTAssertEqual(navigation.profile, [.visibility])
        XCTAssertEqual(navigation.settings, [.account])
    }

    func testControlFindsAnAlreadyRunningServerSessionAfterProcessLossWithoutStart() async throws {
        let transport = surfaceTransport(["get_own_session": [.response(surfaceSession())]])
        let composition = try surfaceComposition(transport)
        await composition.accountFlow.start()
        composition.runtime?.receive(.radioAvailability(.available))
        await composition.startSessionFromControl()
        let starts = await transport.count("start_session")
        XCTAssertEqual(starts, 0)
        XCTAssertNotNil(composition.sessionActivity.payload)
        XCTAssertEqual(composition.productNavigation.discover, [.session])
    }

    func testControlRoutesWelcomeOnboardingDiscoveryOffAndBluetoothWithoutStarting() async throws {
        let signedOut = AppComposition(configuration: nil, defaults: AppInMemoryDefaults(), keychain: AppMemoryKeychain(),
            activityController: RecordingSessionActivityController())
        await signedOut.startSessionFromControl()
        XCTAssertEqual(signedOut.accountFlow.root, .welcome)
        for scenario in ["basics", "interests", "firstLink", "permissions", "discovery", "radio"] {
            var profile = appLinkedPresentationProfile(); profile.discoveryOn = scenario != "discovery"
            switch scenario {
            case "basics": profile.displayName = ""
            case "interests": profile.interestIDs = []
            case "firstLink": profile.linkCount = 0; profile.prerequisites.link = false
            default: break
            }
            let transport = surfaceTransport([:], profile: profile)
            let composition = try surfaceComposition(transport, completed: scenario == "discovery" || scenario == "radio")
            await composition.startSessionFromControl()
            let starts = await transport.count("start_session")
            XCTAssertEqual(starts, 0, scenario)
            if scenario == "discovery" { XCTAssertEqual(composition.productNavigation.discover, []) }
            else if scenario == "radio" { XCTAssertEqual(composition.productNavigation.discover, [.bluetooth]) }
            else {
                XCTAssertEqual(composition.accountFlow.root, .onboarding)
                let expected: OnboardingStep = switch scenario {
                case "basics": .basics
                case "interests": .interests
                case "firstLink": .firstLink
                default: .permissions
                }
                XCTAssertEqual(composition.accountFlow.onboarding?.step, expected)
            }
        }
    }

    func testOfflineAndFailedStartKeepS08RetryAndNeverClaimActivity() async throws {
        for online in [false, true] {
            let transport = surfaceTransport(["get_own_session": [.response(surfaceNull)], "start_session": [.failure]])
            let composition = try surfaceComposition(transport, online: { online })
            await composition.accountFlow.start()
            composition.runtime?.receive(.radioAvailability(.available))
            await composition.startSessionFromControl()
            XCTAssertEqual(composition.productNavigation.discover, [.session])
            XCTAssertEqual(composition.sessionAdapter.controlStartFailure, online ? .unavailable : .offline)
            XCTAssertNil(composition.sessionActivity.payload)
            let starts = await transport.count("start_session")
            XCTAssertEqual(starts, online ? 1 : 0)
        }
    }

    func testOldActivityStopCannotStopNewSessionAndFailedStopNeverRestoresActivity() async throws {
        let transport = surfaceTransport(["start_session": [.response(surfaceSession())], "stop_session": [.failure]])
        let composition = try surfaceComposition(transport)
        await composition.accountFlow.start()
        _ = try await composition.sessionAdapter.actions().startSession()
        await composition.stopSessionFromActivity(sessionID: UUID().uuidString)
        XCTAssertNotNil(composition.sessionActivity.payload)
        let before = await transport.count("stop_session")
        XCTAssertEqual(before, 0)
        await composition.stopSessionFromActivity(sessionID: surfaceSessionID)
        XCTAssertNil(composition.sessionActivity.payload)
        XCTAssertTrue(composition.sessionAdapter.stopPending)
    }

    func testTemporaryServiceOutageStillClearsLocallyAndQueuesStop() async throws {
        let transport = surfaceTransport(["start_session": [.response(surfaceSession())], "stop_session": [.response(surfaceNull)]])
        let composition = try surfaceComposition(transport)
        await composition.accountFlow.start()
        _ = try await composition.sessionAdapter.actions().startSession()
        let services = try XCTUnwrap(composition.sessionServices)
        await composition.sessionAdapter.configure(nil)
        XCTAssertNotNil(composition.sessionActivity.payload)
        await composition.stopSessionFromActivity(sessionID: surfaceSessionID)
        XCTAssertNil(composition.sessionActivity.payload)
        XCTAssertTrue(composition.sessionAdapter.stopPending)
        let before = await transport.count("stop_session")
        XCTAssertEqual(before, 0)
        await composition.sessionAdapter.configure(services)
        await composition.sessionAdapter.foreground()
        try await appBackendEventually { !composition.sessionAdapter.stopPending }
        XCTAssertNil(composition.sessionActivity.payload)
    }

    func testRelaunchedStopVerifiesCurrentSessionAndCannotStopADifferentMarkedSession() async throws {
        for marked in [false, true] {
            let defaults = appBackendDefaults()
            if marked {
                let owner = try JSONDecoder().decode(BackendStorageOwner.self,
                    from: XCTUnwrap(defaults.data(forKey: BackendStorageBinding.ownerKey)))
                try PendingSessionStopStore(defaults: defaults).save(.init(sessionID: UUID(uuidString: surfaceSessionID)!,
                    expiresAt: appBackendTestNow.addingTimeInterval(7200)), owner: owner)
            }
            let otherSession = HTTPResponse(data: Data("""
            {"session_id":"00000000-0000-0000-0000-000000000445","starts_at":1000,"expires_at":8200,"server_time":1000}
            """.utf8), statusCode: 200)
            let transport = surfaceTransport(["get_own_session": [.response(marked ? otherSession : surfaceSession())],
                "stop_session": [.response(surfaceNull)]])
            let composition = try surfaceComposition(transport, defaults: defaults)
            await composition.accountFlow.start()
            await composition.stopSessionFromActivity(sessionID: surfaceSessionID)
            let gets = await transport.count("get_own_session")
            let stops = await transport.count("stop_session")
            XCTAssertEqual(gets, 1)
            XCTAssertEqual(stops, marked ? 0 : 1)
            if marked { XCTAssertEqual(composition.sessionActivity.payload?.sessionID, "00000000-0000-0000-0000-000000000445") }
            else { XCTAssertNil(composition.sessionActivity.payload) }
        }
    }

    func testControlRoutesToDeletionBlockBothWhilePendingAndAfterFailure() async throws {
        let transport = surfaceTransport(["delete_own_account": [.held]])
        let composition = try surfaceComposition(transport)
        await composition.accountFlow.start()
        composition.runtime?.receive(.radioAvailability(.available))
        let deleting = Task { try await composition.settingsSafetyAdapter.accountActions().deleteAccount() }
        try await appBackendEventually { await transport.isHeld("delete_own_account") }
        await composition.startSessionFromControl()
        XCTAssertTrue(composition.deletionSuspended)
        let pendingStarts = await transport.count("start_session")
        XCTAssertEqual(pendingStarts, 0)
        await transport.release("delete_own_account", with: HTTPResponse(data: Data(), statusCode: 503))
        do { _ = try await deleting.value; XCTFail("Deletion should fail") } catch {}
        await composition.startSessionFromControl()
        XCTAssertTrue(composition.deletionSuspended)
        let failedStarts = await transport.count("start_session")
        XCTAssertEqual(failedStarts, 0)
    }

    func testActivityBodyOpensS08AndCoordinatorOrdersEndAfterDelayedUpdate() async throws {
        let transport = surfaceTransport(["start_session": [.response(surfaceSession())]])
        let composition = try surfaceComposition(transport)
        await composition.accountFlow.start()
        await composition.openSessionFromActivity()
        XCTAssertEqual(composition.productNavigation.discover, [.session])
        let controller = HeldSessionActivityController()
        let coordinator = SessionActivityCoordinator(controller: controller)
        let acknowledgement = SessionAcknowledgement(sessionID: surfaceSessionID, startsAt: appBackendTestNow,
            expiresAt: appBackendTestNow.addingTimeInterval(20), serverTime: appBackendTestNow)
        coordinator.receive(.init(version: 1, state: .active(acknowledgement), remainingSeconds: 20,
            activityEndsAt: acknowledgement.expiresAt, stopPending: false, discoveryOffPending: false), displayName: "Own")
        try await appBackendEventually { controller.waiting }
        coordinator.receive(.init(version: 2, state: .stopping, remainingSeconds: 0,
            activityEndsAt: nil, stopPending: true, discoveryOffPending: false), displayName: "Own")
        controller.release()
        await coordinator.flush()
        XCTAssertEqual(controller.calls.count, 2)
        XCTAssertNotNil(controller.calls[0])
        XCTAssertNil(controller.calls[1])
    }
}

@MainActor
private final class RecordingSessionActivityController: SessionActivityControlling {
    var calls: [SessionActivityPayload?] = []
    func apply(_ payload: SessionActivityPayload?) async { calls.append(payload) }
}

@MainActor
private final class HeldSessionActivityController: SessionActivityControlling {
    var calls: [SessionActivityPayload?] = []
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func apply(_ payload: SessionActivityPayload?) async {
        calls.append(payload)
        if calls.count == 1 {
            await withCheckedContinuation { continuation = $0; waiting = true }
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private func readyControlContext() -> SessionControlContext {
    .init(deletionSuspended: false, signedIn: true, accountReady: true,
        onboardingComplete: true, profileReady: true, discoveryOn: true, bluetooth: .available, sessionActive: false)
}

private let surfaceSessionID = "00000000-0000-0000-0000-000000000444"
private let surfaceNull = HTTPResponse(data: Data("null".utf8), statusCode: 200)
private func surfaceSession(expiry: Int = 8200) -> HTTPResponse {
    HTTPResponse(data: Data("""
    {"session_id":"\(surfaceSessionID)","starts_at":1000,"expires_at":\(expiry),"server_time":1000}
    """.utf8), statusCode: 200)
}

private func surfaceTransport(_ plans: [String: [ControlledAppBackendTransport.Reply]],
    profile: OwnProfileState? = nil) -> ControlledAppBackendTransport {
    var plans = plans
    plans["register_time_zone"] = [.response(appAccountOK())]
    var own = profile ?? appLinkedPresentationProfile()
    if profile == nil { own.discoveryOn = true }
    plans["get_own_profile"] = [.response(appOwnProfileResponse(own))]
    return ControlledAppBackendTransport(plans)
}

@MainActor
private func surfaceComposition(_ transport: any HTTPTransport,
    clock: ManualEncounterClock = ManualEncounterClock(),
    controller: (any SessionActivityControlling)? = nil, completed: Bool = true, defaults suppliedDefaults: UserDefaults? = nil,
    online: @escaping @MainActor () -> Bool = { true }) throws -> AppComposition {
    let defaults = suppliedDefaults ?? appBackendDefaults()
    if completed { OnboardingCompletionStore(defaults: defaults).finish(appBackendTestUser) }
    return AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults,
        notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
        transport: transport, keychain: AppMemoryKeychain(), sessionStore: InMemorySessionStore(session: try appBackendTestSession()),
        serverTokenStore: InMemoryTokenBatchStore(), signedOutTokenStore: InMemoryTokenBatchStore(),
        queueOpener: { InMemoryReceiptQueue() }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow },
        sessionIsOnline: online, activityController: controller ?? RecordingSessionActivityController())
}
