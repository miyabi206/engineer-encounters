import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Session credentials with redacted diagnostics and reflection.
public struct BackendSession: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let accessCredential: String
    public let refreshCredential: String
    public let expiresAt: Date
    public let userID: UUID

    public init(accessCredential: String, refreshCredential: String, expiresAt: Date, userID: UUID) throws {
        guard BackendConfiguration.isHeaderValue(accessCredential),
              BackendConfiguration.isHeaderValue(refreshCredential),
              expiresAt.timeIntervalSince1970.isFinite else { throw BackendError.invalidResponse }
        self.accessCredential = accessCredential
        self.refreshCredential = refreshCredential
        self.expiresAt = expiresAt
        self.userID = userID
    }

    public var description: String { "BackendSession(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Replaceable credential persistence, composed with device storage by the app.
public protocol SessionStore: Sendable {
    func load() async throws -> BackendSession?
    func save(_ session: BackendSession) async throws
    func clear() async throws
}

/// Ephemeral credential store for tests and nonpersistent clients.
public actor InMemorySessionStore: SessionStore, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var session: BackendSession?
    public init(session: BackendSession? = nil) { self.session = session }
    public func load() async throws -> BackendSession? { session }
    public func save(_ session: BackendSession) async throws { self.session = session }
    public func clear() async throws { session = nil }
    public nonisolated var description: String { "InMemorySessionStore(<redacted>)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Caller-supplied Auth operation, relative to /auth/v1/, with redacted request material.
public struct AuthRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let path: String
    public let method: String
    public let body: Data
    public let queryItems: [URLQueryItem]

    public init(path: String, method: String = "POST", body: Data, queryItems: [URLQueryItem] = []) throws {
        guard !path.isEmpty, path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
            }
        }), ["POST", "PUT", "PATCH", "GET", "DELETE"].contains(method) else { throw BackendError.invalidRequest }
        self.path = path
        self.method = method
        self.body = body
        self.queryItems = queryItems
    }

    public var description: String { "AuthRequest(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Establishes sessions and coalesces expiry and unauthorized refreshes without timers.
public actor SessionManager: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let configuration: BackendConfiguration
    private let transport: any HTTPTransport
    private let store: any SessionStore
    private let now: @Sendable () -> Date
    private let refreshLeeway: TimeInterval
    private var cached: BackendSession?
    private var loaded = false
    private var generation = UUID()
    private var loading: Task<BackendSession?, any Error>?
    private var refreshFlight: (id: UUID, task: Task<BackendSession, any Error>)?
    private var persistence: Task<Void, any Error>?
    private var pendingIdentityLink: PendingIdentityLink?
    private var identityLinkOperation: UUID?

    private struct PendingIdentityLink {
        let id: UUID
        let epoch: UUID
        let accountID: UUID
        let callback: URL
        let verifier: String
        var state: String?
    }

    struct Authorization: Sendable {
        let session: BackendSession
        let epoch: UUID
    }

    func authorization(for backend: BackendConfiguration? = nil) async throws -> Authorization {
        guard backend == nil || backend == configuration else { throw BackendError.invalidRequest }
        let value = try await session()
        guard cached?.userID == value.userID else { throw BackendError.notAuthenticated }
        return Authorization(session: value, epoch: generation)
    }

    func validate(_ authorization: Authorization) throws {
        guard generation == authorization.epoch, cached?.userID == authorization.session.userID else {
            throw BackendError.notAuthenticated
        }
    }

    public init(configuration: BackendConfiguration, transport: any HTTPTransport,
                store: any SessionStore, refreshLeeway: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.transport = transport
        self.store = store
        self.refreshLeeway = refreshLeeway.isFinite ? max(0, refreshLeeway) : 60
        self.now = now
    }

    /// Sends a provider-neutral Auth request and keeps the returned session with best-effort persistence.
    public func establish(using auth: AuthRequest) async throws -> BackendSession {
        invalidate()
        let epoch = generation
        let session = try await Self.fetch(auth, configuration: configuration, transport: transport, now: now, bearer: nil)
        return try await commit(session, epoch: epoch)
    }

    /// Produces the manual-link authorization URL; opening the browser belongs to the app.
    public func beginGitHubLink() async throws -> URL {
        try await beginIdentityLink(provider: "github", callback: URL(string: "engineer-encounters://auth/github")!)
    }

    /// Exchanges one pending callback without ever installing a different account's session.
    public func completeGitHubLink(from callback: URL) async throws -> BackendSession {
        try await completeIdentityLink(from: callback)
    }

    /// Discards only the in-memory linking attempt, including an in-flight exchange.
    public func cancelGitHubLink() {
        pendingIdentityLink = nil
        identityLinkOperation = nil
    }

    private func beginIdentityLink(provider: String, callback: URL) async throws -> URL {
        guard identityLinkOperation == nil else { throw BackendError.invalidRequest }
        let authorization = try await authorization()
        guard identityLinkOperation == nil else { throw BackendError.invalidRequest }
        let id = UUID()
        let verifier = Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        var pending = PendingIdentityLink(id: id, epoch: authorization.epoch, accountID: authorization.session.userID,
                                          callback: callback, verifier: verifier, state: nil)
        identityLinkOperation = id
        do {
            let auth = try AuthRequest(path: "user/identities/authorize", method: "GET", body: Data(), queryItems: [
                URLQueryItem(name: "provider", value: provider),
                URLQueryItem(name: "redirect_to", value: callback.absoluteString),
                URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
                URLQueryItem(name: "code_challenge_method", value: "s256"),
                URLQueryItem(name: "skip_http_redirect", value: "true")
            ])
            let response = try await Self.send(auth, configuration: configuration, transport: transport,
                                               bearer: authorization.session.accessCredential, followsRedirects: false)
            try Task.checkCancellation()
            try validate(authorization)
            guard identityLinkOperation == id else { throw BackendError.invalidRequest }
            guard (200..<300).contains(response.statusCode) else { throw BackendError.httpFailure(statusCode: response.statusCode) }
            struct Result: Decodable { let url: String }
            guard let result = try? JSONDecoder().decode(Result.self, from: response.data),
                  let parts = URLComponents(string: result.url), parts.scheme == "https", parts.host != nil,
                  parts.user == nil, parts.password == nil, let url = parts.url else { throw BackendError.invalidResponse }
            let states = (parts.queryItems ?? []).filter { $0.name == "state" }
            guard states.count <= 1, states.first.map({ !($0.value ?? "").isEmpty }) ?? true else {
                throw BackendError.invalidResponse
            }
            pending.state = states.first?.value
            pendingIdentityLink = pending
            return url
        } catch {
            if identityLinkOperation == id { cancelGitHubLink() }
            throw error
        }
    }

    private func completeIdentityLink(from callback: URL) async throws -> BackendSession {
        guard let pending = pendingIdentityLink else { throw BackendError.invalidRequest }
        // Consume before any suspension so a duplicate callback cannot exchange twice.
        pendingIdentityLink = nil
        defer { if identityLinkOperation == pending.id { identityLinkOperation = nil } }
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == pending.callback.scheme, parts.host == pending.callback.host,
              parts.percentEncodedPath == pending.callback.path, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else { throw BackendError.invalidRequest }
        let query = parts.queryItems ?? []
        let codes = query.filter { $0.name == "code" }
        let states = query.filter { $0.name == "state" }
        guard !query.contains(where: { $0.name == "error" || $0.name == "error_code" }),
              codes.count == 1, let code = codes.first?.value, !code.isEmpty,
              states.count <= 1 else { throw BackendError.invalidRequest }
        // Supabase PKCE normally returns only code. Validate state whenever it is returned.
        if let state = states.first {
            guard let expected = pending.state, state.value == expected else { throw BackendError.invalidRequest }
        }
        guard generation == pending.epoch, cached?.userID == pending.accountID else { throw BackendError.notAuthenticated }
        struct Parameters: Encodable { let auth_code: String; let code_verifier: String }
        let auth = try AuthRequest(path: "token", body: JSONEncoder().encode(Parameters(auth_code: code, code_verifier: pending.verifier)),
                                   queryItems: [URLQueryItem(name: "grant_type", value: "pkce")])
        let result = try await Self.fetch(auth, configuration: configuration, transport: transport, now: now, bearer: nil)
        try Task.checkCancellation()
        guard generation == pending.epoch, cached?.userID == pending.accountID else { throw BackendError.notAuthenticated }
        guard identityLinkOperation == pending.id else { throw BackendError.invalidRequest }
        guard result.userID == pending.accountID else { throw BackendError.invalidResponse }
        // Provider credentials in the Auth body are intentionally never decoded.
        // A successful exchange supersedes any older refresh still in flight.
        invalidate()
        return try await commit(result, epoch: generation)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Returns a signed-in session, refreshing shortly before its expiry.
    public func session() async throws -> BackendSession {
        if let flight = refreshFlight { return try await finish(flight) }
        guard let session = try await load() else { throw BackendError.notAuthenticated }
        if session.expiresAt <= now().addingTimeInterval(refreshLeeway) { return try await refresh() }
        return session
    }

    /// Refreshes once; a newer credential already replacing a rejected session is reused.
    public func refresh(after rejectedSession: BackendSession? = nil) async throws -> BackendSession {
        if let flight = refreshFlight { return try await finish(flight) }
        guard let current = try await load() else { throw BackendError.notAuthenticated }
        // Loading can suspend, allowing another caller to start a refresh.
        if let flight = refreshFlight { return try await finish(flight) }
        if let rejectedSession, current != rejectedSession { return try await session() }
        struct Parameters: Encodable { let refresh_token: String }
        let body = try JSONEncoder().encode(Parameters(refresh_token: current.refreshCredential))
        let auth = try AuthRequest(path: "token", body: body,
                                   queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        let epoch = generation
        let id = UUID()
        let task = Task {
            let result = try await Self.fetch(auth, configuration: configuration, transport: transport,
                                              now: now, bearer: nil, isRefresh: true)
            guard result.userID == current.userID else { throw BackendError.notAuthenticated }
            return try await self.commit(result, epoch: epoch)
        }
        let flight = (id: id, task: task)
        refreshFlight = flight
        return try await finish(flight)
    }

    /// Invalidates in-flight work and removes all persisted credentials.
    public func clear() async throws {
        invalidate()
        cached = nil
        loaded = true
        try await persist(nil)
    }

    private func invalidate() {
        cancelGitHubLink()
        generation = UUID()
        loading?.cancel()
        loading = nil
        refreshFlight?.task.cancel()
        refreshFlight = nil
    }

    private func load() async throws -> BackendSession? {
        if loaded { return cached }
        let epoch = generation
        let task: Task<BackendSession?, any Error>
        if let loading { task = loading } else {
            task = Task { [store] in
                do { return try await store.load() } catch { throw BackendError.storageFailure }
            }
            loading = task
        }
        do {
            let value = try await task.value
            guard epoch == generation else { throw BackendError.notAuthenticated }
            if !loaded { cached = value; loaded = true }
            loading = nil
            return cached
        } catch {
            if epoch == generation { loading = nil }
            throw error
        }
    }

    private func finish(_ flight: (id: UUID, task: Task<BackendSession, any Error>)) async throws -> BackendSession {
        let epoch = generation
        do {
            let session = try await flight.task.value
            guard epoch == generation else { throw BackendError.notAuthenticated }
            if refreshFlight?.id == flight.id { refreshFlight = nil }
            return session
        } catch {
            if refreshFlight?.id == flight.id {
                refreshFlight = nil
                if error as? BackendError == .notAuthenticated { try await clear() }
            }
            throw error
        }
    }

    private func commit(_ session: BackendSession, epoch: UUID) async throws -> BackendSession {
        guard epoch == generation else { throw BackendError.notAuthenticated }
        cached = session
        loaded = true
        // Auth success remains usable when device persistence is unavailable.
        try? await persist(session)
        guard epoch == generation else { throw BackendError.notAuthenticated }
        return session
    }

    private func persist(_ session: BackendSession?) async throws {
        // Order asynchronous store writes so a slow save cannot undo a later clear.
        let previous = persistence
        let next = Task { [store] in
            _ = try? await previous?.value
            do {
                if let session { try await store.save(session) } else { try await store.clear() }
            } catch { throw BackendError.storageFailure }
        }
        persistence = next
        try await next.value
    }

    private static func fetch(_ auth: AuthRequest, configuration: BackendConfiguration,
                              transport: any HTTPTransport, now: @Sendable () -> Date,
                              bearer: String?, isRefresh: Bool = false) async throws -> BackendSession {
        let response = try await send(auth, configuration: configuration, transport: transport, bearer: bearer)
        guard (200..<300).contains(response.statusCode) else {
            if isRefresh, response.statusCode == 400 || response.statusCode == 401 {
                struct Failure: Decodable {
                    let error: String?
                    let error_code: String?
                    enum CodingKeys: String, CodingKey { case error, error_code }
                    init(from decoder: any Decoder) throws {
                        let fields = try decoder.container(keyedBy: CodingKeys.self)
                        error = try? fields.decode(String.self, forKey: .error)
                        error_code = try? fields.decode(String.self, forKey: .error_code)
                    }
                }
                let deadCodes: Set<String> = ["refresh_token_not_found", "refresh_token_already_used",
                                              "session_not_found", "session_expired", "user_not_found", "user_banned"]
                if let failure = try? JSONDecoder().decode(Failure.self, from: response.data),
                   failure.error == "invalid_grant" || failure.error_code.map(deadCodes.contains) == true {
                    throw BackendError.notAuthenticated
                }
            }
            throw BackendError.httpFailure(statusCode: response.statusCode)
        }
        struct AuthResponse: Decodable {
            struct User: Decodable { let id: UUID }
            let access_token: String
            let refresh_token: String
            let token_type: String
            let expires_in: Int64?
            let expires_at: Int64?
            let user: User
        }
        do {
            let value = try JSONDecoder().decode(AuthResponse.self, from: response.data)
            guard value.token_type.lowercased() == "bearer" else { throw BackendError.invalidResponse }
            let expiry: Date
            if let seconds = value.expires_in {
                guard seconds > 0, seconds < 9_007_199_254_740_992 else { throw BackendError.invalidResponse }
                expiry = now().addingTimeInterval(TimeInterval(seconds))
            } else if let seconds = value.expires_at {
                expiry = try WireSeconds(unixSeconds: seconds).date
            } else { throw BackendError.invalidResponse }
            guard expiry > now() else { throw BackendError.invalidResponse }
            return try BackendSession(accessCredential: value.access_token, refreshCredential: value.refresh_token,
                                      expiresAt: expiry, userID: value.user.id)
        } catch { throw BackendError.invalidResponse }
    }

    private static func send(_ auth: AuthRequest, configuration: BackendConfiguration,
                             transport: any HTTPTransport, bearer: String?, followsRedirects: Bool = true) async throws -> HTTPResponse {
        var components = URLComponents(url: configuration.endpoint("auth/v1/" + auth.path), resolvingAgainstBaseURL: false)!
        if !auth.queryItems.isEmpty { components.queryItems = auth.queryItems }
        guard let url = components.url else { throw BackendError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = auth.method
        request.httpBody = auth.body
        request.setValue(configuration.publicClientKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let response: HTTPResponse
        do {
            if followsRedirects { response = try await transport.send(request) }
            else { response = try await transport.sendWithoutRedirects(request) }
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw BackendError.transportFailure }
        return response
    }

    public nonisolated var description: String { "SessionManager(<redacted>)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
}
