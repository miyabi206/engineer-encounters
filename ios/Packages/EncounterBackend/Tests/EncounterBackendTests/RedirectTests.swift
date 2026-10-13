import Foundation
import XCTest
@testable import EncounterBackend

@MainActor
final class RedirectTests: XCTestCase {
    private let location = URL(string: "https://another-origin.example/collect")!

    func testAuthRequestsRefuse307And308WithoutInstallingOrClearingSessions() async throws {
        for status in [307, 308] {
            for path in ["token", "signup", "logout"] {
                let original: BackendSession? = path == "logout" ? try testSession() : nil
                let store = InMemorySessionStore(session: original)
                let transport = StubTransport([
                    .redirect(HTTPResponse(data: authResponse().data, statusCode: status), location: location),
                    .response(authResponse())
                ])
                let manager = testManager(transport: transport, store: store)
                let auth = try AuthRequest(path: path, body: Data(#"{"id_token":"sign-in-credential"}"#.utf8))
                do { _ = try await manager.establish(using: auth); XCTFail("Redirect must fail") }
                catch { XCTAssertEqual(error as? BackendError, .transportFailure, "\(path): \(status)") }
                let requests = await transport.recorded()
                let refusals = await transport.redirectRefusalCount()
                let saved = try await store.load()
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(refusals, 1)
                XCTAssertEqual(requests.first?.url?.host, "backend.example")
                XCTAssertEqual(saved, original)
                if let original {
                    let current = try await manager.session()
                    XCTAssertEqual(current, original)
                } else {
                    do { _ = try await manager.session(); XCTFail("Nothing may be installed") }
                    catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
                }
            }
        }
    }

    func testRefreshRedirectDoesNotClearOrReplaceTheSession() async throws {
        for status in [307, 308] {
            let original = try testSession()
            let store = InMemorySessionStore(session: original)
            let transport = StubTransport([
                .redirect(jsonResponse(#"{"error":"invalid_grant","error_code":"session_expired"}"#, status: status), location: location),
                .response(authResponse())
            ])
            let manager = testManager(transport: transport, store: store)
            do { _ = try await manager.refresh(); XCTFail("Redirect must fail") }
            catch { XCTAssertEqual(error as? BackendError, .transportFailure) }
            let requests = await transport.recorded()
            let refusals = await transport.redirectRefusalCount()
            let saved = try await store.load()
            let current = try await manager.session()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(refusals, 1)
            XCTAssertEqual(saved, original)
            XCTAssertEqual(current, original)
        }
    }

    func testPKCEExchangeRedirectDoesNotInstallCredentials() async throws {
        for status in [307, 308] {
            let original = try testSession()
            let store = InMemorySessionStore(session: original)
            let transport = StubTransport([
                .response(jsonResponse(#"{"url":"https://github.com/login/oauth/authorize?state=oauth-state"}"#)),
                .redirect(HTTPResponse(data: authResponse().data, statusCode: status), location: location),
                .response(authResponse())
            ])
            let manager = testManager(transport: transport, store: store)
            _ = try await manager.beginGitHubLink()
            do {
                _ = try await manager.completeGitHubLink(from: URL(string: "engineer-encounters://auth/github?code=auth-code")!)
                XCTFail("Redirect must fail")
            } catch { XCTAssertEqual(error as? BackendError, .transportFailure) }
            let requests = await transport.recorded()
            let refusals = await transport.redirectRefusalCount()
            let saved = try await store.load()
            let current = try await manager.session()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(refusals, 2)
            XCTAssertTrue(requests.allSatisfy { $0.url?.host == "backend.example" })
            XCTAssertEqual(saved, original)
            XCTAssertEqual(current, original)
        }
    }

    func testRPCAndEdgeRedirectsIgnoreAuthenticationErrorsAndNeverRetry() async throws {
        for status in [307, 308] {
            for edge in [false, true] {
                let original = try testSession()
                let store = InMemorySessionStore(session: original)
                let response = edge ? edgeFailure("not_authenticated", status: status)
                    : jsonResponse(#"{"message":"not_authenticated"}"#, status: status)
                let transport = StubTransport([.redirect(response, location: location), .response(authResponse())])
                let manager = testManager(transport: transport, store: store)
                do {
                    if edge {
                        let client = EdgeFunctionClient(configuration: testConfiguration(), transport: transport, sessions: manager)
                        let _: RPCResult = try await client.call("function", parameters: RPCParameters(display_name: "Name"))
                    } else {
                        let client = RemoteProcedureClient(configuration: testConfiguration(), transport: transport, sessions: manager)
                        try await client.call("procedure", parameters: RPCParameters(display_name: "Name"))
                    }
                    XCTFail("Redirect must fail")
                } catch { XCTAssertEqual(error as? BackendError, .transportFailure) }
                let requests = await transport.recorded()
                let refusals = await transport.redirectRefusalCount()
                let saved = try await store.load()
                let current = try await manager.session()
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(refusals, 1)
                XCTAssertEqual(requests.first?.url?.host, "backend.example")
                XCTAssertEqual(saved, original)
                XCTAssertEqual(current, original)
            }
        }
    }
}
