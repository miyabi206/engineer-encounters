import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class SessionHolderTests: XCTestCase {
    func testDiscoveryOffWithUnresolvedStopStillSynchronizesThenAllowsAnotherStart() async throws {
        for markedStillActive in [false, true] {
            let defaults = appBackendDefaults(defaults: AppInMemoryDefaults())
            var profile = appPresentationProfile()
            profile.discoveryOn = true
            let transport = sessionTransport([
                "get_own_session": [.response(markedStillActive ? sessionResponse() : sessionNull)],
                "set_discovery": [.failure, .response(appAccountOK()), .response(appAccountOK())],
                "get_own_profile": [.response(appOwnProfileResponse(profile))],
                "start_session": [.response(sessionResponse(id: "00000000-0000-0000-0000-000000000445"))]])
            let composition = try sessionComposition(transport, defaults: defaults)
            await composition.waitForRestoration()
            let owner = try XCTUnwrap(composition.sessionServices?.owner)
            await composition.sessionHolder.bind(nil)
            try PendingSessionStopStore(defaults: defaults).save(.init(
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000444")!,
                expiresAt: appBackendTestNow.addingTimeInterval(100)), owner: owner)
            await composition.sessionHolder.bind(owner)
            let actions = composition.account.profileActions { .available }
            do { _ = try await actions.setDiscovery(false); XCTFail("Offline disable must queue synchronization") } catch { }
            let pending = await composition.sessionHolder.snapshot()
            XCTAssertTrue(pending.stopPending); XCTAssertTrue(pending.discoveryOffPending)
            await composition.sessionAdapter.foreground()
            try await appBackendEventually { !composition.sessionAdapter.stopPending }
            let resolved = await composition.sessionHolder.snapshot()
            XCTAssertFalse(resolved.discoveryOffPending)
            XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
            await assertFlag(composition, false)
            _ = try await actions.setDiscovery(true)
            _ = try await composition.sessionAdapter.actions().startSession()
            await assertFlag(composition, true)
            let requests = await transport.recorded()
            let discoveries = try requests.filter { $0.url?.lastPathComponent == "set_discovery" }.map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Bool])["enabled"]
            }
            XCTAssertEqual(discoveries, [false, false, true])
            let getIndex = try XCTUnwrap(requests.firstIndex { $0.url?.lastPathComponent == "get_own_session" })
            XCTAssertEqual(requests[getIndex + 1].url?.lastPathComponent, "set_discovery")
        }
    }

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

    func testOfflineStopSurvivesRelaunchAndSuppressesMarkedActiveGetAfterStopSucceeds() async throws {
        let defaults = appBackendDefaults()
        let clock = ManualEncounterClock()
        let firstTransport = sessionTransport(["start_session": [.response(sessionResponse())],
            "stop_session": [.failure]])
        let first = try sessionComposition(firstTransport, clock: clock, defaults: defaults)
        await first.waitForRestoration()
        _ = try await first.sessionAdapter.actions().startSession()
        await assertFlag(first, true)
        do { try await first.sessionAdapter.actions().stopSession(); XCTFail("Offline stop must remain queued") } catch { }
        await assertFlag(first, false)
        let keys = pendingStopKeys(defaults)
        XCTAssertEqual(keys.count, 1)
        let data = try XCTUnwrap(defaults.data(forKey: XCTUnwrap(keys.first)))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["sessionID", "expiresAt"])
        XCTAssertFalse(keys[0].contains(appBackendTestUser.uuidString.lowercased()))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-access"))
        await clock.advance(by: 30)
        let transport = sessionTransport(["stop_session": [.held],
            "get_own_session": [.response(sessionResponse(server: 1030)), .response(sessionResponse(server: 1030))],
            "start_session": [.response(sessionResponse(server: 1030,
                id: "00000000-0000-0000-0000-000000000445"))]])
        let relaunched = try sessionComposition(transport, clock: clock, defaults: defaults)
        await relaunched.waitForRestoration()
        await assertFlag(relaunched, false)
        XCTAssertTrue(relaunched.sessionAdapter.stopPending)
        let getting = Task { try await relaunched.sessionAdapter.actions().refreshSession() }
        try await appBackendEventually { await transport.isHeld("stop_session") }
        let getCount = await transport.count("get_own_session")
        XCTAssertEqual(getCount, 1)
        await assertFlag(relaunched, false)
        await transport.release("stop_session", with: sessionNull)
        let state = try await getting.value
        XCTAssertEqual(state, .none)
        await assertFlag(relaunched, false)
        XCTAssertFalse(relaunched.sessionAdapter.stopPending)
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        let paths = await transport.recorded().map { $0.url?.lastPathComponent }
        XCTAssertEqual(Array(paths.suffix(2)), ["get_own_session", "stop_session"])
        let stale = try await relaunched.sessionAdapter.actions().refreshSession()
        XCTAssertEqual(stale, .none)
        await assertFlag(relaunched, false)
        _ = try await relaunched.sessionAdapter.actions().startSession()
        await assertFlag(relaunched, true)
    }

    func testPendingStopMarkerNeedsServerProofAfterLocalExpiryAndAcrossRelaunch() async throws {
        for relaunch in [false, true] {
            let defaults = appBackendDefaults()
            let clock = ManualEncounterClock()
            let transport = sessionTransport(["start_session": [.response(sessionResponse(expiry: 1005))],
                "stop_session": [.failure, .response(sessionNull)], "get_own_session": [.response(sessionNull)]])
            let first = try sessionComposition(transport, clock: clock, defaults: defaults)
            await first.waitForRestoration()
            _ = try await first.sessionAdapter.actions().startSession()
            do { try await first.sessionAdapter.actions().stopSession(); XCTFail("Stop must remain queued") } catch { }
            XCTAssertEqual(pendingStopKeys(defaults).count, 1)
            if relaunch {
                // Simulate process loss: cancel its timers while retaining durable state.
                await first.sessionAdapter.invalidate()
                let launchClock = ManualEncounterClock(monotonic: 0, wall: appBackendTestNow.addingTimeInterval(5))
                let nextTransport = sessionTransport(["get_own_session": [.response(sessionNull)]])
                let next = try sessionComposition(nextTransport, clock: launchClock, defaults: defaults)
                await next.waitForRestoration()
                XCTAssertTrue(next.sessionAdapter.stopPending)
                XCTAssertEqual(pendingStopKeys(defaults).count, 1)
                _ = try await next.sessionAdapter.actions().refreshSession()
                XCTAssertFalse(next.sessionAdapter.stopPending)
                XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
                let stops = await nextTransport.count("stop_session")
                XCTAssertEqual(stops, 0)
                await assertFlag(next, false)
            } else {
                await clock.advance(by: 5)
                let pending = await first.sessionHolder.snapshot()
                XCTAssertTrue(pending.stopPending)
                XCTAssertEqual(pendingStopKeys(defaults).count, 1)
                await assertFlag(first, false)
                _ = try await first.sessionAdapter.actions().refreshSession()
                XCTAssertFalse(first.sessionAdapter.stopPending)
                XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
                let stops = await transport.count("stop_session")
                XCTAssertEqual(stops, 2)
            }
        }
    }

    func testAcknowledgedStopDeadlineCannotDropLaterOfflineStopForInFlightStart() async throws {
        let defaults = appBackendDefaults(defaults: AppInMemoryDefaults())
        let clock = ManualEncounterClock()
        let nextID = "00000000-0000-0000-0000-000000000445"
        let transport = sessionTransport(["start_session": [.response(sessionResponse(expiry: 1005)), .held],
            "stop_session": [.response(sessionNull), .failure, .held],
            "get_own_session": [.response(sessionResponse(server: 1005, expiry: 1100, id: nextID))]])
        let composition = try sessionComposition(transport, clock: clock, defaults: defaults)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        _ = try await actions.startSession()
        try await actions.stopSession()
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        try await appBackendEventually { await clock.pendingWaitCount == 0 }
        let starting = Task { try await actions.startSession() }
        try await appBackendEventually { await transport.isHeld("start_session") }
        let stopping = Task { try await actions.stopSession() }
        try await appBackendEventually { composition.sessionAdapter.stopPending }
        await clock.advance(by: 5)
        let pending = await composition.sessionHolder.snapshot()
        XCTAssertTrue(pending.stopPending)
        await assertFlag(composition, false)
        await transport.release("start_session", with: sessionResponse(server: 1005, expiry: 1100, id: nextID))
        do { _ = try await starting.value; XCTFail("Stopped start must be obsolete") } catch { }
        do { try await stopping.value; XCTFail("Offline stop must remain queued") } catch { }
        XCTAssertTrue(composition.sessionAdapter.stopPending)
        XCTAssertEqual(pendingStopKeys(defaults).count, 1)
        let refreshing = Task { try await actions.refreshSession() }
        try await appBackendEventually { await transport.isHeld("stop_session") }
        let getsBeforeStop = await transport.count("get_own_session")
        XCTAssertEqual(getsBeforeStop, 0)
        await assertFlag(composition, false)
        await transport.release("stop_session", with: sessionNull)
        let state = try await refreshing.value
        XCTAssertEqual(state, .none)
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        let stopCount = await transport.count("stop_session")
        XCTAssertEqual(stopCount, 3)
        await assertFlag(composition, false)
    }

    func testCorruptStopMarkerIsRemovedOnBindAndSessionsRemainUsable() async throws {
        let corruptValues: [Any] = [Data("invalid".utf8), "invalid", Data("{}".utf8)]
        for corrupt in corruptValues {
            let defaults = appBackendDefaults()
            let owner = try JSONDecoder().decode(BackendStorageOwner.self,
                from: XCTUnwrap(defaults.data(forKey: BackendStorageBinding.ownerKey)))
            let key = PendingSessionStopStore.prefix + owner.namespace
            defaults.set(corrupt, forKey: key)
            let transport = sessionTransport(["get_own_session": [.response(sessionNull)],
                "start_session": [.response(sessionResponse())]])
            let composition = try sessionComposition(transport, defaults: defaults)
            await composition.waitForRestoration()
            XCTAssertNil(defaults.object(forKey: key))
            XCTAssertFalse(composition.sessionAdapter.stopPending)
            let state = try await composition.sessionAdapter.actions().refreshSession()
            XCTAssertEqual(state, .none)
            _ = try await composition.sessionAdapter.actions().startSession()
            await assertFlag(composition, true)
            let stopCount = await transport.count("stop_session")
            XCTAssertEqual(stopCount, 0)
            await composition.sessionAdapter.invalidate()
        }
    }

    func testWallClockJumpsBeforeAndAfterMarkerSaveCannotDiscardRelaunchedStop() async throws {
        for jump in [-90000.0, 90000.0] {
            for beforeSave in [true, false] {
                for inFlight in [true, false] {
                    let defaults = appBackendDefaults()
                    let clock = ManualEncounterClock()
                    let firstTransport = sessionTransport(["start_session": [inFlight ? .held : .response(sessionResponse(expiry: 1100))],
                        "stop_session": [.failure]])
                    let first = try sessionComposition(firstTransport, clock: clock, defaults: defaults)
                    await first.waitForRestoration()
                    let actions = first.sessionAdapter.actions()
                    if inFlight {
                        let starting = Task { try await actions.startSession() }
                        try await appBackendEventually { await firstTransport.isHeld("start_session") }
                        let stopping = Task { try await actions.stopSession() }
                        try await appBackendEventually { first.sessionAdapter.stopPending }
                        if beforeSave { await clock.advance(by: 10, wallBy: jump, deliverWakeUps: false) }
                        await firstTransport.release("start_session", with: sessionResponse(expiry: 1100))
                        do { _ = try await starting.value; XCTFail("Stopped start must be obsolete") } catch { }
                        do { try await stopping.value; XCTFail("Stop must remain queued") } catch { }
                    } else {
                        _ = try await actions.startSession()
                        if beforeSave { await clock.advance(by: 10, wallBy: jump, deliverWakeUps: false) }
                        do { try await actions.stopSession(); XCTFail("Stop must remain queued") } catch { }
                    }
                    let key = try XCTUnwrap(pendingStopKeys(defaults).first)
                    let marker = try JSONDecoder().decode(PendingSessionStopStore.Marker.self,
                        from: XCTUnwrap(defaults.data(forKey: key)))
                    XCTAssertEqual(marker.expiresAt.timeIntervalSince(appBackendTestNow),
                        beforeSave ? jump + 90 : 100, accuracy: 0.0001)
                    if !beforeSave { await clock.advance(by: 10, wallBy: jump, deliverWakeUps: false) }
                    let time = await clock.now()
                    await first.sessionAdapter.invalidate()
                    let launchClock = ManualEncounterClock(monotonic: 0, wall: time.wall)
                    let transport = sessionTransport(["get_own_session": [.held], "stop_session": [.held]])
                    let next = try sessionComposition(transport, clock: launchClock, defaults: defaults)
                    await next.waitForRestoration()
                    XCTAssertTrue(next.sessionAdapter.stopPending)
                    let refreshing = Task { try await next.sessionAdapter.actions().refreshSession() }
                    try await appBackendEventually { await transport.isHeld("get_own_session") }
                    await assertFlag(next, false)
                    let stopsBeforeGet = await transport.count("stop_session")
                    XCTAssertEqual(stopsBeforeGet, 0)
                    await transport.release("get_own_session", with: sessionResponse(server: 1010, expiry: 1100))
                    try await appBackendEventually { await transport.isHeld("stop_session") }
                    await assertFlag(next, false)
                    await launchClock.advance(by: 90)
                    let pending = await next.sessionHolder.snapshot()
                    XCTAssertTrue(pending.stopPending)
                    XCTAssertEqual(pendingStopKeys(defaults), [key])
                    await transport.release("stop_session", with: sessionNull)
                    let state = try await refreshing.value
                    XCTAssertEqual(state, .none)
                    XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
                    await assertFlag(next, false)
                    let paths = await transport.recorded().map { $0.url?.lastPathComponent }
                    XCTAssertEqual(paths, ["register_time_zone", "get_own_session", "stop_session"])
                }
            }
        }
    }

    func testRelaunchedMarkerIsRemovedWhenGetReportsNoSessionOrDifferentSession() async throws {
        for differentSession in [true, false] {
            let defaults = appBackendDefaults()
            let first = try sessionComposition(sessionTransport(["start_session": [.response(sessionResponse())],
                "stop_session": [.failure]]), defaults: defaults)
            await first.waitForRestoration()
            _ = try await first.sessionAdapter.actions().startSession()
            do { try await first.sessionAdapter.actions().stopSession(); XCTFail("Stop must remain queued") } catch { }
            await first.sessionAdapter.invalidate()
            let nextID = "00000000-0000-0000-0000-000000000445"
            let transport = sessionTransport(["get_own_session": [.response(differentSession ? sessionResponse(id: nextID) : sessionNull)]])
            let next = try sessionComposition(transport, defaults: defaults)
            await next.waitForRestoration()
            let state = try await next.sessionAdapter.actions().refreshSession()
            if differentSession {
                guard case .active(let value) = state else { return XCTFail("Different session must be applied normally") }
                XCTAssertEqual(value.sessionID, nextID)
            } else { XCTAssertEqual(state, .none) }
            await assertFlag(next, differentSession)
            XCTAssertFalse(next.sessionAdapter.stopPending)
            XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
            let stopCount = await transport.count("stop_session")
            let getCount = await transport.count("get_own_session")
            XCTAssertEqual(stopCount, 0)
            XCTAssertEqual(getCount, 1)
            await next.sessionAdapter.invalidate()
        }
    }

    func testRelaunchedStartChecksMarkedSessionAndStopsItBeforeStarting() async throws {
        let defaults = appBackendDefaults()
        let first = try sessionComposition(sessionTransport(["start_session": [.response(sessionResponse())],
            "stop_session": [.failure]]), defaults: defaults)
        await first.waitForRestoration()
        _ = try await first.sessionAdapter.actions().startSession()
        do { try await first.sessionAdapter.actions().stopSession(); XCTFail("Stop must remain queued") } catch { }
        await first.sessionAdapter.invalidate()
        let transport = sessionTransport(["get_own_session": [.response(sessionResponse())],
            "stop_session": [.response(sessionNull)],
            "start_session": [.response(sessionResponse(id: "00000000-0000-0000-0000-000000000445"))]])
        let next = try sessionComposition(transport, defaults: defaults)
        await next.waitForRestoration()
        _ = try await next.sessionAdapter.actions().startSession()
        await assertFlag(next, true)
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        let paths = await transport.recorded().map { $0.url?.lastPathComponent }
        XCTAssertEqual(Array(paths.suffix(3)), ["get_own_session", "stop_session", "start_session"])
        await next.sessionAdapter.invalidate()
    }

    func testS08StopWithUnresolvedMarkerChecksServerBeforeStopping() async throws {
        let otherID = "00000000-0000-0000-0000-000000000445"
        for answer in ["marked", "none", "other"] {
            let defaults = appBackendDefaults(defaults: AppInMemoryDefaults())
            try seedUnresolvedStop(defaults)
            let transport = sessionTransport(["get_own_session": [.failure, .failure, .held], "stop_session": [.held]])
            let composition = try sessionComposition(transport, defaults: defaults, online: { false })
            await composition.waitForRestoration()
            let actions = composition.sessionAdapter.actions()
            do { _ = try await actions.refreshSession(); XCTFail("Offline S08 cannot resolve the marker") } catch { }
            do { try await actions.stopSession(); XCTFail("Offline stop must retain reconciliation") } catch { }
            XCTAssertTrue(composition.sessionAdapter.stopPending)
            let stopsOffline = await transport.count("stop_session")
            XCTAssertEqual(stopsOffline, 0)
            await composition.sessionAdapter.foreground()
            try await appBackendEventually { await transport.isHeld("get_own_session") }
            let stopsBeforeGet = await transport.count("stop_session")
            XCTAssertEqual(stopsBeforeGet, 0)
            await assertFlag(composition, false)
            await transport.release("get_own_session", with: answer == "none" ? sessionNull :
                sessionResponse(id: answer == "marked" ? "00000000-0000-0000-0000-000000000444" : otherID))
            if answer == "marked" {
                try await appBackendEventually { await transport.isHeld("stop_session") }
                await assertFlag(composition, false)
                await transport.release("stop_session", with: sessionNull)
            }
            try await appBackendEventually { !composition.sessionAdapter.stopPending }
            await assertFlag(composition, answer == "other")
            XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
            let stops = await transport.count("stop_session")
            let gets = await transport.count("get_own_session")
            XCTAssertEqual(stops, answer == "marked" ? 1 : 0)
            XCTAssertEqual(gets, 3)
            await composition.sessionAdapter.invalidate()
        }
    }

    func testSignOutWithUnresolvedMarkerChecksServerAndDropsItBeforeCredentials() async throws {
        for answer in ["marked", "none", "other", "offline", "timeout"] {
            let defaults = appBackendDefaults(defaults: AppInMemoryDefaults())
            try seedUnresolvedStop(defaults)
            let clock = ManualEncounterClock()
            let store = SessionCredentialClearGate(session: try appBackendTestSession())
            let transport = sessionTransport(["get_own_session": [.held], "stop_session": [.held]])
            let composition = try sessionComposition(transport, clock: clock, store: store, defaults: defaults)
            await composition.waitForRestoration()
            let signingOut = Task { try await composition.account.signOut() }
            try await appBackendEventually { await transport.isHeld("get_own_session") }
            await assertFlag(composition, false)
            let stopsBeforeGet = await transport.count("stop_session")
            XCTAssertEqual(stopsBeforeGet, 0)
            XCTAssertEqual(pendingStopKeys(defaults).count, 1)
            if answer == "timeout" {
                try await appBackendEventually { await clock.pendingWaitCount > 0 }
                await clock.advance(by: 1.99)
                let clearedEarly = await store.clearStarted
                XCTAssertFalse(clearedEarly)
                await clock.advance(by: 0.01)
            } else {
                let response: HTTPResponse
                switch answer {
                case "marked": response = sessionResponse()
                case "other": response = sessionResponse(id: "00000000-0000-0000-0000-000000000445")
                case "offline": response = HTTPResponse(data: Data(), statusCode: 503)
                default: response = sessionNull
                }
                await transport.release("get_own_session", with: response)
                if answer == "marked" {
                    try await appBackendEventually { await transport.isHeld("stop_session") }
                    await assertFlag(composition, false)
                    await transport.release("stop_session", with: sessionNull)
                }
            }
            try await appBackendEventually { await store.clearStarted }
            XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
            await assertFlag(composition, false)
            await store.releaseClear()
            try await signingOut.value
            XCTAssertEqual(composition.account.state, .signedOut)
            if answer == "timeout" {
                await transport.release("get_own_session", with: sessionResponse())
                try await appBackendEventually { await clock.pendingWaitCount == 0 }
            }
            let paths = await transport.recorded().compactMap { $0.url?.lastPathComponent }
            XCTAssertEqual(paths, answer == "marked" ? ["register_time_zone", "get_own_session", "stop_session"] :
                ["register_time_zone", "get_own_session"])
            XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        }
    }

    func testStoppingDuringHeldMarkerCheckCannotRetargetStopToAnotherDeviceSession() async throws {
        let defaults = appBackendDefaults(defaults: AppInMemoryDefaults())
        try seedUnresolvedStop(defaults)
        let other = sessionResponse(id: "00000000-0000-0000-0000-000000000445")
        let transport = sessionTransport(["get_own_session": [.held, .response(other)]])
        let composition = try sessionComposition(transport, defaults: defaults)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        let checking = Task { try await actions.refreshSession() }
        try await appBackendEventually { await transport.isHeld("get_own_session") }
        do { try await actions.stopSession(); XCTFail("An outstanding check cannot authorize a stop") } catch { }
        await transport.release("get_own_session", with: other)
        do { _ = try await checking.value; XCTFail("Locally superseded get must be obsolete") } catch { }
        let marker = try JSONDecoder().decode(PendingSessionStopStore.Marker.self,
            from: XCTUnwrap(defaults.data(forKey: XCTUnwrap(pendingStopKeys(defaults).first))))
        XCTAssertEqual(marker.sessionID.uuidString.lowercased(), "00000000-0000-0000-0000-000000000444")
        _ = try await actions.refreshSession()
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        await assertFlag(composition, true)
        let stops = await transport.count("stop_session")
        XCTAssertEqual(stops, 0)
        await composition.sessionAdapter.invalidate()
    }

    func testPendingStopMarkerCannotTravelToAnotherAccountOrBackend() async throws {
        for otherAccount in [true, false] {
            let defaults = appBackendDefaults()
            let first = try sessionComposition(sessionTransport(["start_session": [.response(sessionResponse())],
                "stop_session": [.failure]]), defaults: defaults)
            await first.waitForRestoration()
            _ = try await first.sessionAdapter.actions().startSession()
            do { try await first.sessionAdapter.actions().stopSession(); XCTFail("Stop must remain queued") } catch { }
            let keys = pendingStopKeys(defaults)
            let nextUser = otherAccount ? UUID() : appBackendTestUser
            let configuration = otherAccount ? appBackendTestConfiguration() :
                BackendConfiguration(address: "https://other.example", publicClientKey: "other-public")!
            let nextTransport = sessionTransport(["get_own_session": [.response(sessionResponse())]])
            let next = try sessionComposition(nextTransport,
                store: InMemorySessionStore(session: appBackendTestSession(userID: nextUser)),
                defaults: defaults, configuration: configuration)
            await next.waitForRestoration()
            XCTAssertFalse(next.sessionAdapter.stopPending)
            _ = try await next.sessionAdapter.actions().refreshSession()
            await assertFlag(next, true)
            let stops = await nextTransport.count("stop_session")
            XCTAssertEqual(stops, 0)
            XCTAssertEqual(pendingStopKeys(defaults), keys)
        }
    }

    func testSignOutAbandonsStalledActiveStopAtTwoSecondsAndClearsMarkerBeforeCredentials() async throws {
        let defaults = appBackendDefaults()
        let clock = ManualEncounterClock()
        let store = SessionCredentialClearGate(session: try appBackendTestSession())
        let transport = sessionTransport(["start_session": [.response(sessionResponse())], "stop_session": [.held]])
        let composition = try sessionComposition(transport, clock: clock, store: store, defaults: defaults)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        await assertFlag(composition, true)
        let signingOut = Task { try await composition.account.signOut() }
        try await appBackendEventually { await transport.isHeld("stop_session") }
        await assertFlag(composition, false)
        XCTAssertEqual(pendingStopKeys(defaults).count, 1)
        try await appBackendEventually { await clock.pendingWaitCount > 0 }
        await clock.advance(by: 1.99)
        let clearingEarly = await store.clearStarted
        XCTAssertFalse(clearingEarly)
        await clock.advance(by: 0.01)
        try await appBackendEventually { await store.clearStarted }
        XCTAssertTrue(defaults.bool(forKey: SessionCleanupMarker.key))
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        await store.releaseClear()
        var finished = false
        let completion = Task { try await signingOut.value; finished = true }
        try await appBackendEventually { finished }
        try await completion.value
        XCTAssertEqual(composition.account.state, .signedOut)
        let time = await clock.now()
        XCTAssertEqual(time.monotonic, 2, accuracy: 0.0001)
        await transport.release("stop_session", with: sessionResponse())
        await assertFlag(composition, false)
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        try await appBackendEventually { await clock.pendingWaitCount == 0 }
    }

    func testSuccessfulAccountDeletionClearsPendingStopMarkerWithoutAnotherStopRequest() async throws {
        let defaults = appBackendDefaults()
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "stop_session": [.failure], "delete_own_account": [.response(sessionJSON(["deleted": true]))]])
        let composition = try sessionComposition(transport, defaults: defaults)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        do { try await composition.sessionAdapter.actions().stopSession(); XCTFail("Stop must remain queued") } catch { }
        XCTAssertEqual(pendingStopKeys(defaults).count, 1)
        let services = try XCTUnwrap(composition.sessionServices)
        _ = try await services.call { try await $0.deletion.deleteOwnAccount() }
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        await assertFlag(composition, false)
        let stops = await transport.count("stop_session")
        XCTAssertEqual(stops, 1)
    }

    func testDelayedStartAndGetAnswersUseRequestSendAnchorAndCannotExtendExpiry() async throws {
        for procedure in ["start_session", "get_own_session"] {
            for delay in [40.0, 100.0] {
                let clock = ManualEncounterClock(monotonic: 50)
                let transport = sessionTransport([procedure: [.held]])
                let composition = try sessionComposition(transport, clock: clock)
                await composition.waitForRestoration()
                let actions = composition.sessionAdapter.actions()
                let request = Task { () throws -> SessionState in
                    if procedure == "start_session" { return .active(try await actions.startSession()) }
                    return try await actions.refreshSession()
                }
                try await appBackendEventually { await transport.isHeld(procedure) }
                await clock.advance(by: delay, wallBy: -90000, deliverWakeUps: false)
                await transport.release(procedure, with: sessionResponse(expiry: 1100))
                if delay == 100, procedure == "start_session" {
                    do { _ = try await request.value; XCTFail("Expired start cannot be acknowledged active") } catch { }
                } else {
                    let state = try await request.value
                    if delay == 100 { XCTAssertEqual(state, .none) }
                    else {
                        guard case .active(let value) = state else { return XCTFail("Unexpired answer must activate") }
                        XCTAssertEqual(value.serverTime, Date(timeIntervalSince1970: 1040))
                    }
                }
                let snapshot = await composition.sessionHolder.snapshot()
                XCTAssertEqual(snapshot.remainingSeconds, delay == 40 ? 60 : 0)
                await assertFlag(composition, delay == 40)
                if delay == 40 {
                    await clock.advance(by: 60, deliverWakeUps: false)
                    await assertFlag(composition, false)
                }
            }
        }
    }

    func testRealNetworkRecoveryCallbackRetriesPendingStopWithoutInjectedOnlineFlag() async throws {
        let network = SessionNetworkAvailability(monitorsSystemPath: false)
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "stop_session": [.failure, .response(sessionNull)]])
        let composition = try sessionComposition(transport, online: nil, network: network)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        network.receive(isOnline: false)
        do { try await composition.sessionAdapter.actions().stopSession(); XCTFail("Stop must remain queued") } catch { }
        await assertFlag(composition, false)
        network.receive(isOnline: true)
        try await appBackendEventually { !composition.sessionAdapter.stopPending }
        let stops = await transport.count("stop_session")
        XCTAssertEqual(stops, 2)
        await assertFlag(composition, false)
    }

    func testForegroundHeldStopDoesNotDelayRuntimeRefreshTokenTopUpOrUpload() async throws {
        let clock = ManualEncounterClock()
        let defaults = appBackendDefaults()
        ParticipationFlag(defaults: defaults).isEnabled = true
        let tokens = InMemoryTokenBatchStore(batch: try appBackendLongBatch())
        let queue = InMemoryReceiptQueue()
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "stop_session": [.failure, .held], "issue_token_batch": [.held], "submit_receipts": [.held]])
        let composition = try sessionComposition(transport, clock: clock, defaults: defaults, tokens: tokens, queue: queue)
        await composition.waitForRestoration()
        _ = try await composition.sessionAdapter.actions().startSession()
        do { try await composition.sessionAdapter.actions().stopSession(); XCTFail("Stop must remain queued") } catch { }
        // Let the initial top-up/upload settle before introducing fresh runtime work.
        try await appBackendEventually { composition.runtime?.uploadTask == nil }
        try await tokens.clear()
        try await queue.enqueue(appBackendFinalReceipt())
        var refreshed = false
        let refresh = Task { await composition.refresh(); refreshed = true }
        try await appBackendEventually {
            let stopHeld = await transport.isHeld("stop_session")
            let tokensHeld = await transport.isHeld("issue_token_batch")
            let uploadHeld = await transport.isHeld("submit_receipts")
            return refreshed && stopHeld && tokensHeld && uploadHeld
        }
        await refresh.value
        await assertFlag(composition, false)
        await transport.release("stop_session", with: sessionNull)
        let batch = try JSONEncoder().encode(TokenBatchTransfer(batchID: appBackendTestUser, batch: appBackendLongBatch()))
        await transport.release("issue_token_batch", with: HTTPResponse(data: batch, statusCode: 200))
        await transport.release("submit_receipts", with: HTTPResponse(data: Data("[]".utf8), statusCode: 200))
        try await appBackendEventually { !composition.sessionAdapter.stopPending }
        await composition.setParticipation(false)
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
        try await appBackendEventually { !composition.sessionAdapter.stopPending }
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        XCTAssertEqual(composition.sessionAdapter.state, .none)
        await assertFlag(composition, false)
        let count = await transport.count("stop_session")
        XCTAssertEqual(count, 2)
    }

    func testPendingStopIsRetriedBeforeLaterStartAndFailureRefusesStartOrGet() async throws {
        let transport = sessionTransport(["start_session": [.response(sessionResponse()), .response(sessionResponse(id: "00000000-0000-0000-0000-000000000445"))],
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
        let defaults = appBackendDefaults()
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "stop_session": [.failure, .held]])
        let composition = try sessionComposition(transport, defaults: defaults, keychain: keychain)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        _ = try await actions.startSession()
        do { try await actions.stopSession(); XCTFail("Stop must remain queued") } catch { }
        await keychain.setUnavailable(true)
        await composition.account.restore()
        XCTAssertNil(composition.sessionServices)
        XCTAssertTrue(composition.sessionAdapter.stopPending)
        XCTAssertEqual(pendingStopKeys(defaults).count, 1)
        await assertFlag(composition, false)
        await keychain.setUnavailable(false)
        await composition.refresh()
        XCTAssertNotNil(composition.sessionServices)
        // Foreground schedules its retry without waiting for the network response.
        try await appBackendEventually { await transport.isHeld("stop_session") }
        XCTAssertTrue(composition.sessionAdapter.stopPending)
        await assertFlag(composition, false)
        await transport.release("stop_session", with: sessionNull)
        try await appBackendEventually { !composition.sessionAdapter.stopPending }
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        await assertFlag(composition, false)
        let stopCount = await transport.count("stop_session")
        XCTAssertEqual(stopCount, 2)
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
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

    func testSignOutDuringPendingStartBoundsStopBeforeDeletingCredentialsWithoutWaitingForStart() async throws {
        let clock = ManualEncounterClock()
        let store = FailingAppSessionStore(session: try appBackendTestSession())
        let transport = sessionTransport(["start_session": [.held], "stop_session": [.held]])
        let composition = try sessionComposition(transport, clock: clock, store: store)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        let starting = Task { try await actions.startSession() }
        try await appBackendEventually { await transport.isHeld("start_session") }
        let signingOut = Task { try await composition.account.signOut() }
        try await appBackendEventually { await transport.isHeld("stop_session") }
        await assertFlag(composition, false)
        let before = await store.operations
        XCTAssertFalse(before.contains("clear"))
        try await appBackendEventually { await clock.pendingWaitCount > 0 }
        await clock.advance(by: 2)
        var finished = false
        let completion = Task { try await signingOut.value; finished = true }
        try await appBackendEventually { finished }
        try await completion.value
        await transport.release("stop_session", with: sessionNull)
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
        let defaults = appBackendDefaults()
        let next = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "stop_session": [.failure, .failure],
            "token": [.response(appBackendAuthResponse(userID: next))],
            "accept_declarations": [.response(appAccountOK())],
            "register_time_zone": [.response(appAccountOK()), .response(appAccountOK())]])
        let composition = try sessionComposition(transport, defaults: defaults)
        await composition.waitForRestoration()
        let oldServices = try XCTUnwrap(composition.sessionServices)
        let oldActions = composition.sessionAdapter.actions()
        _ = try await oldActions.startSession()
        do { try await oldActions.stopSession(); XCTFail("Stop must remain queued") } catch { }
        XCTAssertEqual(pendingStopKeys(defaults).count, 1)
        try await composition.account.signOut()
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
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
        let transport = sessionTransport(["start_session": [.response(sessionResponse()), .response(sessionResponse(id: "00000000-0000-0000-0000-000000000445"))],
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
        let oldTransport = sessionTransport(["start_session": [.response(sessionResponse())], "get_own_session": [.held]])
        let old = try sessionComposition(oldTransport, defaults: defaults)
        await old.waitForRestoration()
        _ = try await old.sessionAdapter.actions().startSession()
        await assertFlag(old, true)
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
        try await appBackendEventually { !composition.sessionAdapter.stopPending }
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        await assertFlag(composition, false)
        let count = await transport.count("set_discovery")
        XCTAssertEqual(count, 2)
    }

    func testDiscoveryEnableFinishesQueuedDisableBeforeEnablingAndPermittingStart() async throws {
        let transport = sessionTransport(["start_session": [.response(sessionResponse()), .response(sessionResponse(id: "00000000-0000-0000-0000-000000000445"))],
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
        let defaults = appBackendDefaults()
        let store = FailingAppSessionStore(session: try appBackendTestSession())
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "get_own_session": [.response(sessionError("not_authenticated", status: 401))],
            "token": [.response(HTTPResponse(data: Data("{\"error_code\":\"refresh_token_not_found\"}".utf8), statusCode: 400))]])
        let composition = try sessionComposition(transport, store: store, defaults: defaults)
        await composition.waitForRestoration()
        let actions = composition.sessionAdapter.actions()
        _ = try await actions.startSession()
        do { _ = try await actions.refreshSession(); XCTFail("Dead authorization must fail") } catch { }
        await assertFlag(composition, false)
        XCTAssertEqual(composition.account.state, .signedOut)
        let stored = await store.stored
        XCTAssertNil(stored)
        XCTAssertFalse(composition.sessionAdapter.stopPending)
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        let stops = await transport.count("stop_session")
        XCTAssertEqual(stops, 0)
    }

    func testAuthorizationLossOutsideAdapterClearsFlagBeforeCredentialDeletion() async throws {
        let defaults = appBackendDefaults()
        let store = SessionCredentialClearGate(session: try appBackendTestSession())
        let transport = sessionTransport(["start_session": [.response(sessionResponse())],
            "get_own_session": [.response(sessionError("not_authenticated", status: 401))],
            "token": [.response(HTTPResponse(data: Data("{\"error_code\":\"refresh_token_not_found\"}".utf8), statusCode: 400))]])
        let composition = try sessionComposition(transport, store: store, defaults: defaults)
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
        XCTAssertTrue(pendingStopKeys(defaults).isEmpty)
        let stops = await transport.count("stop_session")
        XCTAssertEqual(stops, 0)
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
            let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(), notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
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

private func sessionResponse(server: Int = 1000, expiry: Int = 8200,
    id: String = "00000000-0000-0000-0000-000000000444") -> HTTPResponse {
    sessionJSON(["session_id": id, "starts_at": 1000,
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
    online: (@MainActor () -> Bool)? = { true },
    network: SessionNetworkAvailability? = nil,
    tokens: any TokenBatchStore = InMemoryTokenBatchStore(),
    queue: any ReceiptQueue = InMemoryReceiptQueue()) throws -> AppComposition {
    AppComposition(configuration: configuration, defaults: defaults ?? appBackendDefaults(), notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(), transport: transport,
        keychain: keychain, sessionStore: try store ?? InMemorySessionStore(session: appBackendTestSession()),
        serverTokenStore: tokens, signedOutTokenStore: InMemoryTokenBatchStore(),
        queueOpener: { queue }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow },
        sessionIsOnline: online, sessionNetwork: network, timeZone: { "Asia/Tokyo" })
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

@MainActor
private func pendingStopKeys(_ defaults: UserDefaults) -> [String] {
    defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(PendingSessionStopStore.prefix) }.sorted()
}

@MainActor
private func seedUnresolvedStop(_ defaults: UserDefaults) throws {
    let owner = try JSONDecoder().decode(BackendStorageOwner.self,
        from: XCTUnwrap(defaults.data(forKey: BackendStorageBinding.ownerKey)))
    let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000444"))
    try PendingSessionStopStore(defaults: defaults).save(.init(sessionID: id,
        expiresAt: appBackendTestNow.addingTimeInterval(7200)), owner: owner)
}
