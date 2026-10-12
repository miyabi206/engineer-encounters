import EncounterDomain
import Foundation

/// One pull reaches the adapter directly. No task drains events ahead of the engine.
@MainActor
final class RuntimeBluetoothTransport: BluetoothTransport {
    nonisolated let events: AsyncStream<BluetoothEvent>
    private nonisolated let underlying: any BluetoothTransport
    private let delivery: RuntimeBluetoothPull

    init(underlying: any BluetoothTransport, availability: @escaping @MainActor (RadioAvailability) -> Void) {
        self.underlying = underlying
        let delivery = RuntimeBluetoothPull(underlying: underlying, availability: availability)
        self.delivery = delivery
        events = AsyncStream(unfolding: { await delivery.next() })
    }

    nonisolated func execute(_ command: BluetoothCommand) async { await underlying.execute(command) }

    func invalidate() { delivery.invalidate() }
}

@MainActor
private final class RuntimeBluetoothPull {
    private let underlying: any BluetoothTransport
    private let availability: @MainActor (RadioAvailability) -> Void
    private var valid = true
    private var pull: Task<BluetoothEvent?, Never>?

    init(underlying: any BluetoothTransport, availability: @escaping @MainActor (RadioAvailability) -> Void) {
        self.underlying = underlying
        self.availability = availability
    }

    func next() async -> BluetoothEvent? {
        guard valid, !Task.isCancelled else { return nil }
        let task = Task { [underlying] in
            var iterator = underlying.events.makeAsyncIterator()
            return await iterator.next()
        }
        pull = task
        let event = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        pull = nil
        guard valid, !Task.isCancelled else { return nil }
        if case .availabilityChanged(let value) = event { availability(value) }
        return event
    }

    func invalidate() { valid = false; pull?.cancel() }
    deinit { pull?.cancel() }
}
