import Foundation
import EncounterDomain

/// Mutable state is confined to the adapter queue, including consumer pulls.
final class EventDelivery: @unchecked Sendable {
    private let queue: DispatchQueue
    private var backlog = EventBacklog()
    private var waiting: CheckedContinuation<BluetoothEvent?, Never>?
    private var finished = false

    init(queue: DispatchQueue) { self.queue = queue }

    var count: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return backlog.count
    }

    func append(_ event: BluetoothEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished, backlog.append(event) else { return }
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: backlog.next())
        }
    }

    func next() async -> BluetoothEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    if let event = backlog.next() {
                        continuation.resume(returning: event)
                    } else if finished {
                        continuation.resume(returning: nil)
                    } else {
                        precondition(waiting == nil, "Bluetooth events have one consumer")
                        waiting = continuation
                    }
                }
            }
        } onCancel: {
            self.finish(cancelled: true)
        }
    }

    func finish(cancelled: Bool = false) {
        queue.async { [self] in
            finished = true
            // Normal termination preserves queued events for the stream to drain.
            if cancelled { backlog = EventBacklog() }
            waiting?.resume(returning: nil)
            waiting = nil
        }
    }
}
