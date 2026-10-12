import XCTest
import Foundation
import EncounterBackend

@MainActor
final class SessionTests: XCTestCase {
    func testConfigurationRejectsInvalidAddressesAndKeys() {
        for address in ["", "example.com", "ftp://example.com", "https://", "https://user:pass@example.com",
                        "https://example.com?secret=x", "https://example.com/#fragment", " https://example.com",
                        "https://example.com:0", "https://example.com:65536"] {
            XCTAssertNil(BackendConfiguration(address: address, publicClientKey: "key"), address)
        }
        for key in ["", "with space", "key\r\nInjected:yes", " key "] {
            XCTAssertNil(BackendConfiguration(address: "https://example.com", publicClientKey: key))
        }
        XCTAssertEqual(testConfiguration().address.absoluteString, "https://backend.example/base/")
        XCTAssertNotNil(BackendConfiguration(address: "http://localhost:54321", publicClientKey: "key"))
    }

    func testEstablishSendsCallerSuppliedRequestAndPersistsSession() async throws {
        let transport = StubTransport([.response(authResponse())])
        let store = InMemorySessionStore()
        let manager = testManager(transport: transport, store: store)
        let body = Data(#"{"provider":"example","credential":"test"}"#.utf8)
        let auth = try AuthRequest(path: "provider/session", body: body,
                                   queryItems: [URLQueryItem(name: "flow", value: "provider")])
        let session = try await manager.establish(using: auth)
        let stored = try await store.load()
        XCTAssertEqual(stored, session)
        XCTAssertEqual(session, try testSession(access: "new-access", refresh: "new-refresh"))
        let requests = await transport.recorded()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://backend.example/base/auth/v1/provider/session?flow=provider")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, body)
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testRefreshRequestAndExpiryLeeway() async throws {
        let original = try testSession(expiresIn: 60)
        let transport = StubTransport([.response(authResponse())])
        let store = InMemorySessionStore(session: original)
        let manager = testManager(transport: transport, store: store)
        let refreshed = try await manager.session()
        let requests = await transport.recorded()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://backend.example/base/auth/v1/token?grant_type=refresh_token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["refresh_token": "old-refresh"])
        XCTAssertEqual(refreshed.expiresAt, testNow.addingTimeInterval(3600))
        let saved = try await store.load()
        XCTAssertEqual(saved, refreshed)
        let second = try await manager.session()
        XCTAssertEqual(second, refreshed)
        let finalRequests = await transport.recorded()
        XCTAssertEqual(finalRequests.count, 1)
    }

    func testRefreshIsSingleFlightWithoutSleeping() async throws {
        let transport = StubTransport([.held(authResponse())])
        let manager = testManager(transport: transport, store: InMemorySessionStore(session: try testSession(expiresIn: 10)))
        let tasks = (0..<12).map { _ in Task { try await manager.session() } }
        await transport.waitForRequests(1)
        await transport.release()
        for task in tasks {
            let session = try await task.value
            XCTAssertEqual(session.accessCredential, "new-access")
        }
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testAlreadyRefreshedCredentialIsReusedForLateUnauthorizedResponse() async throws {
        let original = try testSession()
        let transport = StubTransport([.response(authResponse())])
        let manager = testManager(transport: transport, store: InMemorySessionStore(session: original))
        let refreshed = try await manager.refresh(after: original)
        let reused = try await manager.refresh(after: original)
        XCTAssertEqual(reused, refreshed)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testClearCannotBeUndoneByInFlightRefresh() async throws {
        let transport = StubTransport([.held(authResponse())])
        let store = InMemorySessionStore(session: try testSession(expiresIn: 10))
        let manager = testManager(transport: transport, store: store)
        let task = Task { try await manager.session() }
        await transport.waitForRequests(1)
        try await manager.clear()
        await transport.release()
        do { _ = try await task.value; XCTFail("Cleared refresh must fail") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        let saved = try await store.load()
        XCTAssertNil(saved)
        do { _ = try await manager.session(); XCTFail("Session must be absent") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
    }

    func testInvalidRefreshClearsStoredSession() async throws {
        let transport = StubTransport([.response(jsonResponse(#"{"error":"invalid_grant"}"#, status: 400))])
        let store = InMemorySessionStore(session: try testSession(expiresIn: 0))
        let manager = testManager(transport: transport, store: store)
        do { _ = try await manager.session(); XCTFail("Invalid refresh must fail") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        let saved = try await store.load()
        XCTAssertNil(saved)
    }

    func testAbsoluteExpiryAndMalformedAuthResponses() async throws {
        let valid = jsonResponse("""
        {"access_token":"access","refresh_token":"refresh","token_type":"bearer",
         "expires_at":1800003600,"user":{"id":"\(testUserID.uuidString)"}}
        """)
        let manager = testManager(transport: StubTransport([.response(valid)]), store: InMemorySessionStore())
        let auth = try AuthRequest(path: "token", body: Data("{}".utf8))
        let session = try await manager.establish(using: auth)
        XCTAssertEqual(session.expiresAt, testNow.addingTimeInterval(3600))
        for response in [authResponse(expiresIn: -1), authResponse(access: ""), jsonResponse("{}"),
                         jsonResponse(#"{"access_token":"private credential","user":{"id":"sensitive"}}"#)] {
            let invalidManager = testManager(transport: StubTransport([.response(response)]), store: InMemorySessionStore())
            do { _ = try await invalidManager.establish(using: auth); XCTFail("Malformed response must fail") }
            catch { XCTAssertEqual(error as? BackendError, .invalidResponse) }
        }
    }

    func testAuthPathValidationAndRedaction() throws {
        for path in ["", "../token", "/token", "token?secret=x", "token#x", "token//next", "%2e%2e/token"] {
            XCTAssertThrowsError(try AuthRequest(path: path, body: Data())) {
                XCTAssertEqual($0 as? BackendError, .invalidRequest)
            }
        }
        let session = try testSession()
        let auth = try AuthRequest(path: "token", body: Data("sensitive-body".utf8))
        let response = authResponse()
        for value in [session as Any, auth as Any, response as Any] {
            XCTAssertTrue(String(describing: value).contains("<redacted>"))
            XCTAssertTrue(String(reflecting: value).contains("<redacted>"))
            XCTAssertEqual(Mirror(reflecting: value).children.count, 0)
        }
    }

    func testOnlyExplicitDeadRefreshCredentialsClearTheSession() async throws {
        let deadCodes = ["refresh_token_not_found", "refresh_token_already_used", "session_not_found",
                         "session_expired", "user_not_found", "user_banned"]
        for status in [400, 401] {
            let bodies = [#"{"error":"invalid_grant"}"#, #"{"error":"invalid_grant","error_code":7}"#,
                          #"{"error":7,"error_code":"session_expired"}"#]
                + deadCodes.map { "{\"error_code\":\"\($0)\"}" }
            for body in bodies {
                let store = InMemorySessionStore(session: try testSession())
                let manager = testManager(transport: StubTransport([.response(jsonResponse(body, status: status))]), store: store)
                do { _ = try await manager.refresh(); XCTFail("Dead refresh must fail") }
                catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
                let saved = try await store.load()
                XCTAssertNil(saved)
            }
        }
    }

    func testOtherAuthFailuresKeepTheSession() async throws {
        let original = try testSession()
        let cases = [
            (400, "{}"), (401, "malformed"), (400, #"{"error":"invalid_request"}"#),
            (401, #"{"error_code":"unknown"}"#), (400, #"{"message":"invalid_grant"}"#),
            (403, #"{"error":"invalid_grant"}"#), (500, #"{"error_code":"session_expired"}"#)
        ]
        for (status, body) in cases {
            let store = InMemorySessionStore(session: original)
            let manager = testManager(transport: StubTransport([.response(jsonResponse(body, status: status))]), store: store)
            do { _ = try await manager.refresh(); XCTFail("Auth failure must fail") }
            catch { XCTAssertEqual(error as? BackendError, .httpFailure(statusCode: status)) }
            let saved = try await store.load()
            let current = try await manager.session()
            XCTAssertEqual(saved, original)
            XCTAssertEqual(current, original)
        }
        for (step, expected) in [(StubTransport.Step.failure, BackendError.transportFailure),
                                 (.response(jsonResponse("{}")), .invalidResponse)] {
            let store = InMemorySessionStore(session: original)
            let manager = testManager(transport: StubTransport([step]), store: store)
            do { _ = try await manager.refresh(); XCTFail("Refresh must fail") }
            catch { XCTAssertEqual(error as? BackendError, expected) }
            let saved = try await store.load()
            XCTAssertEqual(saved, original)
        }
    }

    func testFailedEstablishPreservesLoadedAndUnloadedPreviousSession() async throws {
        let original = try testSession()
        let auth = try AuthRequest(path: "provider/session", body: Data("{}".utf8))
        for preload in [false, true] {
            for step in [StubTransport.Step.failure, .response(jsonResponse("{}")),
                         .response(jsonResponse(#"{"error":"invalid_grant"}"#, status: 400)),
                         .response(jsonResponse("{}", status: 401))] {
                let store = InMemorySessionStore(session: original)
                let manager = testManager(transport: StubTransport([step]), store: store)
                if preload { _ = try await manager.session() }
                do { _ = try await manager.establish(using: auth); XCTFail("Establish must fail") }
                catch { XCTAssertNotNil(error as? BackendError) }
                let saved = try await store.load()
                let current = try await manager.session()
                XCTAssertEqual(saved, original)
                XCTAssertEqual(current, original)
            }
        }
    }

    func testEstablishInvalidatesAnOlderRefreshEvenWhenEstablishFails() async throws {
        let original = try testSession()
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let auth = try AuthRequest(path: "provider/session", body: Data("{}".utf8))
        for succeeds in [false, true] {
            for oldAnswer in [authResponse(), jsonResponse(#"{"error":"invalid_grant"}"#, status: 400)] {
                let answer = succeeds ? authResponse(access: "replacement", userID: otherID) : jsonResponse("{}", status: 400)
                let transport = StubTransport([.held(oldAnswer), .response(answer)])
                let store = InMemorySessionStore(session: original)
                let manager = testManager(transport: transport, store: store)
                let refreshing = Task { try await manager.refresh() }
                await transport.waitForRequests(1)
                var expected = original
                do { expected = try await manager.establish(using: auth); XCTAssertTrue(succeeds) }
                catch { XCTAssertFalse(succeeds); XCTAssertEqual(error as? BackendError, .httpFailure(statusCode: 400)) }
                await transport.release()
                do { _ = try await refreshing.value; XCTFail("Old refresh must be discarded") }
                catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
                let saved = try await store.load()
                let current = try await manager.session()
                XCTAssertEqual(saved, expected)
                XCTAssertEqual(current, expected)
            }
        }
    }

    func testAuthSessionsRemainUsableWhenSavingFails() async throws {
        for establishes in [false, true] {
            let store = ThrowingSessionStore(session: try testSession(), failure: .save)
            let transport = StubTransport([.response(authResponse())])
            let manager = testManager(transport: transport, store: store)
            let obtained: BackendSession
            if establishes {
                obtained = try await manager.establish(using: AuthRequest(path: "provider/session", body: Data("{}".utf8)))
            } else { obtained = try await manager.refresh() }
            let current = try await manager.session()
            XCTAssertEqual(current, obtained)
            XCTAssertEqual(obtained.accessCredential, "new-access")
            let requests = await transport.recorded()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testStoreLoadAndClearFailuresAreSanitizedAndClearStillErasesMemory() async throws {
        let loadStore = ThrowingSessionStore(session: try testSession(), failure: .load)
        let loadManager = testManager(transport: StubTransport([]), store: loadStore)
        do { _ = try await loadManager.session(); XCTFail("Load must fail") }
        catch { XCTAssertEqual(error as? BackendError, .storageFailure) }
        // Establish does not depend on successfully loading the previous session.
        let establishManager = testManager(transport: StubTransport([.response(authResponse())]), store: loadStore)
        _ = try await establishManager.establish(using: AuthRequest(path: "provider/session", body: Data("{}".utf8)))
        let current = try await establishManager.session()
        XCTAssertEqual(current.accessCredential, "new-access")
        for invalidRefresh in [false, true] {
            let store = ThrowingSessionStore(session: try testSession(), failure: .clear)
            let transport = StubTransport([.response(jsonResponse(#"{"error":"invalid_grant"}"#, status: 401))])
            let manager = testManager(transport: transport, store: store)
            _ = try await manager.session()
            do {
                if invalidRefresh { _ = try await manager.refresh() } else { try await manager.clear() }
                XCTFail("Clear must fail")
            } catch { XCTAssertEqual(error as? BackendError, .storageFailure) }
            do { _ = try await manager.session(); XCTFail("Cleared memory must stay empty") }
            catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        }
    }

    func testRelativeExpiryTakesPrecedenceOverServerAbsoluteExpiry() async throws {
        let auth = try AuthRequest(path: "provider/session", body: Data("{}".utf8))
        for absolute in [1_700_000_000, 1_900_000_000] {
            let response = jsonResponse("""
            {"access_token":"access","refresh_token":"refresh","token_type":"bearer",
             "expires_in":1234,"expires_at":\(absolute),"user":{"id":"\(testUserID.uuidString)"}}
            """)
            let manager = testManager(transport: StubTransport([.response(response)]), store: InMemorySessionStore())
            let session = try await manager.establish(using: auth)
            XCTAssertEqual(session.expiresAt, testNow.addingTimeInterval(1234))
        }
        let response = jsonResponse("""
        {"access_token":"access","refresh_token":"refresh","token_type":"bearer",
         "expires_in":0,"expires_at":1900000000,"user":{"id":"\(testUserID.uuidString)"}}
        """)
        let manager = testManager(transport: StubTransport([.response(response)]), store: InMemorySessionStore())
        do { _ = try await manager.establish(using: auth); XCTFail("Invalid relative expiry must fail") }
        catch { XCTAssertEqual(error as? BackendError, .invalidResponse) }
    }
}

private actor ThrowingSessionStore: SessionStore {
    enum Operation { case load, save, clear }
    private var session: BackendSession?
    private let failure: Operation
    init(session: BackendSession, failure: Operation) { self.session = session; self.failure = failure }
    func load() async throws -> BackendSession? {
        if failure == .load { throw TestFailure.sensitive("private-store-error") }
        return session
    }
    func save(_ session: BackendSession) async throws {
        if failure == .save { throw TestFailure.sensitive("private-store-error") }
        self.session = session
    }
    func clear() async throws {
        if failure == .clear { throw TestFailure.sensitive("private-store-error") }
        session = nil
    }
}
