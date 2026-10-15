import EncounterBackend
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class BackendLinkTransportTests: XCTestCase {
    func testAuthorizationRedirectIsRefusedThroughBoundTransport() async throws {
        let defaults = appBackendDefaults()
        let binding = BackendStorageBinding(configuration: appBackendTestConfiguration(), defaults: defaults,
            cleanup: SessionCleanupMarker(defaults: defaults))
        try binding.observeAccount(appBackendTestUser)
        try binding.bind(binding.storageOwner(account: appBackendTestUser))
        let underlying = RedirectProbeTransport()
        let transport = BackendBoundTransport(transport: underlying, binding: binding)
        let sessions = SessionManager(configuration: appBackendTestConfiguration(), transport: transport,
            store: InMemorySessionStore(session: try appBackendTestSession()), now: { appBackendTestNow })
        do { _ = try await sessions.beginGitHubLink(); XCTFail("Redirect must reach Auth as a refusal") }
        catch {
            XCTAssertEqual(error as? BackendError, .transportFailure)
            XCTAssertNotEqual(error as? BackendError, .notAuthenticated, "Redirect failure must not sign the account out")
        }
        let counts = await underlying.counts()
        XCTAssertEqual(counts.normal, 0)
        XCTAssertEqual(counts.refused, 1)
        let session = try await sessions.session()
        XCTAssertEqual(session.userID, appBackendTestUser)
    }

    func testAuthenticatedGateCoversRPCAndEdgeAndAuthIdentityRequests() async throws {
        let defaults = appBackendDefaults()
        let binding = BackendStorageBinding(configuration: appBackendTestConfiguration(), defaults: defaults,
            cleanup: SessionCleanupMarker(defaults: defaults))
        // A prepared signed-out owner permits public Auth, but no account traffic.
        try binding.bind(binding.storageOwner(account: nil))
        let underlying = RedirectProbeTransport()
        let transport = BackendBoundTransport(transport: underlying, binding: binding)
        for path in ["rest/v1/rpc/list_own_links", "functions/v1/github-links", "auth/v1/user/identities/authorize",
                     "auth/v1/user", "auth/v1/token?grant_type=pkce",
                     "auth/v1/user/identities/00000000-0000-0000-0000-000000000444"] {
            for refusesRedirects in [false, true] {
                let request = URLRequest(url: URL(string: "https://backend.example/" + path)!)
                do {
                    if refusesRedirects { _ = try await transport.sendWithoutRedirects(request) }
                    else { _ = try await transport.send(request) }
                    XCTFail("Account request must be gated: \(path)")
                } catch { XCTAssertTrue(error is CancellationError) }
            }
        }
        let counts = await underlying.counts()
        XCTAssertEqual(counts.normal, 0)
        XCTAssertEqual(counts.refused, 0)
        try binding.observeAccount(appBackendTestUser)
        try binding.bind(binding.storageOwner(account: appBackendTestUser))
        _ = try await transport.send(URLRequest(url: URL(string: "https://backend.example/functions/v1/github-links")!))
        let allowed = await underlying.counts()
        XCTAssertEqual(allowed.normal, 1)
    }
}

private actor RedirectProbeTransport: HTTPTransport {
    private var normal = 0
    private var refused = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        normal += 1
        return HTTPResponse(data: Data(), statusCode: 200)
    }
    func sendWithoutRedirects(_ request: URLRequest) async throws -> HTTPResponse {
        refused += 1
        return HTTPResponse(data: Data(), statusCode: 302)
    }
    func counts() -> (normal: Int, refused: Int) { (normal, refused) }
}
