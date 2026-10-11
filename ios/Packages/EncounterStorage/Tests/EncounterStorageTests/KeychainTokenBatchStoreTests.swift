import Foundation
import XCTest
import Security
import EncounterDomain
import EncounterDomainTestSupport
@testable import EncounterStorage

@MainActor
final class KeychainTokenBatchStoreTests: XCTestCase {
    func testSystemKeychainDictionariesAreDeviceOnlyAndNeverSynchronize() {
        let data = Data([1, 2, 3])
        let query = SystemKeychainClient.itemQuery(service: "service", account: "account")
        let read = SystemKeychainClient.readQuery(service: "service", account: "account")
        let add = SystemKeychainClient.addAttributes(data, service: "service", account: "account")
        let update = SystemKeychainClient.writeAttributes(data)
        for dictionary in [query, read, add] {
            XCTAssertEqual(dictionary[kSecClass as String] as? String, kSecClassGenericPassword as String)
            XCTAssertEqual(dictionary[kSecAttrService as String] as? String, "service")
            XCTAssertEqual(dictionary[kSecAttrAccount as String] as? String, "account")
            XCTAssertEqual(dictionary[kSecAttrSynchronizable as String] as? Bool, false)
        }
        for dictionary in [add, update] {
            XCTAssertEqual(dictionary[kSecValueData as String] as? Data, data)
            XCTAssertEqual(dictionary[kSecAttrAccessible as String] as? String,
                           kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        }
        XCTAssertEqual(Set(update.keys), Set([kSecValueData as String, kSecAttrAccessible as String]))
        XCTAssertEqual(read[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(read[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertNil(query[kSecValueData as String])
        XCTAssertNil(update[kSecClass as String])
    }

    func testMissingSaveReplaceAndIdempotentClear() async throws {
        let client = FakeKeychainClient()
        let store = KeychainTokenBatchStore(service: "test-service", account: "test-account", client: client)
        let missing = try await store.load()
        XCTAssertNil(missing)
        let first = try EncounterSamples.batch(count: 2)
        let replacement = try EncounterSamples.batch(count: 1)
        try await store.save(first)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, first)
        let raw = try await client.read(service: "test-service", account: "test-account")
        XCTAssertEqual(try JSONDecoder().decode(TokenBatch.self, from: XCTUnwrap(raw)), first)
        try await store.save(replacement)
        let replaced = try await store.load()
        XCTAssertEqual(replaced, replacement)
        try await store.clear()
        try await store.clear()
        let cleared = try await store.load()
        XCTAssertNil(cleared)
    }

    func testServiceAndAccountSeparateItems() async throws {
        let client = FakeKeychainClient()
        let store = KeychainTokenBatchStore(service: "a", account: "b", client: client)
        let batch = try EncounterSamples.batch(count: 1)
        try await store.save(batch)
        for (service, account) in [("a", "other"), ("other", "b")] {
            let other = KeychainTokenBatchStore(service: service, account: account, client: client)
            let absent = try await other.load()
            XCTAssertNil(absent)
            try await other.clear()
        }
        let retained = try await store.load()
        XCTAssertEqual(retained, batch)
    }

    func testCorruptedAndInvalidBatchesThrowWithoutExposingStoredBytes() async throws {
        let client = FakeKeychainClient()
        let store = KeychainTokenBatchStore(service: "test", account: "batch", client: client)
        let window = try EncounterSamples.batch(count: 1).windows[0]
        let encodedWindow = String(decoding: try JSONEncoder().encode(window), as: UTF8.self)
        let invalidBatches = [
            Data("private-token-material".utf8),
            Data("{\"windows\":[\(encodedWindow),\(encodedWindow)]}".utf8),
            Data("{\"windows\":[{\"token\":[1],\"validFrom\":0,\"validUntil\":900}]}".utf8)
        ]
        for data in invalidBatches {
            try await client.writeOrReplace(data, service: "test", account: "batch")
            do {
                _ = try await store.load()
                XCTFail("Corrupted batch was accepted")
            } catch {
                XCTAssertEqual(error as? TokenBatchStorageError, .corruptedBatch)
                XCTAssertFalse(String(describing: error).contains("private-token-material"))
                XCTAssertFalse(String(describing: error).contains(encodedWindow))
            }
            let unchanged = try await client.read(service: "test", account: "batch")
            XCTAssertEqual(unchanged, data)
        }
    }

    func testClientFailuresPropagateAndFailedReplacementPreservesBatch() async throws {
        let client = FakeKeychainClient()
        let store = KeychainTokenBatchStore(client: client)
        let original = try EncounterSamples.batch(count: 2)
        let replacement = try EncounterSamples.batch(count: 1)
        try await store.save(original)
        for operation in FakeKeychainClient.Operation.allCases {
            await client.fail(operation)
            do {
                switch operation {
                case .read: _ = try await store.load()
                case .write: try await store.save(replacement)
                case .delete: try await store.clear()
                }
                XCTFail("Client failure was swallowed")
            } catch {
                XCTAssertEqual(error as? FakeKeychainClient.Operation, operation)
            }
            await client.fail(nil)
            let retained = try await store.load()
            XCTAssertEqual(retained, original)
        }
    }
}

private actor FakeKeychainClient: KeychainClient {
    enum Operation: Error, CaseIterable { case read, write, delete }
    private struct Key: Hashable {
        let service: String
        let account: String
    }
    private var items: [Key: Data] = [:]
    private var failure: Operation?

    func fail(_ operation: Operation?) { failure = operation }

    func read(service: String, account: String) async throws -> Data? {
        if failure == .read { throw Operation.read }
        return items[Key(service: service, account: account)]
    }

    func writeOrReplace(_ data: Data, service: String, account: String) async throws {
        if failure == .write { throw Operation.write }
        items[Key(service: service, account: account)] = data
    }

    func delete(service: String, account: String) async throws {
        if failure == .delete { throw Operation.delete }
        items.removeValue(forKey: Key(service: service, account: account))
    }
}
