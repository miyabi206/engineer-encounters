import EncounterDomain
import Foundation

/// Observe permission changes while participation is off; one relay feeds the existing engine.
@MainActor
final class RuntimeBluetoothTransport: BluetoothTransport {
    nonisolated let events: AsyncStream<BluetoothEvent>
    private nonisolated let underlying: any BluetoothTransport
    private let continuation: AsyncStream<BluetoothEvent>.Continuation
    private let task: Task<Void, Never>

    init(underlying: any BluetoothTransport, availability: @escaping @MainActor (RadioAvailability) -> Void) {
        self.underlying = underlying
        let stream = AsyncStream<BluetoothEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        task = Task {
            for await event in underlying.events {
                guard !Task.isCancelled else { break }
                if case .availabilityChanged(let value) = event { availability(value) }
                stream.continuation.yield(event)
            }
            stream.continuation.finish()
        }
    }

    nonisolated func execute(_ command: BluetoothCommand) async { await underlying.execute(command) }

    func invalidate() { task.cancel(); continuation.finish() }
    deinit { task.cancel(); continuation.finish() }
}
