import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EncounterBackend

@MainActor
final class RedirectTests: XCTestCase {
    private let location = URL(string: "https://another-origin.example/collect")!

    func testRealURLSessionTransportRefusesURLProtocolRedirectWithoutContactingTarget() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionHTTPTransport(session: session)
        for status in [307, 308] {
            RedirectURLProtocol.requests.reset()
            var request = URLRequest(url: URL(string: "https://redirect-stub.example/\(status)")!, timeoutInterval: 2)
            request.httpMethod = "POST"
            request.httpBody = Data("synthetic-body".utf8)
            request.setValue("Bearer synthetic-test-token", forHTTPHeaderField: "Authorization")
            // Prove that the protocol stub really redirects an ordinary URLSession task.
            let (_, followed) = try await session.data(for: request)
            XCTAssertEqual((followed as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(RedirectURLProtocol.requests.hosts, ["redirect-stub.example", "redirect-target.example"])
            RedirectURLProtocol.requests.reset()
            let response = try await transport.sendWithoutRedirects(request)
            XCTAssertEqual(response.statusCode, status)
            XCTAssertEqual(RedirectURLProtocol.requests.hosts, ["redirect-stub.example"])
            do { _ = try await transport.send(request); XCTFail("Credential transport must reject redirect status") }
            catch { XCTAssertEqual(error as? BackendError, .transportFailure) }
            XCTAssertEqual(RedirectURLProtocol.requests.hosts, ["redirect-stub.example", "redirect-stub.example"])
        }
    }

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

private final class RedirectRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var hosts: [String] { lock.withLock { values } }
    func append(_ host: String) { lock.withLock { values.append(host) } }
    func reset() { lock.withLock { values = [] } }
}

private final class RedirectURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = RedirectRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.append(url.host!)
        if url.host == "redirect-stub.example" {
            let target = URL(string: "https://redirect-target.example/collect")!
            let response = HTTPURLResponse(url: url, statusCode: Int(url.lastPathComponent)!,
                httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var redirected = request
            redirected.url = target
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("redirect-response".utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("unexpected-follow".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
