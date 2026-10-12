import EncounterBackend
import EncounterStorage
import Foundation

/// SystemKeychainClient writes after-first-unlock, device-only, nonsynchronizing items.
struct KeychainSessionStore: SessionStore {
    static let service = "EngineerEncounters.Backend.Session"
    private let client: any KeychainClient
    private let backendIdentity: String

    init(backendIdentity: String, client: any KeychainClient = SystemKeychainClient()) {
        self.backendIdentity = backendIdentity
        self.client = client
    }

    private struct StoredSession: Codable {
        let backendIdentity: String?
        let accessCredential: String
        let refreshCredential: String
        let expiresAt: Date
        let userID: UUID
    }

    func load() async throws -> BackendSession? {
        do {
            guard let data = try await client.read(service: Self.service, account: "current") else { return nil }
            let value = try JSONDecoder().decode(StoredSession.self, from: data)
            guard value.backendIdentity == backendIdentity else { throw BackendError.notAuthenticated }
            return try BackendSession(accessCredential: value.accessCredential,
                                      refreshCredential: value.refreshCredential,
                                      expiresAt: value.expiresAt, userID: value.userID)
        } catch BackendError.notAuthenticated { throw BackendError.notAuthenticated }
        catch { throw BackendError.storageFailure }
    }

    func save(_ session: BackendSession) async throws {
        do {
            let data = try JSONEncoder().encode(StoredSession(
                backendIdentity: backendIdentity,
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

/// A new provider session cannot overwrite the current account until local cleanup completes.
actor StagedSessionStore: SessionStore {
    private var session: BackendSession?
    private var persistentStore: (any SessionStore)?

    func load() async throws -> BackendSession? { session }
    func save(_ session: BackendSession) async throws {
        self.session = session
        try await persistentStore?.save(session)
    }
    func clear() async throws {
        session = nil
        try await persistentStore?.clear()
    }
    func activate(_ store: any SessionStore) async throws {
        persistentStore = store
        if let session { try await store.save(session) }
    }
}
