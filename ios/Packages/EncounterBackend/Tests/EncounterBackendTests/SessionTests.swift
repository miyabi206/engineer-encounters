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
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
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
        let transport = StubTransport([.response(jsonResponse(#"{"message":"private credential"}"#, status: 400))])
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
}
