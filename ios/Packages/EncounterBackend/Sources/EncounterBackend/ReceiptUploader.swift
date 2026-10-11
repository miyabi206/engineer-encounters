import Foundation
import EncounterDomain

/// Caller-driven exponential retries, with bounded jitter and no timers.
public struct ReceiptRetrySchedule: Sendable {
    private var delay: TimeInterval = 5
    private let random: @Sendable () -> Double

    public init(random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.random = random
    }

    public mutating func nextAttempt(after now: Date, madeProgress: Bool) -> Date {
        if madeProgress { delay = 5 }
        let sample = random()
        let unit = sample.isFinite ? min(1, max(0, sample)) : 0.5
        let interval = min(900, max(5, delay * (0.8 + 0.4 * unit)))
        delay = min(900, delay * 2)
        return now.addingTimeInterval(interval)
    }

    public mutating func reset() { delay = 5 }
}

/// Terminal removals, the next caller-driven attempt, and retryable call failures.
public struct ReceiptUploadOutcome: Sendable, Equatable {
    public let settledCount: Int
    public let nextAttemptAt: Date?
    public let error: BackendError?
}

/// Uploads final, unexpired queued evidence and applies server acknowledgements.
public actor ReceiptUploader {
    private let client: RemoteProcedureClient
    private let queue: any ReceiptQueue
    private var schedule: ReceiptRetrySchedule
    private typealias Flight = (id: UUID, task: Task<ReceiptUploadOutcome, any Error>)
    private var inFlight: Flight?
    private var followUp: Flight?
    private var checkedOrder: [UUID] = []

    public init(client: RemoteProcedureClient, queue: any ReceiptQueue,
                schedule: ReceiptRetrySchedule = ReceiptRetrySchedule()) {
        self.client = client
        self.queue = queue
        self.schedule = schedule
    }

    public func upload(at now: Date) async throws -> ReceiptUploadOutcome {
        if let inFlight {
            if let followUp { return try await followUp.task.value }
            let id = UUID()
            let task = Task {
                _ = await inFlight.task.result
                return try await self.performPass(at: now, id: id)
            }
            followUp = (id, task)
            return try await task.value
        }
        let id = UUID()
        let task = Task { try await self.performPass(at: now, id: id) }
        inFlight = (id, task)
        return try await task.value
    }

    private func performPass(at now: Date, id: UUID) async throws -> ReceiptUploadOutcome {
        defer {
            if inFlight?.id == id {
                inFlight = followUp
                followUp = nil
            }
        }
        return try await uploadPending(at: now)
    }

    private func uploadPending(at now: Date) async throws -> ReceiptUploadOutcome {
        let eligible = try await queue.pending().filter { $0.isFinalEvidence && $0.expiresAt > now }
        let eligibleIDs = Set(eligible.map(\.id))
        checkedOrder.removeAll { !eligibleIDs.contains($0) }
        let ranks = Dictionary(uniqueKeysWithValues: checkedOrder.enumerated().map { ($0.element, $0.offset) })
        let newReceipts = Array(eligible.filter { $0.uploadStatus == .notYetUploaded }.prefix(50))
        let candidates = eligible.enumerated().filter { $0.element.uploadStatus == .acceptedAsCandidate }.sorted {
            let lhs = ranks[$0.element.id] ?? -1
            let rhs = ranks[$1.element.id] ?? -1
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.prefix(50 - newReceipts.count).map(\.element)
        let receipts = newReceipts + candidates
        guard !receipts.isEmpty else {
            schedule.reset()
            return ReceiptUploadOutcome(settledCount: 0, nextAttemptAt: nil, error: nil)
        }
        let checkedIDs = Set(receipts.map(\.id))
        checkedOrder.removeAll { checkedIDs.contains($0) }
        checkedOrder.append(contentsOf: receipts.map(\.id))
        let statuses: [ReceiptStatusTransfer]
        do {
            statuses = try await client.call("submit_receipts", parameters: SubmitReceiptsParameters(receipts: receipts))
        } catch let error as BackendError where Self.isRetryable(error) {
            return ReceiptUploadOutcome(settledCount: 0,
                                        nextAttemptAt: schedule.nextAttempt(after: now, madeProgress: false), error: error)
        }
        var settled = 0
        var madeProgress = false
        for receipt in receipts {
            guard let status = statuses.first(where: { $0.id == receipt.id })?.status else { continue }
            do {
                if status.isTerminal {
                    try await queue.acknowledge(receipt.id)
                    settled += 1
                    madeProgress = true
                } else if var current = try await queue.pending().first(where: { $0.id == receipt.id }),
                          current.uploadStatus != .acceptedAsCandidate {
                    current.uploadStatus = .acceptedAsCandidate
                    try await queue.update(current)
                    madeProgress = true
                }
            } catch ReceiptQueueError.missingIdentity { continue }
        }
        let hasPending = try await queue.pending().contains { $0.isFinalEvidence && $0.expiresAt > now }
        let next = hasPending ? schedule.nextAttempt(after: now, madeProgress: madeProgress) : nil
        if !hasPending { schedule.reset() }
        return ReceiptUploadOutcome(settledCount: settled, nextAttemptAt: next, error: nil)
    }

    private static func isRetryable(_ error: BackendError) -> Bool {
        switch error {
        case .rateLimited, .transportFailure: return true
        case .httpFailure(let status): return status == 408 || status == 429 || (500..<600).contains(status)
        default: return false
        }
    }
}
