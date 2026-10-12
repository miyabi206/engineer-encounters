import EncounterDomain
import Foundation

@MainActor
protocol ReceiptUploadCancellation {
    func cancel()
}

@MainActor
protocol ReceiptUploadScheduler {
    func schedule(at date: Date, operation: @escaping @MainActor () async -> Void) -> any ReceiptUploadCancellation
}

@MainActor
struct ClockReceiptUploadScheduler: ReceiptUploadScheduler {
    let clock: any EncounterClock

    func schedule(at date: Date, operation: @escaping @MainActor () async -> Void) -> any ReceiptUploadCancellation {
        let task = Task {
            let time = await clock.now()
            do {
                try await clock.wait(until: time.monotonic + max(0, date.timeIntervalSince(time.wall)))
                guard !Task.isCancelled else { return }
                await operation()
            } catch { /* Cancellation ends this scheduled attempt. */ }
        }
        return ClockReceiptUploadJob(task: task)
    }
}

@MainActor
private final class ClockReceiptUploadJob: ReceiptUploadCancellation {
    private let task: Task<Void, Never>
    init(task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
    deinit { task.cancel() }
}
