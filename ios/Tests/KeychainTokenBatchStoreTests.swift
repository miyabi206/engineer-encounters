import EncounterDomain
import EncounterStorage
import Foundation
import Security
import XCTest

final class KeychainTokenBatchStoreTests: XCTestCase {
    func testRealKeychainRoundTripAndDeletion() async throws {
        let store = KeychainTokenBatchStore(service: "EngineerEncounters.Tests.\(UUID().uuidString)")
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        let batch = try TokenBatch(windows: [TokenWindow(
            token: TemporaryToken(), validFrom: start,
            validUntil: start.addingTimeInterval(EncounterProtocol.tokenWindowDuration)
        )])
        do {
            try await store.save(batch)
            let loaded = try await store.load()
            XCTAssertEqual(loaded, batch)
            try await store.clear()
            let cleared = try await store.load()
            XCTAssertNil(cleared)
        } catch {
            try? await store.clear()
            if error as? TokenBatchStorageError == .keychainStatus(errSecMissingEntitlement) {
                throw XCTSkip("Keychain entitlement is unavailable in the unsigned simulator run (CODE_SIGNING_ALLOWED=NO).")
            }
            throw error
        }
    }
}
