import Foundation
import XCTest
import EncounterDomain
import EncounterDomainTestSupport

@MainActor
final class ReceiptQueueTests: XCTestCase {
    func testInMemoryQueuePassesReusableContract() async throws {
        try await ReceiptQueueContract.checkAll(on: InMemoryReceiptQueue(), factory: { EncounterSamples.receipt($0) })
    }

    func testAmbientEvidenceRequiresCheckpointAnd120Seconds() {
        var receipt = EncounterSamples.receipt()
        receipt.observedDuration = 120
        receipt.sessionFlag = true
        XCTAssertFalse(receipt.hasQualifyingAmbientEvidence)
        receipt.checkpoint = ReceiptTokenPair(ownToken: receipt.start.ownToken, peerToken: receipt.start.peerToken,
                                             observedAt: receipt.start.observedAt.addingTimeInterval(120))
        receipt.observedDuration = 119
        XCTAssertFalse(receipt.hasQualifyingAmbientEvidence)
        receipt.observedDuration = 120
        XCTAssertTrue(receipt.hasQualifyingAmbientEvidence)
        receipt.observedDuration = 121
        XCTAssertTrue(receipt.hasQualifyingAmbientEvidence)
    }

    func testReceiptCodablePreservesEveryEvidenceField() throws {
        let start = EncounterSamples.receipt().start
        let checkpoint = ReceiptTokenPair(ownToken: EncounterSamples.token(seed: 3), peerToken: EncounterSamples.token(seed: 4),
                                          observedAt: start.observedAt.addingTimeInterval(120))
        for role in [ExchangeRole.central, .peripheral] {
            for status in [ReceiptUploadStatus.notYetUploaded, .acceptedAsCandidate] {
                let receipt = EncounterReceipt(id: EncounterSamples.receipt().id, role: role,
                                                exchangeNonce: EncounterSamples.nonce(), priorExchangeNonce: EncounterSamples.nonce(seed: 3),
                                                start: start, checkpoint: checkpoint, observedDuration: 120,
                                                sessionFlag: true, isFinalEvidence: true, uploadStatus: status)
                XCTAssertEqual(try JSONDecoder().decode(EncounterReceipt.self, from: JSONEncoder().encode(receipt)), receipt)
                XCTAssertEqual(receipt.expiresAt, start.observedAt.addingTimeInterval(172_800))
            }
        }
        let minimal = EncounterSamples.receipt()
        XCTAssertEqual(try JSONDecoder().decode(EncounterReceipt.self, from: JSONEncoder().encode(minimal)), minimal)
    }

    func testUpdateCannotMoveFirstObservationOrRewriteInitialEvidence() async throws {
        let queue = InMemoryReceiptQueue()
        let original = EncounterSamples.receipt()
        try await queue.enqueue(original)
        let newStart = ReceiptTokenPair(ownToken: original.start.ownToken, peerToken: original.start.peerToken,
                                        observedAt: original.start.observedAt.addingTimeInterval(1))
        let changed = EncounterReceipt(id: original.id, role: original.role, exchangeNonce: original.exchangeNonce, start: newStart)
        do {
            try await queue.update(changed)
            XCTFail("Update changed the first observation")
        } catch {
            XCTAssertEqual(error as? ReceiptQueueError, .changedInitialEvidence(original.id))
        }
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [original])
    }

    func testConcurrentDuplicatesProduceOneReceipt() async throws {
        let queue = InMemoryReceiptQueue()
        let receipt = EncounterSamples.receipt()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { try await queue.enqueue(receipt) } }
            try await group.waitForAll()
        }
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [receipt])
    }

    func testContractReportsFirstViolationDescriptively() async throws {
        do {
            try await ReceiptQueueContract.checkAll(on: DroppingQueue())
            XCTFail("Contract accepted a queue that loses writes")
        } catch let error as ReceiptQueueContractError {
            XCTAssertEqual(error.rule, "enqueue")
            XCTAssertTrue(error.description.contains("returned write was not readable"))
        }
    }
}

private actor DroppingQueue: ReceiptQueue {
    func enqueue(_ receipt: EncounterReceipt) async throws {}
    func update(_ receipt: EncounterReceipt) async throws {}
    func pending() async throws -> [EncounterReceipt] { [] }
    func acknowledge(_ identity: UUID) async throws {}
    func removeExpired(asOf time: Date) async throws {}
    func removeAll() async throws {}
}
