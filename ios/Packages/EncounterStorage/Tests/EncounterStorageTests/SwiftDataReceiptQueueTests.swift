import Foundation
import XCTest
import EncounterDomain
import EncounterDomainTestSupport
@testable import EncounterStorage

@MainActor
final class SwiftDataReceiptQueueTests: XCTestCase {
    func testInMemoryContract() async throws {
        try await ReceiptQueueContract.checkAll(on: SwiftDataReceiptQueue.inMemory())
    }

    func testFileBackedContract() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ReceiptQueueContract.checkAll(on: SwiftDataReceiptQueue.fileBacked(directory: directory))
    }

    func testSavedEvidenceOrderAndTerminalIdentitySurviveAnotherInstance() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SwiftDataReceiptQueue.fileBacked(directory: directory)
        let acknowledged = EncounterSamples.receipt(1)
        var retained = EncounterSamples.receipt(3)
        retained.checkpoint = EncounterSamples.receipt(4).start
        retained.observedDuration = 120
        retained.sessionFlag = true
        retained.isFinalEvidence = true
        retained.uploadStatus = .acceptedAsCandidate
        let secondReceipt = EncounterSamples.receipt(2)
        try await first.enqueue(acknowledged)
        try await first.enqueue(EncounterSamples.receipt(3))
        try await first.enqueue(secondReceipt)
        try await first.update(retained)
        try await first.acknowledge(acknowledged.id)

        let reopened = try SwiftDataReceiptQueue.fileBacked(directory: directory)
        let pending = try await reopened.pending()
        XCTAssertEqual(pending, [retained, secondReceipt])
        try await reopened.enqueue(acknowledged)
        do {
            try await reopened.update(acknowledged)
            XCTFail("Terminal identity accepted an update")
        } catch {
            XCTAssertEqual(error as? ReceiptQueueError, .missingIdentity(acknowledged.id))
        }
        let afterRetry = try await reopened.pending()
        XCTAssertEqual(afterRetry, [retained, secondReceipt])
    }

    func testStoredTombstoneBlocksRetryUntilInclusiveExpiry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = EncounterSamples.receipt()
        let first = try SwiftDataReceiptQueue.fileBacked(directory: directory)
        try await first.enqueue(receipt)
        try await first.acknowledge(receipt.id)

        let queue = try SwiftDataReceiptQueue.fileBacked(directory: directory)
        try await queue.removeExpired(asOf: receipt.expiresAt.addingTimeInterval(-1))
        try await queue.acknowledge(receipt.id) // Repetition must not extend the original expiry.
        try await queue.enqueue(receipt)
        let blocked = try await queue.pending()
        XCTAssertTrue(blocked.isEmpty)

        try await queue.removeExpired(asOf: receipt.expiresAt)
        try await queue.enqueue(receipt)
        let reused = try await queue.pending()
        XCTAssertEqual(reused, [receipt])
        try await queue.removeExpired(asOf: receipt.expiresAt)
        let expired = try await queue.pending()
        XCTAssertTrue(expired.isEmpty)
    }

    func testUnseenAcknowledgementExpiresOneLifetimeAfterInjectedTime() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = EncounterSamples.receipt()
        let acknowledgementTime = receipt.start.observedAt.addingTimeInterval(600)
        let deadline = acknowledgementTime.addingTimeInterval(EncounterProtocol.receiptLifetime)
        let first = try SwiftDataReceiptQueue.fileBacked(directory: directory, now: { acknowledgementTime })
        try await first.acknowledge(receipt.id)

        let queue = try SwiftDataReceiptQueue.fileBacked(directory: directory, now: { deadline })
        try await queue.acknowledge(receipt.id)
        try await queue.removeExpired(asOf: deadline.addingTimeInterval(-1))
        try await queue.enqueue(receipt)
        let blocked = try await queue.pending()
        XCTAssertTrue(blocked.isEmpty)
        try await queue.removeExpired(asOf: deadline)
        try await queue.enqueue(receipt)
        let reused = try await queue.pending()
        XCTAssertEqual(reused, [receipt])
    }

    func testRemoveAllClearsDurableTombstones() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SwiftDataReceiptQueue.fileBacked(directory: directory)
        let receipt = EncounterSamples.receipt()
        try await first.enqueue(receipt)
        try await first.acknowledge(receipt.id)
        try await first.removeAll()
        let reopened = try SwiftDataReceiptQueue.fileBacked(directory: directory)
        try await reopened.enqueue(receipt)
        let pending = try await reopened.pending()
        XCTAssertEqual(pending, [receipt])
    }

    func testUpdatesRejectEachChangedInitialEvidenceField() async throws {
        let queue = try SwiftDataReceiptQueue.inMemory()
        let original = EncounterSamples.receipt()
        try await queue.enqueue(original)
        let alternatives = [
            EncounterReceipt(id: original.id, protocolVersion: original.protocolVersion + 1,
                             role: original.role, exchangeNonce: original.exchangeNonce, start: original.start),
            EncounterReceipt(id: original.id, role: .peripheral,
                             exchangeNonce: original.exchangeNonce, start: original.start),
            EncounterReceipt(id: original.id, role: original.role,
                             exchangeNonce: EncounterSamples.nonce(seed: 9), start: original.start),
            EncounterReceipt(id: original.id, role: original.role, exchangeNonce: original.exchangeNonce,
                             priorExchangeNonce: EncounterSamples.nonce(seed: 9), start: original.start),
            EncounterReceipt(id: original.id, role: original.role, exchangeNonce: original.exchangeNonce,
                             start: EncounterSamples.receipt(2).start)
        ]
        for changed in alternatives {
            do {
                try await queue.update(changed)
                XCTFail("Initial evidence was overwritten")
            } catch {
                XCTAssertEqual(error as? ReceiptQueueError, .changedInitialEvidence(original.id))
            }
        }
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [original])
    }

    func testConcurrentDuplicateEnqueuesRemainIdempotent() async throws {
        let queue = try SwiftDataReceiptQueue.inMemory()
        let receipt = EncounterSamples.receipt()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { try await queue.enqueue(receipt) } }
            try await group.waitForAll()
        }
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [receipt])
    }

    func testCreationThrowsForFileInsteadOfDirectory() throws {
        let location = temporaryDirectory()
        try Data().write(to: location)
        defer { try? FileManager.default.removeItem(at: location) }
        XCTAssertThrowsError(try SwiftDataReceiptQueue.fileBacked(directory: location))
    }

    func testUnwritableDirectoryRejectsCreationAndEnqueueWithoutStoring() async throws {
        let directory = temporaryDirectory()
        let queue = try SwiftDataReceiptQueue.fileBacked(directory: directory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try SwiftDataReceiptQueue.fileBacked(directory: directory))
        do {
            try await queue.enqueue(EncounterSamples.receipt())
            XCTFail("Enqueue reported success with an unwritable store")
        } catch {
            XCTAssertTrue(error is ReceiptStorageError)
        }
        let pending = try await queue.pending()
        XCTAssertTrue(pending.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let reopened = try SwiftDataReceiptQueue.fileBacked(directory: directory)
        let persisted = try await reopened.pending()
        XCTAssertTrue(persisted.isEmpty)
        try await queue.enqueue(EncounterSamples.receipt())
        let recovered = try await queue.pending()
        XCTAssertEqual(recovered, [EncounterSamples.receipt()])
    }

    #if os(iOS)
    func testDirectoryStoreAndSidecarsHaveAfterFirstUnlockProtection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try SwiftDataReceiptQueue.fileBacked(directory: directory)
        try await queue.enqueue(EncounterSamples.receipt())
        let store = directory.appendingPathComponent("receipts.store").path
        for path in [directory.path, store, store + "-wal", store + "-shm"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        }
    }
    #endif

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
