import EncounterBackend
import EncounterStorage
import Foundation

/// SystemKeychainClient writes after-first-unlock, device-only, nonsynchronizing items.
struct KeychainSessionStore: SessionStore {
    static let service = "EngineerEncounters.Backend.Session"
    private let client: any KeychainClient

    init(client: any KeychainClient = SystemKeychainClient()) { self.client = client }

    private struct StoredSession: Codable {
        let accessCredential: String
        let refreshCredential: String
        let expiresAt: Date
        let userID: UUID
    }

    func load() async throws -> BackendSession? {
        do {
            guard let data = try await client.read(service: Self.service, account: "current") else { return nil }
            let value = try JSONDecoder().decode(StoredSession.self, from: data)
            return try BackendSession(accessCredential: value.accessCredential,
                                      refreshCredential: value.refreshCredential,
                                      expiresAt: value.expiresAt, userID: value.userID)
        } catch { throw BackendError.storageFailure }
    }

    func save(_ session: BackendSession) async throws {
        do {
            let data = try JSONEncoder().encode(StoredSession(
                accessCredential: session.accessCredential, refreshCredential: session.refreshCredential,
                expiresAt: session.expiresAt, userID: session.userID
            ))
            try await client.writeOrReplace(data, service: Self.service, account: "current")
        } catch { throw BackendError.storageFailure }
    }

    func clear() async throws {
        do { try await client.delete(service: Self.service, account: "current") }
        catch { throw BackendError.storageFailure }
    }
}
