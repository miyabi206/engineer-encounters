import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Calls authenticated JSON procedures and retries one unauthorized response after refresh.
public actor RemoteProcedureClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let configuration: BackendConfiguration
    private let transport: any HTTPTransport
    private let sessions: SessionManager

    public init(configuration: BackendConfiguration, transport: any HTTPTransport, sessions: SessionManager) {
        self.configuration = configuration
        self.transport = transport
        self.sessions = sessions
    }

    /// Encodes parameters and decodes the procedure's response without exposing failure payloads.
    public func call<Parameters: Encodable & Sendable, Response: Decodable & Sendable>(
        _ name: String, parameters: Parameters, as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let response = try await execute(name, parameters: parameters)
        do { return try JSONDecoder().decode(Response.self, from: response.data) }
        catch { throw BackendError.invalidResponse }
    }

    /// Executes procedures whose successful response has no JSON result.
    public func call<Parameters: Encodable & Sendable>(_ name: String, parameters: Parameters) async throws {
        _ = try await execute(name, parameters: parameters)
    }

    private func execute<Parameters: Encodable & Sendable>(_ name: String, parameters: Parameters) async throws -> HTTPResponse {
        guard let first = name.utf8.first, (97...122).contains(first),
              name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            throw BackendError.invalidRequest
        }
        let data: Data
        do { data = try JSONEncoder().encode(parameters) } catch { throw BackendError.invalidRequest }
        let authorization = try await sessions.authorization(for: configuration)
        var session = authorization.session
        for attempt in 0...1 {
            try await sessions.validate(authorization)
            var request = URLRequest(url: configuration.endpoint("rest/v1/rpc/" + name))
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue(configuration.publicClientKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer " + session.accessCredential, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response: HTTPResponse
            do { response = try await transport.send(request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw BackendError.transportFailure }
            try await sessions.validate(authorization)
            if (200..<300).contains(response.statusCode) { return response }
            let error: BackendError
            switch response.statusCode {
            case 408, 500..<600: error = .httpFailure(statusCode: response.statusCode)
            case 429: error = .rateLimited
            default: error = BackendError.response(response, procedure: name, parameters: data)
            }
            if attempt == 0, response.statusCode == 401 || error == .notAuthenticated {
                let refreshed = try await sessions.refresh(after: session)
                try await sessions.validate(authorization)
                guard refreshed.userID == session.userID else { throw BackendError.notAuthenticated }
                session = refreshed
            } else { throw error }
        }
        throw BackendError.notAuthenticated
    }

    public nonisolated var description: String { "RemoteProcedureClient(<redacted>)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
}
