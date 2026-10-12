import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class SessionHolderTests: XCTestCase {
    func testRelaunchClaimsNothingUntilFreshGetAndNullGetClearsActivity() async throws {
        let transport = sessionTransport(["get_own_session": [.held, .response(sessionNull)]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        await assertFlag(composition, false)
        let before = await transport.count("get_own_session")
        XCTAssertEqual(before, 0)
        let actions = composition.sessionAdapter.actions()
        let refresh = Task { try await actions.refreshSession() }
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        await assertFlag(composition, false)
        await transport.release("get_own_session", with: sessionResponse())
        guard case .active = try await refresh.value else { return XCTFail("Get acknowledgement must activate") }
        await assertFlag(composition, true)
        let state = try await actions.refreshSession()
        XCTAssertEqual(state, .none)
        await assertFlag(composition, false)
    }

    func testStartUsesServerTimeAndContinuousElapsedAndExpiresWithoutNetworkOrWakeup() async throws {
        let clock = ManualEncounterClock(monotonic: 50, wall: appBackendTestNow)
        let transport = sessionTransport(["start_session": [.response(sessionResponse(server: 1100, expiry: 1200))]])
        let composition = try sessionComposition(transport, clock: clock)
        await composition.waitForRestoration()
        let acknowledgement = try await composition.sessionAdapter.actions().startSession()
        XCTAssertEqual(acknowledgement.serverTime, Date(timeIntervalSince1970: 1100))
        await assertFlag(composition, true)
        await clock.advance(by: 40, wallBy: -90000, deliverWakeUps: false)
        let remaining = await composition.sessionHolder.snapshot()
        XCTAssertEqual(remaining.remainingSeconds, 60)
        guard case .active(let reopened) = await composition.sessionAdapter.presentationState() else {
            return XCTFail("Reopened S08 must still be active")
        }
        XCTAssertEqual(reopened.serverTime, Date(timeIntervalSince1970: 1140))
        let before = await transport.recorded().count
        await clock.advance(by: 60, wallBy: 900000, deliverWakeUps: false)
        await assertFlag(composition, false)
        let expired = await composition.sessionHolder.snapshot()
        XCTAssertEqual(expired.state, .none)
        XCTAssertEqual(expired.remainingSeconds, 0)
        let after = await transport.recorded().count
        XCTAssertEqual(after, before)
    }

    func testScheduledExpiryPublishesEndedStateWithoutRuntimeReadOrServerCall() async throws {
        let clock = ManualEncounterClock()
        let transport = sessionTransport(["start_session": [.response(sessionResponse(server: 1000, expiry: 1005))]])
        let composition = try sessionComposition(transport, clock: clock)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        try await appBackendEventually { await clock.pendingWaitCount > 0 }
        await clock.advance(by: 5)
        try await appBackendEventually { composition.sessionAdapter.state == .none }
        let requests = await transport.recorded()
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["register_time_zone", "start_session"])
    }

    func testExpiredOrFutureAcknowledgementNeverSetsFlag() async throws {
        for response in [sessionResponse(server: 1200, expiry: 1200), sessionResponse(server: 999)] {
            let transport = sessionTransport(["get_own_session": [.response(response)]])
            let composition = try sessionComposition(transport)
            await composition.waitForRestoration()
            let state = try await composition.sessionAdapter.actions().refreshSession()
            XCTAssertEqual(state, .none)
            await assertFlag(composition, false)
        }
    }

    func testStopClearsImmediatelyAndFailedStopRetriesOnForeground() async throws {
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "stop_session": [.held, .response(sessionNull)]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        _ = try await actions.startSession()
        let stopping = Task { try await actions.stopSession() }
        try await appBackendEventually { await transport.isHeld("stop_session") }
        await assertFlag(composition, false)
        XCTAssertTrue(composition.sessionAdapter.stopPending)
        await transport.release("stop_session", with: HTTPResponse(data: Data(), statusCode: 503))
        do { try await stopping.value; XCTFail("Stop should remain queued") } catch { }
        await assertFlag(composition, false)
        XCTAssertTrue(composition.sessionAdapter.stopPending)
        await composition.refresh()
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        await assertFlag(composition, false)
        let count = await transport.count("stop_session")
        XCTAssertEqual(count, 2)
    }

    func testPendingStopIsRetriedBeforeLaterStartAndFailureRefusesStartOrGet() async throws {
        let transport = sessionTransport(["start_session": [.response(sessionResponse()), .response(sessionResponse())],
            "stop_session": [.failure, .failure, .failure, .response(sessionNull)]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        _ = try await actions.startSession()
        do { try await actions.stopSession(); XCTFail("First stop must fail") } catch { }
        do { _ = try await actions.startSession(); XCTFail("Unsent stop must refuse start") } catch { }
        do { _ = try await actions.refreshSession(); XCTFail("Unsent stop must refuse get") } catch { }
        await assertFlag(composition, false)
        let before = await transport.recorded()
        XCTAssertEqual(before.filter { $0.url?.lastPathComponent == "start_session" }.count, 1)
        XCTAssertFalse(before.contains { $0.url?.lastPathComponent == "get_own_session" })
        _ = try await actions.startSession()
        await assertFlag(composition, true)
        let paths = await transport.recorded().map { $0.url?.lastPathComponent }
        XCTAssertEqual(Array(paths.suffix(2)), ["stop_session", "start_session"])
        XCTAssertFalse(composition.sessionAdapter.stopPending)
    }

    func testTemporaryKeychainUnavailabilityRetainsPendingStopUntilRecovery() async throws {
        let keychain = AppMemoryKeychain()
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "stop_session": [.failure, .response(sessionNull)]])
        let composition = try sessionComposition(transport, keychain: keychain)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        _ = try await actions.startSession()
        do { try await actions.stopSession(); XCTFail("Stop must remain queued") } catch { }
        await keychain.setUnavailable(true)
        await composition.account.restore()
        XCTAssertNil(composition.sessionServices)
        XCTAssertTrue(composition.sessionAdapter.stopPending)
        await assertFlag(composition, false)
        await keychain.setUnavailable(false)
        await composition.refresh()
        XCTAssertNotNil(composition.sessionServices)
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        await assertFlag(composition, false)
        let stopCount = await transport.count("stop_session")
        XCTAssertEqual(stopCount, 2)
    }

    func testStartAnswerAfterLocalStopIsSuppressedAndServerStopFollowsStart() async throws {
        let transport = sessionTransport(["start_session": [.held], "stop_session": [.response(sessionNull)]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        let starting = Task { try await actions.startSession() }
        try await appBackendEventually { await transport.isHeld("start_session") }
        let stopping = Task { try await actions.stopSession() }
        try await appBackendEventually { composition.sessionAdapter.stopPending }
        await assertFlag(composition, false)
        let before = await transport.count("stop_session")
        XCTAssertEqual(before, 0)
        await transport.release("start_session", with: sessionResponse())
        do { _ = try await starting.value; XCTFail("Stopped start must be obsolete") } catch { }
        try await stopping.value
        await assertFlag(composition, false)
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        let paths = await transport.recorded().map { $0.url?.lastPathComponent }
        XCTAssertEqual(paths, ["register_time_zone", "start_session", "stop_session"])
    }

    func testHeldGetCannotUndoStopEvenAfterStopAcknowledgement() async throws {
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "get_own_session": [.held], "stop_session": [.response(sessionResponse())]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        _ = try await actions.startSession()
        let getting = Task { try await actions.refreshSession() }
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        let stopping = Task { try await actions.stopSession() }
        try await appBackendEventually { composition.sessionAdapter.stopPending }
        await transport.release("get_own_session", with: sessionResponse())
        do { _ = try await getting.value; XCTFail("Stopped get must be obsolete") } catch { }
        try await stopping.value
        await assertFlag(composition, false)
        XCTAssertFalse(composition.sessionAdapter.stopPending)
    }

    func testSignOutDuringPendingStartStopsBeforeDeletingCredentialsWithoutWaitingForStart() async throws {
        let store = FailingAppSessionStore(session: try appBackendTestSession())
        let transport = sessionTransport(["start_session": [.held], "stop_session": [.held]])
        let composition = try sessionComposition(transport, store: store)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        let starting = Task { try await actions.startSession() }
        try await appBackendEventually { await transport.isHeld("start_session") }
        let signingOut = Task { try await composition.account.signOut() }
        try await appBackendEventually { await transport.isHeld("stop_session") }
        await assertFlag(composition, false)
        let before = await store.operations
        XCTAssertFalse(before.contains("clear"))
        await transport.release("stop_session", with: sessionNull)
        try await signingOut.value
        XCTAssertEqual(composition.account.state, .signedOut)
        let stillHeld = await transport.isHeld("start_session")
        XCTAssertTrue(stillHeld)
        await transport.release("start_session", with: sessionResponse())
        do { _ = try await starting.value; XCTFail("Signed-out start must be obsolete") } catch { }
        await assertFlag(composition, false)
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        XCTAssertNil(composition.sessionServices)
        let count = await transport.count("stop_session")
        XCTAssertEqual(count, 1)
    }

    func testFailedOutgoingStopNeverTravelsWithReplacementAccount() async throws {
        let next = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "stop_session": [.failure, .failure],
            "token": [.response(appBackendAuthResponse(userID: next))],
            "accept_declarations": [.response(appAccountOK())],
            "register_time_zone": [.response(appAccountOK()), .response(appAccountOK())]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        let oldServices = try XCTUnwrap(composition.sessionServices)
        let oldActions = composition.sessionAdapter.actions()
        _ = try await oldActions.startSession()
        do { try await oldActions.stopSession(); XCTFail("Stop must remain queued") } catch { }
        try await composition.account.signOut()
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        try await composition.account.signIn(using: .init(path: "token", body: Data("{}".utf8)),
            isAdult: true, acceptsTermsAndPrivacy: true, termsVersion: "v1", privacyVersion: "v1")
        XCTAssertEqual(composition.account.state, .signedIn(next))
        XCTAssertFalse(oldServices === composition.sessionServices)
        await composition.refresh()
        do { try await oldActions.stopSession(); XCTFail("Old actions must be fenced") } catch { }
        let count = await transport.count("stop_session")
        XCTAssertEqual(count, 2)
        await assertFlag(composition, false)
    }

    func testObsoleteStopCannotChangeReplacementAccountsAcknowledgedSession() async throws {
        let next = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        let transport = sessionTransport(["start_session": [.response(sessionResponse()), .response(sessionResponse())],
            "stop_session": [.held, .response(sessionNull)],
            "token": [.response(appBackendAuthResponse(userID: next))],
            "accept_declarations": [.response(appAccountOK())],
            "register_time_zone": [.response(appAccountOK()), .response(appAccountOK())]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        let oldActions = composition.sessionAdapter.actions()
        _ = try await oldActions.startSession()
        let stopping = Task { try await oldActions.stopSession() }
        try await appBackendEventually { await transport.isHeld("stop_session") }
        try await composition.account.signOut()
        try await composition.account.signIn(using: .init(path: "token", body: Data("{}".utf8)),
            isAdult: true, acceptsTermsAndPrivacy: true, termsVersion: "v1", privacyVersion: "v1")
        _ = try await composition.sessionAdapter.actions().startSession()
        await transport.release("stop_session", with: sessionResponse())
        do { try await stopping.value; XCTFail("Old stop must be obsolete") } catch { }
        XCTAssertEqual(composition.account.state, .signedIn(next))
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        await assertFlag(composition, true)
        let stopCount = await transport.count("stop_session")
        XCTAssertEqual(stopCount, 2)
    }

    func testBackendReplacementClearsFlagAndFencesLateResponseAndOldServices() async throws {
        let defaults = appBackendDefaults()
        let oldTransport = sessionTransport(["get_own_session": [.held]])
        let old = try sessionComposition(oldTransport, defaults: defaults)
        await old.waitForRestoration()
        let services = try XCTUnwrap(old.sessionServices)
        let getting = Task { try await old.sessionAdapter.actions().refreshSession() }
        try await appBackendEventually { await oldTransport.isHeld("get_own_session") }
        let replacement = try sessionComposition(sessionTransport([:]), defaults: defaults,
            configuration: BackendConfiguration(address: "https://other.example", publicClientKey: "other-public")!)
        await replacement.waitForRestoration()
        await oldTransport.release("get_own_session", with: sessionResponse())
        do { _ = try await getting.value; XCTFail("Old backend response must be fenced") } catch { }
        do { _ = try await services.call { try await $0.qr.cancelQRCode() }; XCTFail("Old bundle must refuse calls") } catch { }
        let qrCount = await oldTransport.count("cancel_qr_code")
        XCTAssertEqual(qrCount, 0)
        await assertFlag(old, false)
        await assertFlag(replacement, false)
    }

    func testBluetoothLossLeavesSessionClockRunning() async throws {
        let clock = ManualEncounterClock()
        let transport = sessionTransport(["start_session": [.response(sessionResponse(server: 1000, expiry: 1100))]])
        let composition = try sessionComposition(transport, clock: clock)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        composition.runtime?.receive(.radioAvailability(.unavailable))
        await composition.runtime?.stop()
        await clock.advance(by: 20)
        await assertFlag(composition, true)
        let snapshot = await composition.sessionHolder.snapshot()
        XCTAssertEqual(snapshot.remainingSeconds, 80)
        let stopCount = await transport.count("stop_session")
        XCTAssertEqual(stopCount, 0)
    }

    func testDiscoveryOffClearsImmediatelyAndAcknowledgementSynchronizesStop() async throws {
        let profile = appPresentationProfile()
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "set_discovery": [.held], "get_own_profile": [.response(appOwnProfileResponse(profile))]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        let profileActions = composition.account.profileActions { .available }
        let disabling = Task { try await profileActions.setDiscovery(false) }
        try await appBackendEventually { await transport.isHeld("set_discovery") }
        await assertFlag(composition, false)
        XCTAssertTrue(composition.sessionAdapter.stopPending)
        await transport.release("set_discovery", with: appAccountOK())
        _ = try await disabling.value
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        await assertFlag(composition, false)
        do { _ = try await composition.sessionAdapter.actions().startSession(); XCTFail("Discovery must be enabled again") }
        catch { XCTAssertEqual(error as? SessionActionError, .prerequisiteMissing(details: ["discovery"])) }
        let stopCount = await transport.count("stop_session")
        XCTAssertEqual(stopCount, 0) // set_discovery(false) stops transactionally.
    }

    func testFailedDiscoveryOffRetriesBoundSynchronizationOnForeground() async throws {
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "set_discovery": [.failure, .response(appAccountOK())]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        let actions = composition.account.profileActions { .available }
        do { _ = try await actions.setDiscovery(false); XCTFail("Write must fail") } catch { }
        await assertFlag(composition, false)
        let snapshot = await composition.sessionHolder.snapshot()
        XCTAssertTrue(snapshot.discoveryOffPending)
        await composition.refresh()
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        await assertFlag(composition, false)
        let count = await transport.count("set_discovery")
        XCTAssertEqual(count, 2)
    }

    func testDiscoveryEnableFinishesQueuedDisableBeforeEnablingAndPermittingStart() async throws {
        let transport = sessionTransport(["start_session": [.response(sessionResponse()), .response(sessionResponse())],
            "set_discovery": [.failure, .response(appAccountOK()), .response(appAccountOK())],
            "get_own_profile": [.response(appOwnProfileResponse(appPresentationProfile()))]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        let actions = composition.account.profileActions { .available }
        do { _ = try await actions.setDiscovery(false); XCTFail("Disable must fail") } catch { }
        _ = try await actions.setDiscovery(true)
        _ = try await composition.sessionAdapter.actions().startSession()
        await assertFlag(composition, true)
        let requests = await transport.recorded().filter { $0.url?.lastPathComponent == "set_discovery" }
        let values = try requests.map { request in
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Bool])["enabled"]
        }
        XCTAssertEqual(values, [false, false, true])
    }

    func testOfflineStartIsRefusedWithoutNetworkAndTransportFailureDoesNotSignOut() async throws {
        let offlineTransport = sessionTransport([:])
        let offline = try sessionComposition(offlineTransport, online: { false })
        await offline.waitForRestoration()
        do { _ = try await offline.sessionAdapter.actions().startSession(); XCTFail("Offline start must fail") }
        catch { XCTAssertEqual(error as? SessionActionError, .offline) }
        XCTAssertEqual(offline.sessionAdapter.state, .startRefusedOffline)
        XCTAssertEqual(offline.sessionAdapter.failure, .offline)
        await assertFlag(offline, false)
        let count = await offlineTransport.count("start_session")
        XCTAssertEqual(count, 0)
        let transport = sessionTransport(["start_session": [.failure]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        do { _ = try await composition.sessionAdapter.actions().startSession(); XCTFail("Transport failure must fail") }
        catch { XCTAssertEqual(error as? SessionActionError, .unavailable) }
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        XCTAssertEqual(composition.sessionAdapter.failure, .transport)
        await assertFlag(composition, false)
    }

    func testPrerequisiteReadyAndRateLimitFailuresMapWithoutSigningOut() async throws {
        for (reply, expected, actionError) in [
            (sessionError("prerequisite_missing", details: "discovery"), SessionAdapterFailure.prerequisiteMissing(["discovery"]),
             SessionActionError.prerequisiteMissing(details: ["discovery"])),
            (sessionError("account_not_ready"), .accountNotReady, .unavailable),
            (sessionError("rate_limited", status: 429), .rateLimited, .unavailable)
        ] {
            let transport = sessionTransport(["start_session": [.response(reply)]])
            let composition = try sessionComposition(transport)
            await composition.waitForRestoration()
            do { _ = try await composition.sessionAdapter.actions().startSession(); XCTFail("Start must be refused") }
            catch { XCTAssertEqual(error as? SessionActionError, actionError) }
            XCTAssertEqual(composition.sessionAdapter.failure, expected)
            XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
            await assertFlag(composition, false)
        }
    }

    func testS08ActionsRouteDiscoveryPrerequisiteWithoutClaimingActivity() async throws {
        let transport = sessionTransport(["start_session": [.response(sessionError("prerequisite_missing", details: "discovery"))]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        var discoveryOpened = false
        let navigation = SessionNavigationActions(openQR: {}, openEncounter: { _ in }, close: {},
            openDiscoveryOff: { discoveryOpened = true })
        let model = SessionModel(actions: composition.sessionAdapter.actions(), navigation: navigation, monotonicNow: { 0 })
        await model.start()
        XCTAssertTrue(discoveryOpened)
        XCTAssertFalse(model.isActive)
        await assertFlag(composition, false)
    }

    func testAuthorizationLossClearsActiveFlagAndDiscardsCredentials() async throws {
        let store = FailingAppSessionStore(session: try appBackendTestSession())
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "get_own_session": [.response(sessionError("not_authenticated", status: 401))],
            "token": [.response(HTTPResponse(data: Data("{\"error_code\":\"refresh_token_not_found\"}".utf8), statusCode: 400))]])
        let composition = try sessionComposition(transport, store: store)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        _ = try await actions.startSession()
        do { _ = try await actions.refreshSession(); XCTFail("Dead authorization must fail") } catch { }
        await assertFlag(composition, false)
        XCTAssertEqual(composition.account.state, .signedOut)
        let stored = await store.stored
        XCTAssertNil(stored)
        XCTAssertFalse(composition.sessionAdapter.stopPending)
    }

    func testAuthorizationLossOutsideAdapterClearsFlagBeforeCredentialDeletion() async throws {
        let store = SessionCredentialClearGate(session: try appBackendTestSession())
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "get_own_session": [.response(sessionError("not_authenticated", status: 401))],
            "token": [.response(HTTPResponse(data: Data("{\"error_code\":\"refresh_token_not_found\"}".utf8), statusCode: 400))]])
        let composition = try sessionComposition(transport, store: store)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        let services = try XCTUnwrap(composition.sessionServices)
        let getting = Task { try await services.call { try await $0.session.getOwnSession() } }
        try await appBackendEventually { await store.clearStarted }
        await assertFlag(composition, false)
        let before = await store.stored
        XCTAssertNotNil(before)
        await store.releaseClear()
        do { _ = try await getting.value; XCTFail("Authorization must fail") } catch { }
        await composition.refresh()
        XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertFalse(composition.sessionAdapter.stopPending)
    }

    func testAllUnitFourServicesAreAvailableThroughFencedBundle() async throws {
        let transport = sessionTransport([
            "get_own_session": [.response(sessionNull)],
            "cancel_qr_code": [.response(sessionJSON(["cancelled": true]))],
            "get_encounter_feed": [.response(sessionJSON(["cards": [], "truncated": false]))],
            "get_report_settings": [.response(sessionJSON(["report_hour": 19, "report_minute": 0,
                "time_zone": "Asia/Tokyo", "notifications_enabled": false]))],
            "list_blocks": [.response(sessionJSON(["blocks": [], "truncated": false]))],
            "delete_own_account": [.response(sessionJSON(["deleted": true]))]])
        let composition = try sessionComposition(transport)
        await composition.waitForRestoration()
        let bundle = try XCTUnwrap(composition.sessionServices)
        _ = try await bundle.call { try await $0.session.getOwnSession() }
        _ = try await bundle.call { try await $0.qr.cancelQRCode() }
        _ = try await bundle.call { try await $0.encounter.getEncounterFeed() }
        _ = try await bundle.call { try await $0.report.getReportSettings() }
        _ = try await bundle.call { try await $0.safety.listBlocks() }
        _ = try await bundle.call { try await $0.deletion.deleteOwnAccount() }
        let count = await transport.recorded().count
        XCTAssertEqual(count, 7)
        try await composition.account.signOut()
        do { _ = try await bundle.call { try await $0.safety.listBlocks() }; XCTFail("Signed-out bundle must be fenced") } catch { }
        let after = await transport.recorded().count
        XCTAssertEqual(after, count)
    }

    func testHolderFlagReachesReceiptsThroughRealCompositionRuntime() async throws {
        for (mode, expected) in [("none", false), ("active", true), ("expired", false), ("stopped", false)] {
            let clock = ManualEncounterClock()
            let link = FakeBluetoothLink()
            let radio = await FakeBluetoothTransport(phone: .first, link: link, clock: clock)
            let peerRadio = await FakeBluetoothTransport(phone: .second, link: link, clock: clock)
            let queue = InMemoryReceiptQueue()
            let batch = try appBackendLongBatch()
            let batchData = try JSONEncoder().encode(TokenBatchTransfer(batchID: appBackendTestUser, batch: batch))
            let transport = sessionTransport(["start_session": [.response(sessionResponse(expiry: mode == "expired" ? 1005 : 8200))],
                "stop_session": [.response(sessionNull)],
                "issue_token_batch": [.response(HTTPResponse(data: batchData, statusCode: 200))],
                "submit_receipts": [.response(HTTPResponse(data: Data("[]".utf8), statusCode: 200))]])
            let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(),
                transport: transport, keychain: AppMemoryKeychain(),
                sessionStore: InMemorySessionStore(session: try appBackendTestSession()),
                serverTokenStore: InMemoryTokenBatchStore(batch: batch),
                signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { queue }, transportFactory: { radio },
                clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow },
                sessionIsOnline: { true })
            await composition.waitForRestoration()
            if mode != "none" { _ = try await composition.sessionAdapter.actions().startSession() }
            if mode == "expired" { await clock.advance(by: 5, deliverWakeUps: false) }
            if mode == "stopped" { try await composition.sessionAdapter.actions().stopSession() }
            let peerWindow = try TokenWindow(token: EncounterSamples.token(seed: 999),
                validFrom: appBackendTestNow, validUntil: appBackendTestNow.addingTimeInterval(900))
            let peer = EncounterEngine(transport: peerRadio,
                tokenProvider: TokenProvider(store: InMemoryTokenBatchStore(batch: try TokenBatch(windows: [peerWindow]))),
                receiptQueue: InMemoryReceiptQueue(), clock: clock, sessionFlag: { false })
            await link.setObservations(to: .second, enabled: false)
            await peer.start()
            try await appBackendEventually {
                let idle = await peer.isIdle
                let commands = await peerRadio.commands()
                return idle && commands.contains(.startDiscovery)
            }
            await composition.setParticipation(true)
            try await appBackendEventually { !(try await queue.pending()).isEmpty }
            let pending = try await queue.pending()
            let receipt = try XCTUnwrap(pending.first)
            XCTAssertEqual(receipt.sessionFlag, expected, "Receipt flag after \(mode)")
            await composition.setParticipation(false)
            await composition.runtime?.invalidateForAccountChange()
            await peer.stop()
        }
    }

    private func assertFlag(_ composition: AppComposition, _ expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let flag = await composition.sessionHolder.isActive()
        XCTAssertEqual(flag, expected, file: file, line: line)
    }
}

private let sessionNull = HTTPResponse(data: Data("null".utf8), statusCode: 200)

private func sessionResponse(server: Int = 1000, expiry: Int = 8200) -> HTTPResponse {
    sessionJSON(["session_id": "00000000-0000-0000-0000-000000000444", "starts_at": 1000,
                 "expires_at": expiry, "server_time": server])
}

private func sessionJSON(_ value: [String: Any], status: Int = 200) -> HTTPResponse {
    HTTPResponse(data: try! JSONSerialization.data(withJSONObject: value), statusCode: status)
}

private func sessionError(_ code: String, details: String = "", status: Int = 400) -> HTTPResponse {
    sessionJSON(["message": code, "details": details], status: status)
}

private func sessionTransport(_ plans: [String: [ControlledAppBackendTransport.Reply]]) -> ControlledAppBackendTransport {
    var plans = plans
    if plans["register_time_zone"] == nil { plans["register_time_zone"] = [.response(appAccountOK())] }
    return ControlledAppBackendTransport(plans)
}

@MainActor
private func sessionComposition(_ transport: any HTTPTransport, clock: ManualEncounterClock = ManualEncounterClock(),
    store: (any SessionStore)? = nil, defaults: UserDefaults? = nil, keychain: AppMemoryKeychain = AppMemoryKeychain(),
    configuration: BackendConfiguration = appBackendTestConfiguration(),
    online: @escaping @MainActor () -> Bool = { true }) throws -> AppComposition {
    AppComposition(configuration: configuration, defaults: defaults ?? appBackendDefaults(), transport: transport,
        keychain: keychain, sessionStore: try store ?? InMemorySessionStore(session: appBackendTestSession()),
        serverTokenStore: InMemoryTokenBatchStore(), signedOutTokenStore: InMemoryTokenBatchStore(),
        queueOpener: { InMemoryReceiptQueue() }, clock: clock, now: { appBackendTestNow },
        sessionIsOnline: online, timeZone: { "Asia/Tokyo" })
}

private actor SessionCredentialClearGate: SessionStore {
    private(set) var stored: BackendSession?
    private(set) var clearStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(session: BackendSession) { stored = session }
    func load() -> BackendSession? { stored }
    func save(_ session: BackendSession) { stored = session }
    func clear() async {
        if !clearStarted {
            clearStarted = true
            await withCheckedContinuation { continuation = $0 }
        }
        stored = nil
    }
    func releaseClear() { continuation?.resume(); continuation = nil }
}
