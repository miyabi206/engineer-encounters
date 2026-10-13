import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import EncounterBackend

actor StubTransport: HTTPTransport {
    enum Step: Sendable {
        case response(HTTPResponse)
        case held(HTTPResponse)
        case redirect(HTTPResponse, location: URL)
        case failure
    }
    private var nonRedirectingRequests = 0
    private var steps: [Step]
    private var requests: [URLRequest] = []
    private var hold: CheckedContinuation<Void, Never>?
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    init(_ steps: [Step]) { self.steps = steps }

    func sendWithoutRedirects(_ request: URLRequest) async throws -> HTTPResponse {
        nonRedirectingRequests += 1
        return try await send(request, followsRedirects: false)
    }
    func redirectRefusalCount() -> Int { nonRedirectingRequests }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await send(request, followsRedirects: true)
    }

    private func send(_ request: URLRequest, followsRedirects: Bool) async throws -> HTTPResponse {
        requests.append(request)
        for (count, observer) in observers where requests.count >= count { observer.resume() }
        observers.removeAll { requests.count >= $0.0 }
        guard !steps.isEmpty else { throw BackendError.invalidResponse }
        let step = steps.removeFirst()
        switch step {
        case .response(let response): return response
        case let .redirect(response, location):
            guard followsRedirects else { return response }
            var redirected = request
            redirected.url = location
            return try await send(redirected, followsRedirects: true)
        case .held(let response):
            await withCheckedContinuation { hold = $0 }
            return response
        case .failure: throw TestFailure.sensitive("do-not-expose-credentials")
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func release() { hold?.resume(); hold = nil }
    func recorded() -> [URLRequest] { requests }
}

enum TestFailure: Error { case sensitive(String) }

let testNow = Date(timeIntervalSince1970: 1_800_000_000)
let testUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

func testConfiguration() -> BackendConfiguration {
    BackendConfiguration(address: "https://backend.example/base/", publicClientKey: "public-key")!
}

func testSession(expiresIn: TimeInterval = 3600, access: String = "old-access", refresh: String = "old-refresh") throws -> BackendSession {
    try BackendSession(accessCredential: access, refreshCredential: refresh,
                       expiresAt: testNow.addingTimeInterval(expiresIn), userID: testUserID)
}

func jsonResponse(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(data: Data(json.utf8), statusCode: status)
}

func authResponse(access: String = "new-access", refresh: String = "new-refresh", expiresIn: Int = 3600,
                  userID: UUID = testUserID) -> HTTPResponse {
    jsonResponse("""
    {"access_token":"\(access)","refresh_token":"\(refresh)","token_type":"bearer",
     "expires_in":\(expiresIn),"user":{"id":"\(userID.uuidString)"}}
    """)
}

func testManager(transport: any HTTPTransport, store: any SessionStore) -> SessionManager {
    SessionManager(configuration: testConfiguration(), transport: transport, store: store, now: { testNow })
}

struct RPCParameters: Encodable, Sendable { let display_name: String }
struct RPCResult: Decodable, Sendable, Equatable { let saved: Bool }

func serviceClient(_ transport: StubTransport) throws -> RemoteProcedureClient {
    RemoteProcedureClient(configuration: testConfiguration(), transport: transport,
                          sessions: testManager(transport: transport,
                                                store: InMemorySessionStore(session: try testSession())))
}
