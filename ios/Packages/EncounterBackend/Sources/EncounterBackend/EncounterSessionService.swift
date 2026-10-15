import Foundation

/// Server ledger acknowledgement, separate from Auth credentials and local participation state.
public struct SessionTransfer: Decodable, Sendable, Equatable {
    public let sessionID: UUID
    public let startsAt: WireSeconds
    public let expiresAt: WireSeconds
    public let serverTime: WireSeconds
    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", startsAt = "starts_at", expiresAt = "expires_at", serverTime = "server_time"
    }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try fields.lowercaseUUID(forKey: .sessionID)
        startsAt = try fields.decode(WireSeconds.self, forKey: .startsAt)
        expiresAt = try fields.decode(WireSeconds.self, forKey: .expiresAt)
        serverTime = try fields.decode(WireSeconds.self, forKey: .serverTime)
    }
}

/// Stateless session calls. Pending stops and the session flag belong to the app.
public struct EncounterSessionService: Sendable {
    private let client: RemoteProcedureClient
    public init(client: RemoteProcedureClient) { self.client = client }
    public func startSession() async throws -> SessionTransfer {
        try await client.call("start_session", parameters: EmptyLinkParameters())
    }
    public func stopSession() async throws -> SessionTransfer? {
        try await client.call("stop_session", parameters: EmptyLinkParameters())
    }
    public func getOwnSession() async throws -> SessionTransfer? {
        try await client.call("get_own_session", parameters: EmptyLinkParameters())
    }
}
