import Foundation
import EncounterDomain

/// Describes the first queue contract violation without logging sensitive evidence.
public struct ReceiptQueueContractError: Error, Sendable, CustomStringConvertible {
    public let rule: String
    public let detail: String

    public init(rule: String, detail: String) {
        self.rule = rule
        self.detail = detail
    }

    public var description: String { "Receipt queue contract [\(rule)]: \(detail)" }
}

/// Framework-independent checks reusable by every receipt queue implementation.
/// Checks clear the supplied isolated queue; the factory must return distinct,
/// deterministic identities for different indexes and the same receipt per index.
public enum ReceiptQueueContract {
    public typealias Factory = @Sendable (Int) -> EncounterReceipt

    /// Runs the complete contract against any queue using deterministic receipt fixtures.
    public static func checkAll(on queue: any ReceiptQueue,
                                factory: Factory = { EncounterSamples.receipt($0) }) async throws {
        try await checkEnqueueAndPending(on: queue, factory: factory)
        try await checkUpdate(on: queue, factory: factory)
        try await checkDuplicateEnqueue(on: queue, factory: factory)
        try await checkAcknowledge(on: queue, factory: factory)
        try await checkExpiry(on: queue, factory: factory)
        try await checkRemoveAll(on: queue, factory: factory)
    }

    /// A returned enqueue must already be readable, with stable enqueue ordering.
    public static func checkEnqueueAndPending(on queue: any ReceiptQueue, factory: Factory) async throws {
        try await queue.removeAll()
        let first = factory(2)
        let second = factory(1)
        try await queue.enqueue(first)
        try require(try await queue.pending() == [first], rule: "enqueue", detail: "returned write was not readable")
        try await queue.enqueue(second)
        try require(try await queue.pending() == [first, second], rule: "pending order", detail: "enqueue order changed")
        try require(try await queue.pending() == [first, second], rule: "pending order", detail: "repeated read changed order")
    }

    /// Updating a candidate preserves its identity, initial evidence and order.
    public static func checkUpdate(on queue: any ReceiptQueue, factory: Factory) async throws {
        try await queue.removeAll()
        var receipt = factory(1)
        let second = factory(2)
        try await queue.enqueue(receipt)
        try await queue.enqueue(second)
        receipt.checkpoint = ReceiptTokenPair(ownToken: second.start.ownToken, peerToken: second.start.peerToken,
                                             observedAt: receipt.start.observedAt.addingTimeInterval(120))
        receipt.observedDuration = 120
        receipt.isFinalEvidence = true
        receipt.uploadStatus = .acceptedAsCandidate
        try await queue.update(receipt)
        try require(try await queue.pending() == [receipt, second], rule: "update",
                    detail: "identity, evidence, candidate retention or enqueue order changed")
        do {
            try await queue.update(factory(3))
        } catch {
            try require(try await queue.pending() == [receipt, second], rule: "update", detail: "missing identity changed queue")
            return
        }
        throw ReceiptQueueContractError(rule: "update", detail: "missing identity was accepted as an update")
    }

    /// Duplicate enqueues cannot overwrite a checkpoint or create another entry.
    public static func checkDuplicateEnqueue(on queue: any ReceiptQueue, factory: Factory) async throws {
        try await queue.removeAll()
        let original = factory(1)
        try await queue.enqueue(original)
        var updated = original
        updated.uploadStatus = .acceptedAsCandidate
        try await queue.update(updated)
        try await queue.enqueue(original)
        try await queue.enqueue(original)
        try require(try await queue.pending() == [updated], rule: "duplicate enqueue", detail: "duplicate added or overwrote evidence")
    }

    /// Acknowledgement is terminal, idempotent and cannot be undone by delivery retries.
    public static func checkAcknowledge(on queue: any ReceiptQueue, factory: Factory) async throws {
        try await queue.removeAll()
        let receipt = factory(1)
        let retained = factory(2)
        try await queue.enqueue(receipt)
        try await queue.enqueue(retained)
        try await queue.acknowledge(receipt.id)
        try await queue.acknowledge(receipt.id)
        try await queue.acknowledge(factory(3).id)
        try await queue.enqueue(receipt)
        try require(try await queue.pending() == [retained], rule: "acknowledge", detail: "terminal identity revived or another entry was removed")
        do {
            try await queue.update(receipt)
        } catch {
            try require(try await queue.pending() == [retained], rule: "acknowledge", detail: "update revived terminal identity")
            return
        }
        throw ReceiptQueueContractError(rule: "acknowledge", detail: "terminal identity accepted an update")
    }

    /// Checkpoint updates cannot extend the inclusive 48-hour removal deadline.
    public static func checkExpiry(on queue: any ReceiptQueue, factory: Factory) async throws {
        try await queue.removeAll()
        var receipt = factory(1)
        try await queue.enqueue(receipt)
        receipt.checkpoint = ReceiptTokenPair(ownToken: receipt.start.ownToken, peerToken: receipt.start.peerToken,
                                             observedAt: receipt.start.observedAt.addingTimeInterval(3_600))
        receipt.observedDuration = 120
        receipt.uploadStatus = .acceptedAsCandidate
        try await queue.update(receipt)
        try await queue.removeExpired(asOf: receipt.expiresAt.addingTimeInterval(-1))
        try require(try await queue.pending() == [receipt], rule: "expiry", detail: "receipt removed before 48 hours")
        let second = factory(2)
        let later = EncounterReceipt(id: second.id, role: second.role, exchangeNonce: second.exchangeNonce,
                                     start: ReceiptTokenPair(ownToken: second.start.ownToken, peerToken: second.start.peerToken,
                                                             observedAt: receipt.start.observedAt.addingTimeInterval(1)))
        try await queue.enqueue(later)
        try await queue.removeExpired(asOf: receipt.expiresAt)
        try require(try await queue.pending() == [later], rule: "expiry", detail: "48-hour deadline extended or unexpired receipt removed")
        try await queue.removeExpired(asOf: later.expiresAt.addingTimeInterval(1))
        try require(try await queue.pending().isEmpty, rule: "expiry", detail: "receipt remained after deadline")
    }

    /// Sign-out/reset clears every queued receipt and is safe to repeat.
    public static func checkRemoveAll(on queue: any ReceiptQueue, factory: Factory) async throws {
        try await queue.removeAll()
        try await queue.enqueue(factory(1))
        try await queue.enqueue(factory(2))
        try await queue.removeAll()
        try await queue.removeAll()
        try require(try await queue.pending().isEmpty, rule: "remove-all", detail: "evidence remained after reset")
    }

    private static func require(_ condition: Bool, rule: String, detail: String) throws {
        guard condition else { throw ReceiptQueueContractError(rule: rule, detail: detail) }
    }
}
