import Foundation
import Security
import EncounterDomain

/// Reads and replaces opaque bytes without exposing token material in errors.
public protocol KeychainClient: Sendable {
    func read(service: String, account: String) async throws -> Data?
    func writeOrReplace(_ data: Data, service: String, account: String) async throws
    func delete(service: String, account: String) async throws
}

/// Contains only an operation's status or a generic codec failure, never token bytes.
public enum TokenBatchStorageError: Error, Equatable, Sendable {
    case keychainStatus(Int32)
    case corruptedBatch
    case encodingFailed
}

/// Stores device-only generic passwords accessible after the first unlock, without iCloud sync.
public struct SystemKeychainClient: KeychainClient {
    public init() {}

    public func read(service: String, account: String) async throws -> Data? {
        let query = Self.readQuery(service: service, account: account)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenBatchStorageError.keychainStatus(status) }
        guard let data = result as? Data else { throw TokenBatchStorageError.corruptedBatch }
        return data
    }

    public func writeOrReplace(_ data: Data, service: String, account: String) async throws {
        let query = Self.itemQuery(service: service, account: account)
        let attributes = Self.writeAttributes(data)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let newItem = Self.addAttributes(data, service: service, account: account)
            status = SecItemAdd(newItem as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw TokenBatchStorageError.keychainStatus(status) }
    }

    public func delete(service: String, account: String) async throws {
        let status = SecItemDelete(Self.itemQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenBatchStorageError.keychainStatus(status)
        }
    }

    static func readQuery(service: String, account: String) -> [String: Any] {
        var query = itemQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    static func writeAttributes(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }

    static func addAttributes(_ data: Data, service: String, account: String) -> [String: Any] {
        itemQuery(service: service, account: account).merging(writeAttributes(data)) { _, replacement in replacement }
    }

    static func itemQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}

/// Replaces whole JSON batches and rejects corrupt stored values without partial recovery.
public struct KeychainTokenBatchStore: TokenBatchStore {
    private let client: any KeychainClient
    private let service: String
    private let account: String

    public init(service: String = "EncounterStorage.TokenBatch", account: String = "current",
                client: any KeychainClient = SystemKeychainClient()) {
        self.client = client
        self.service = service
        self.account = account
    }

    public func load() async throws -> TokenBatch? {
        guard let data = try await client.read(service: service, account: account) else { return nil }
        do { return try JSONDecoder().decode(TokenBatch.self, from: data) }
        catch { throw TokenBatchStorageError.corruptedBatch }
    }

    public func save(_ batch: TokenBatch) async throws {
        let data: Data
        do { data = try JSONEncoder().encode(batch) }
        catch { throw TokenBatchStorageError.encodingFailed }
        try await client.writeOrReplace(data, service: service, account: account)
    }

    public func clear() async throws {
        try await client.delete(service: service, account: account)
    }
}
