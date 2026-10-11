import Foundation
import XCTest
import SwiftData
import EncounterDomain
import EncounterDomainTestSupport
@testable import EncounterStorage

@MainActor
final class SwiftDataReceiptQueueTests: XCTestCase {
    func testInMemoryContract() async throws {
        try await ReceiptQueueContract.checkAll(on: SwiftDataReceiptQueue.inMemory(now: { EncounterSamples.observationTime }))
    }

    func testFileBackedContract() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ReceiptQueueContract.checkAll(on: SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime }))
    }

    func testExpiryFiltersReadsAndTreatsExpiredIdentitiesAsMissingBeforeCleanup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = EncounterSamples.receipt(1)
        let retained = EncounterSamples.receipt(2, observedAt: EncounterSamples.observationTime.addingTimeInterval(60))
        let older = EncounterSamples.receipt(3, observedAt: EncounterSamples.observationTime.addingTimeInterval(-60))
        let later = EncounterSamples.receipt(4, observedAt: EncounterSamples.observationTime.addingTimeInterval(120))
        let receipts = [expired, retained, older, later]
        do {
            let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
            for receipt in receipts { try await queue.enqueue(receipt) }
            // Expiry must take precedence over decoding failure on update.
            try await queue.corruptPayload(for: older.id)
        }
        let time = expired.expiresAt
        let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { time })
        await queue.setWriteHooks(ReceiptQueueWriteHooks(beforeSave: { XCTFail("Pending attempted a save") }))
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [retained, later])
        let stored = try await queue.storedReceiptIdentities()
        XCTAssertEqual(stored, receipts.map(\.id))
        for receipt in [expired, older] {
            do {
                try await queue.update(receipt)
                XCTFail("Updated expired evidence")
            } catch {
                XCTAssertEqual(error as? ReceiptQueueError, .missingIdentity(receipt.id))
            }
        }
        await queue.setWriteHooks(ReceiptQueueWriteHooks())
        let unseen = EncounterSamples.receipt(5).id
        try await queue.acknowledge(expired.id)
        try await queue.acknowledge(unseen)
        let expiredDeadline = try await queue.terminalExpiry(for: expired.id)
        let unseenDeadline = try await queue.terminalExpiry(for: unseen)
        XCTAssertEqual(expiredDeadline, time.addingTimeInterval(EncounterProtocol.receiptLifetime))
        XCTAssertEqual(expiredDeadline, unseenDeadline)
        try await queue.removeExpired(asOf: time)
        let cleaned = try await queue.storedReceiptIdentities()
        XCTAssertEqual(cleaned, [retained.id, later.id])
        try await queue.removeExpired(asOf: time.addingTimeInterval(EncounterProtocol.receiptLifetime))
        let remaining = try await queue.storedReceiptIdentities()
        let tombstones = try await queue.terminalReceiptIdentities()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(tombstones.isEmpty)
    }

    func testReceiptLimitCountsUndecodableRowsAndPreservesDuplicatesAndEvidence() async throws {
        let queue = try await SwiftDataReceiptQueue.inMemory(now: { EncounterSamples.observationTime }, receiptLimit: 2)
        let first = EncounterSamples.receipt(1)
        let second = EncounterSamples.receipt(2)
        try await queue.enqueue(first)
        try await queue.enqueue(second)
        try await queue.corruptPayload(for: first.id)
        await queue.setWriteHooks(ReceiptQueueWriteHooks(beforeSave: { XCTFail("Full queue attempted a save") }))
        try await queue.enqueue(first)
        do {
            try await queue.enqueue(EncounterSamples.receipt(3))
            XCTFail("Exceeded receipt capacity")
        } catch {
            XCTAssertEqual(error as? ReceiptStorageError, .queueFull)
        }
        let identities = try await queue.storedReceiptIdentities()
        let pending = try await queue.pending()
        XCTAssertEqual(identities, [first.id, second.id])
        XCTAssertEqual(pending, [second])
    }

    func testEnqueueReclaimsExpiredReceiptsAndTombstonesBeforeCheckingCapacity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = EncounterSamples.receipt(1)
        let retained = EncounterSamples.receipt(2, observedAt: EncounterSamples.observationTime.addingTimeInterval(60))
        let acknowledged = EncounterSamples.receipt(3)
        do {
            let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory,
                now: { EncounterSamples.observationTime }, receiptLimit: 2, tombstoneLimit: 2)
            try await queue.enqueue(acknowledged)
            try await queue.acknowledge(acknowledged.id)
            try await queue.enqueue(expired)
            try await queue.corruptPayload(for: expired.id)
            try await queue.enqueue(retained)
        }
        let time = expired.expiresAt
        let replacement = EncounterSamples.receipt(3, observedAt: time)
        do {
            let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory,
                now: { time }, receiptLimit: 2, tombstoneLimit: 2)
            await queue.setWriteHooks(ReceiptQueueWriteHooks(beforeSave: { throw NSError(domain: "save-fault", code: 1) }))
            do {
                try await queue.enqueue(replacement)
                XCTFail("Cleanup save failure was swallowed")
            } catch {
                XCTAssertEqual(error as? ReceiptStorageError, .saveFailed)
            }
            let unchanged = try await queue.storedReceiptIdentities()
            let tombstones = try await queue.terminalReceiptIdentities()
            XCTAssertEqual(unchanged, [expired.id, retained.id])
            XCTAssertEqual(tombstones, [acknowledged.id])
            await queue.setWriteHooks(ReceiptQueueWriteHooks())
            try await queue.enqueue(replacement)
            let cleaned = try await queue.storedReceiptIdentities()
            let cleanedTombstones = try await queue.terminalReceiptIdentities()
            XCTAssertEqual(cleaned, [retained.id, replacement.id])
            XCTAssertTrue(cleanedTombstones.isEmpty)
        }
        let reopened = try await SwiftDataReceiptQueue.fileBacked(directory: directory,
            now: { time }, receiptLimit: 2, tombstoneLimit: 2)
        do {
            try await reopened.enqueue(EncounterSamples.receipt(4, observedAt: time))
            XCTFail("Exceeded durable receipt capacity")
        } catch {
            XCTAssertEqual(error as? ReceiptStorageError, .queueFull)
        }
        let persisted = try await reopened.pending()
        XCTAssertEqual(persisted, [retained, replacement])
    }

    func testTombstoneLimitEvictsEarliestExpiryIncludingIncomingIdentityDurably() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let early = EncounterSamples.receipt(1)
        let middle = EncounterSamples.receipt(2, observedAt: EncounterSamples.observationTime.addingTimeInterval(60))
        let late = EncounterSamples.receipt(3, observedAt: EncounterSamples.observationTime.addingTimeInterval(120))
        do {
            let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory,
                now: { EncounterSamples.observationTime }, tombstoneLimit: 2)
            for receipt in [early, late, middle] { try await queue.enqueue(receipt) }
            for receipt in [early, late, middle] { try await queue.acknowledge(receipt.id) }
            let identities = try await queue.terminalReceiptIdentities()
            XCTAssertEqual(Set(identities), Set([middle.id, late.id]))
            // An unseen acknowledgement has an earlier deadline than both retained identities.
            try await queue.acknowledge(EncounterSamples.receipt(4).id)
            let afterUnseen = try await queue.terminalReceiptIdentities()
            XCTAssertEqual(Set(afterUnseen), Set([middle.id, late.id]))
            try await queue.enqueue(early)
            try await queue.acknowledge(early.id)
            let afterIncomingEviction = try await queue.terminalReceiptIdentities()
            XCTAssertEqual(Set(afterIncomingEviction), Set([middle.id, late.id]))
        }
        let reopened = try await SwiftDataReceiptQueue.fileBacked(directory: directory,
            now: { EncounterSamples.observationTime }, tombstoneLimit: 2)
        let persisted = try await reopened.terminalReceiptIdentities()
        XCTAssertEqual(Set(persisted), Set([middle.id, late.id]))
        for receipt in [middle, late, early] { try await reopened.enqueue(receipt) }
        let pending = try await reopened.pending()
        XCTAssertEqual(pending, [early])
    }

    func testFailedTombstoneEvictionRollsBackReceiptAndTerminalIdentities() async throws {
        let queue = try await SwiftDataReceiptQueue.inMemory(now: { EncounterSamples.observationTime }, tombstoneLimit: 1)
        let early = EncounterSamples.receipt(1)
        let late = EncounterSamples.receipt(2, observedAt: EncounterSamples.observationTime.addingTimeInterval(60))
        try await queue.enqueue(early)
        try await queue.acknowledge(early.id)
        try await queue.enqueue(late)
        await queue.setWriteHooks(ReceiptQueueWriteHooks(beforeSave: { throw NSError(domain: "save-fault", code: 1) }))
        do {
            try await queue.acknowledge(late.id)
            XCTFail("Eviction save failure was swallowed")
        } catch {
            XCTAssertEqual(error as? ReceiptStorageError, .saveFailed)
        }
        let pending = try await queue.pending()
        let unchanged = try await queue.terminalReceiptIdentities()
        XCTAssertEqual(pending, [late])
        XCTAssertEqual(unchanged, [early.id])
        await queue.setWriteHooks(ReceiptQueueWriteHooks())
        try await queue.acknowledge(late.id)
        let recovered = try await queue.terminalReceiptIdentities()
        XCTAssertEqual(recovered, [late.id])
    }

    func testSavedEvidenceOrderAndTerminalIdentitySurviveAnotherInstance() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let acknowledged = EncounterSamples.receipt(1)
        var retained = EncounterSamples.receipt(3)
        retained.checkpoint = EncounterSamples.receipt(4).start
        retained.observedDuration = 120
        retained.sessionFlag = true
        retained.isFinalEvidence = true
        retained.uploadStatus = .acceptedAsCandidate
        let secondReceipt = EncounterSamples.receipt(2)
        do {
            let first = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
            try await first.enqueue(acknowledged)
            try await first.enqueue(EncounterSamples.receipt(3))
            try await first.enqueue(secondReceipt)
            try await first.update(retained)
            try await first.acknowledge(acknowledged.id)
        }

        let reopened = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
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
        do {
            let first = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
            try await first.enqueue(receipt)
            try await first.acknowledge(receipt.id)
        }

        let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
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
        do {
            let first = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { acknowledgementTime })
            try await first.acknowledge(receipt.id)
        }

        let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { acknowledgementTime.addingTimeInterval(60) })
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
        let receipt = EncounterSamples.receipt()
        do {
            let first = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
            try await first.enqueue(receipt)
            try await first.acknowledge(receipt.id)
            try await first.removeAll()
        }

        let reopened = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
        try await reopened.enqueue(receipt)
        let pending = try await reopened.pending()
        XCTAssertEqual(pending, [receipt])
    }

    func testUpdatesRejectEachChangedInitialEvidenceField() async throws {
        let queue = try await SwiftDataReceiptQueue.inMemory(now: { EncounterSamples.observationTime })
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
        let queue = try await SwiftDataReceiptQueue.inMemory(now: { EncounterSamples.observationTime })
        let receipt = EncounterSamples.receipt()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { try await queue.enqueue(receipt) } }
            try await group.waitForAll()
        }
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [receipt])
    }

    func testCreationThrowsForFileInsteadOfDirectory() async throws {
        let location = temporaryDirectory()
        try Data().write(to: location)
        defer { try? FileManager.default.removeItem(at: location) }
        do {
            _ = try await SwiftDataReceiptQueue.fileBacked(directory: location, now: { EncounterSamples.observationTime })
            XCTFail("Opened a file as a directory")
        } catch {
            XCTAssertEqual(error as? ReceiptStorageError, .unavailable)
        }
    }

    func testUnwritableDirectoryRejectsCreationAndEnqueueWithoutStoring() async throws {
        let directory = temporaryDirectory()
        var queue: SwiftDataReceiptQueue? = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        do {
            _ = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
            XCTFail("Opened an unwritable directory")
        } catch {
            XCTAssertEqual(error as? ReceiptStorageError, .unavailable)
        }
        do {
            try await queue!.enqueue(EncounterSamples.receipt())
            XCTFail("Enqueue reported success with an unwritable store")
        } catch {
            XCTAssertTrue(error is ReceiptStorageError)
        }
        let pending = try await queue!.pending()
        XCTAssertTrue(pending.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        queue = nil
        let reopened = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
        let persisted = try await reopened.pending()
        XCTAssertTrue(persisted.isEmpty)
        try await reopened.enqueue(EncounterSamples.receipt())
        let recovered = try await reopened.pending()
        XCTAssertEqual(recovered, [EncounterSamples.receipt()])
    }

    func testFailedInsertRollsBackAndNextWritePersists() async throws {
        try await assertSaveRollback(.enqueue)
    }

    func testFailedUpdateRollsBackAndNextWritePersists() async throws {
        try await assertSaveRollback(.update)
    }

    func testFailedAcknowledgeRollsBackAndNextWritePersists() async throws {
        try await assertSaveRollback(.acknowledge)
    }

    func testFailedBulkDeletionsRollBackAndNextWritePersists() async throws {
        try await assertSaveRollback(.removeExpired)
        try await assertSaveRollback(.removeAll)
    }

    func testProtectionFailureAfterEverySuccessfulWriteIsIgnoredAndWritePersists() async throws {
        for operation in WriteOperation.allCases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = EncounterSamples.receipt()
            let inserted = EncounterSamples.receipt(2)
            let expected: [EncounterReceipt]
            switch operation {
            case .enqueue: expected = [original, inserted]
            case .update: expected = [updated(original)]
            case .acknowledge, .removeExpired, .removeAll: expected = []
            }
            do {
                let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
                try await queue.enqueue(original)
                await queue.setWriteHooks(ReceiptQueueWriteHooks(
                    beforeSave: { XCTAssertFalse(Thread.isMainThread) },
                    afterSaveProtection: { throw NSError(domain: "protection-fault", code: 1) }
                ))
                try await perform(operation, on: queue, receipt: operation == .enqueue ? inserted : original)
                let pending = try await queue.pending()
                XCTAssertEqual(pending, expected, "\(operation)")
            }
            let reopened = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
            let persisted = try await reopened.pending()
            XCTAssertEqual(persisted, expected, "\(operation)")
            if operation == .acknowledge {
                try await reopened.enqueue(original)
                let blocked = try await reopened.pending()
                XCTAssertTrue(blocked.isEmpty)
            }
        }
    }

    func testStoreUsesSuppliedDirectoryAndExcludesItFromBackupOnOpenAndReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
            try await queue.enqueue(EncounterSamples.receipt())
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("receipts.store").path))
            #if os(iOS)
            XCTAssertEqual(try URL(fileURLWithPath: directory.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            #endif
        }
        #if os(iOS)
        var location = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try location.setResourceValues(values)
        #endif
        let reopened = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
        #if os(iOS)
        XCTAssertEqual(try URL(fileURLWithPath: directory.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #endif
        let pending = try await reopened.pending()
        XCTAssertEqual(pending, [EncounterSamples.receipt()])
    }

    func testPendingSkipsCorruptedRowsAndRetainsThemDurablyInHealthyOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipts = (1...3).map { EncounterSamples.receipt($0) }
        do {
            let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
            for receipt in receipts { try await queue.enqueue(receipt) }
            try await queue.corruptPayload(for: receipts[1].id)
            let pending = try await queue.pending()
            XCTAssertEqual(pending, [receipts[0], receipts[2]])
            let identities = try await queue.storedReceiptIdentities()
            XCTAssertEqual(identities, receipts.map(\.id))
        }
        let reopened = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
        let identities = try await reopened.storedReceiptIdentities()
        XCTAssertEqual(identities, receipts.map(\.id))
        let pending = try await reopened.pending()
        XCTAssertEqual(pending, [receipts[0], receipts[2]])
    }

    func testPendingSkipsCorruptedRowsWithoutSavingAndNextWriteRetainsThem() async throws {
        let queue = try await SwiftDataReceiptQueue.inMemory(now: { EncounterSamples.observationTime })
        let receipts = (1...3).map { EncounterSamples.receipt($0) }
        for receipt in receipts { try await queue.enqueue(receipt) }
        try await queue.corruptPayload(for: receipts[1].id)
        await queue.setWriteHooks(ReceiptQueueWriteHooks(beforeSave: { XCTFail("Pending attempted a save") }))
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [receipts[0], receipts[2]])
        let beforeRetry = try await queue.storedReceiptIdentities()
        XCTAssertEqual(beforeRetry, receipts.map(\.id))
        await queue.setWriteHooks(ReceiptQueueWriteHooks())
        try await queue.enqueue(EncounterSamples.receipt(4))
        let recovered = try await queue.pending()
        XCTAssertEqual(recovered, [receipts[0], receipts[2], EncounterSamples.receipt(4)])
        let afterRetry = try await queue.storedReceiptIdentities()
        XCTAssertEqual(afterRetry, receipts.map(\.id) + [EncounterSamples.receipt(4).id])
    }

    func testSkippedCorruptedRowIsRetainedUntilItsExpiry() async throws {
        let queue = try await SwiftDataReceiptQueue.inMemory(now: { EncounterSamples.observationTime })
        let receipt = EncounterSamples.receipt()
        let retained = EncounterSamples.receipt(2, observedAt: receipt.start.observedAt.addingTimeInterval(60))
        try await queue.enqueue(receipt)
        try await queue.enqueue(retained)
        try await queue.corruptPayload(for: receipt.id)
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [retained])
        try await queue.removeExpired(asOf: receipt.expiresAt.addingTimeInterval(-1))
        let beforeExpiry = try await queue.storedReceiptIdentities()
        XCTAssertEqual(beforeExpiry, [receipt.id, retained.id])
        try await queue.removeExpired(asOf: receipt.expiresAt)
        let atExpiry = try await queue.storedReceiptIdentities()
        XCTAssertEqual(atExpiry, [retained.id])
        let remaining = try await queue.pending()
        XCTAssertEqual(remaining, [retained])
    }

    func testRemoveAllClearsSkippedCorruptedRows() async throws {
        let queue = try await SwiftDataReceiptQueue.inMemory(now: { EncounterSamples.observationTime })
        let receipts = (1...3).map { EncounterSamples.receipt($0) }
        for receipt in receipts { try await queue.enqueue(receipt) }
        try await queue.corruptPayload(for: receipts[1].id)
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [receipts[0], receipts[2]])
        try await queue.removeAll()
        let identities = try await queue.storedReceiptIdentities()
        XCTAssertTrue(identities.isEmpty)
        let cleared = try await queue.pending()
        XCTAssertTrue(cleared.isEmpty)
    }

    func testCorruptedRowRejectsUpdateButCanBeAcknowledgedWithOriginalDeadline() async throws {
        let queue = try await SwiftDataReceiptQueue.inMemory(now: { EncounterSamples.observationTime })
        let receipt = EncounterSamples.receipt()
        try await queue.enqueue(receipt)
        try await queue.corruptPayload(for: receipt.id)
        do {
            try await queue.update(receipt)
            XCTFail("Updated corrupted evidence")
        } catch {
            XCTAssertEqual(error as? ReceiptStorageError, .corruptedReceipt)
        }
        try await queue.acknowledge(receipt.id)
        try await queue.enqueue(receipt)
        let blocked = try await queue.pending()
        XCTAssertTrue(blocked.isEmpty)
        try await queue.removeExpired(asOf: receipt.expiresAt)
        try await queue.enqueue(receipt)
        let reused = try await queue.pending()
        XCTAssertEqual(reused, [receipt])
    }

    func testEncodingAndSequenceFailuresAreSanitizedAndDoNotChangePending() async throws {
        let queue = try await SwiftDataReceiptQueue.inMemory(now: { EncounterSamples.observationTime })
        var invalid = EncounterSamples.receipt()
        invalid.observedDuration = .nan
        do {
            try await queue.enqueue(invalid)
            XCTFail("Encoded non-finite duration")
        } catch {
            XCTAssertEqual(error as? ReceiptStorageError, .encodingFailed)
        }
        let original = EncounterSamples.receipt()
        try await queue.enqueue(original)
        do {
            try await queue.update(invalid)
            XCTFail("Updated to non-finite duration")
        } catch {
            XCTAssertEqual(error as? ReceiptStorageError, .encodingFailed)
        }
        try await queue.exhaustSequence(for: original.id)
        do {
            try await queue.enqueue(EncounterSamples.receipt(2))
            XCTFail("Overflowed sequence")
        } catch {
            XCTAssertEqual(error as? ReceiptStorageError, .sequenceExhausted)
        }
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [original])
    }

    private enum WriteOperation: CaseIterable {
        case enqueue, update, acknowledge, removeExpired, removeAll
    }

    private func updated(_ receipt: EncounterReceipt) -> EncounterReceipt {
        var changed = receipt
        changed.checkpoint = EncounterSamples.receipt(4).start
        changed.observedDuration = 120
        changed.uploadStatus = .acceptedAsCandidate
        return changed
    }

    private func perform(_ operation: WriteOperation, on queue: SwiftDataReceiptQueue,
                         receipt: EncounterReceipt) async throws {
        switch operation {
        case .enqueue: try await queue.enqueue(receipt)
        case .update: try await queue.update(updated(receipt))
        case .acknowledge: try await queue.acknowledge(receipt.id)
        case .removeExpired: try await queue.removeExpired(asOf: receipt.expiresAt)
        case .removeAll: try await queue.removeAll()
        }
    }

    private func assertSaveRollback(_ operation: WriteOperation) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = EncounterSamples.receipt()
        let retained = EncounterSamples.receipt(2)
        let unrelated = EncounterSamples.receipt(3)
        do {
            let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
            try await queue.enqueue(original)
            try await queue.enqueue(retained)
            await queue.setWriteHooks(ReceiptQueueWriteHooks(beforeSave: {
                throw NSError(domain: "private-receipt-material", code: 1)
            }))
            do {
                try await perform(operation, on: queue,
                                  receipt: operation == .enqueue ? EncounterSamples.receipt(4) : original)
                XCTFail("Save fault was swallowed: \(operation)")
            } catch {
                XCTAssertEqual(error as? ReceiptStorageError, .saveFailed)
                XCTAssertFalse(String(describing: error).contains("private-receipt-material"))
            }
            let unchanged = try await queue.pending()
            XCTAssertEqual(unchanged, [original, retained])
            await queue.setWriteHooks(ReceiptQueueWriteHooks())
            try await queue.enqueue(unrelated)
            let recovered = try await queue.pending()
            XCTAssertEqual(recovered, [original, retained, unrelated])
        }
        let reopened = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
        let persisted = try await reopened.pending()
        XCTAssertEqual(persisted, [original, retained, unrelated])
        let tombstones = try await reopened.terminalReceiptIdentities()
        XCTAssertTrue(tombstones.isEmpty)
    }

    #if os(iOS)
    func testDirectoryStoreAndSidecarsHaveAfterFirstUnlockProtection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try await SwiftDataReceiptQueue.fileBacked(directory: directory, now: { EncounterSamples.observationTime })
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

// Test fixtures mutate SwiftData only on the same serial model executor as queue operations.
private extension SwiftDataReceiptQueue {
    func corruptPayload(for identity: UUID) throws {
        let descriptor = FetchDescriptor<StoredReceipt>(predicate: #Predicate { $0.identity == identity })
        let row = try XCTUnwrap(modelContext.fetch(descriptor).first)
        row.payload = Data("undecodable-receipt".utf8)
        try modelContext.save()
    }

    func storedReceiptIdentities() throws -> [UUID] {
        try modelContext.fetch(FetchDescriptor<StoredReceipt>(sortBy: [SortDescriptor(\.sequence)])).map(\.identity)
    }

    func terminalReceiptIdentities() throws -> [UUID] {
        try modelContext.fetch(FetchDescriptor<TerminalReceiptIdentity>()).map(\.identity)
    }

    func terminalExpiry(for identity: UUID) throws -> Date {
        let descriptor = FetchDescriptor<TerminalReceiptIdentity>(predicate: #Predicate { $0.identity == identity })
        return try XCTUnwrap(modelContext.fetch(descriptor).first).expiry
    }

    func exhaustSequence(for identity: UUID) throws {
        let descriptor = FetchDescriptor<StoredReceipt>(predicate: #Predicate { $0.identity == identity })
        let row = try XCTUnwrap(modelContext.fetch(descriptor).first)
        row.sequence = Int64.max
        try modelContext.save()
    }
}
