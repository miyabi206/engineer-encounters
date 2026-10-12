import EncounterDomain
import Foundation

/// Fences an uploader's local writes without waiting for its network response.
actor AccountReceiptQueue: ReceiptQueue {
    private let queue: any ReceiptQueue
    private var active = true
    private var writing: Task<Void, any Error>?

    init(_ queue: any ReceiptQueue) { self.queue = queue }

    func invalidate() async {
        active = false
        _ = await writing?.result
    }

    func pending() async throws -> [EncounterReceipt] {
        guard active else { throw CancellationError() }
        let receipts = try await queue.pending()
        guard active else { throw CancellationError() }
        return receipts
    }

    func enqueue(_ receipt: EncounterReceipt) async throws {
        try await write { try await $0.enqueue(receipt) }
    }
    func update(_ receipt: EncounterReceipt) async throws {
        try await write { try await $0.update(receipt) }
    }
    func acknowledge(_ identity: UUID) async throws {
        try await write { try await $0.acknowledge(identity) }
    }
    func removeExpired(asOf time: Date) async throws {
        try await write { try await $0.removeExpired(asOf: time) }
    }
    func removeAll() async throws {
        try await write { try await $0.removeAll() }
    }

    private func write(_ operation: @escaping @Sendable (any ReceiptQueue) async throws -> Void) async throws {
        guard active else { throw CancellationError() }
        let previous = writing
        let task = Task {
            _ = await previous?.result
            guard self.active else { throw CancellationError() }
            try await operation(self.queue)
        }
        writing = task
        try await task.value
    }
}
