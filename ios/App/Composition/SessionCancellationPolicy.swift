import EncounterBackend
import EncounterDomain
import Foundation

enum SessionCancellationPolicy {
    static let startRequestTimeout: TimeInterval = 60
    static let quarantineDuration: TimeInterval = startRequestTimeout + 5
    static let pollInterval: TimeInterval = 5
}

/// Relative scheduling never compares a cancellation with wall or server time.
@MainActor
protocol SessionCancellationScheduling {
    func schedule(after delay: TimeInterval, operation: @escaping @MainActor () async -> Void) -> any ReceiptUploadCancellation
}

@MainActor
struct ClockSessionCancellationScheduler: SessionCancellationScheduling {
    let clock: any EncounterClock
    func schedule(after delay: TimeInterval, operation: @escaping @MainActor () async -> Void) -> any ReceiptUploadCancellation {
        let task = Task {
            let deadline = await clock.now().monotonic + delay
            do {
                try await clock.wait(until: deadline)
                guard !Task.isCancelled else { return }
                await operation()
            } catch { /* Rebinding and sign-out cancel polling. */ }
        }
        return SessionCancellationJob(task: task)
    }
}

@MainActor
private final class SessionCancellationJob: ReceiptUploadCancellation {
    let task: Task<Void, Never>
    init(task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
    deinit { task.cancel() }
}

/// A timeout does not join an uncooperative transport or accept its late result.
@MainActor
final class SessionStartCompletion {
    private var continuation: CheckedContinuation<SessionTransfer?, any Error>?
    private var result: Result<SessionTransfer?, any Error>?
    func install(_ continuation: CheckedContinuation<SessionTransfer?, any Error>) {
        if let result { continuation.resume(with: result) }
        else { self.continuation = continuation }
    }
    func finish(_ result: Result<SessionTransfer?, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result); continuation = nil
    }
}
