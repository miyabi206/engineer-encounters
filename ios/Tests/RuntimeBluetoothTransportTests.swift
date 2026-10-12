import CoreBluetooth
import EncounterDomain
import EncounterDomainTestSupport
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class RuntimeBluetoothTransportTests: XCTestCase {
    func testHeldEngineWorkLeavesObservationsAtTheAdapterAdmissionBound() async throws {
        let adapter = AdmissionBoundTestTransport()
        await adapter.append(.availabilityChanged(.available))
        let relay = RuntimeBluetoothTransport(underlying: adapter) { _ in }
        let gate = BluetoothProcessingGate()
        let engine = EncounterEngine(transport: relay, tokenProvider: TokenProvider(store: InMemoryTokenBatchStore()),
            receiptQueue: InMemoryReceiptQueue(), clock: ManualEncounterClock(), sessionFlag: {
                await gate.wait()
                return false
            })
        let starting = Task { await engine.start() }
        try await appBackendEventually {
            let waiting = await gate.isWaiting
            let pulls = await adapter.pullCount
            return waiting && pulls >= 1
        }
        // Deliver callbacks while the engine is held inside its first operation.
        // An eager relay would empty this queue into its own buffer during these actor hops.
        for _ in 0..<1024 { await adapter.append(.peerObserved(PeerHandle())) }
        let buffered = await adapter.bufferedCount
        let dropped = await adapter.droppedCount
        let pulls = await adapter.pullCount
        XCTAssertEqual(buffered, 256)
        XCTAssertEqual(dropped, 768)
        XCTAssertEqual(pulls, 1)
        await gate.release()
        await starting.value
        await engine.stop()
        relay.invalidate()
    }

    func testNoConsumerMeansNoPullsAndOneDemandPullsExactlyOneEvent() async throws {
        let adapter = AdmissionBoundTestTransport()
        let relay = RuntimeBluetoothTransport(underlying: adapter) { _ in }
        for _ in 0..<512 { await adapter.append(.peerObserved(PeerHandle())) }
        let initialPulls = await adapter.pullCount
        let initialCount = await adapter.bufferedCount
        XCTAssertEqual(initialPulls, 0)
        XCTAssertEqual(initialCount, 256)
        var iterator = relay.events.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertNotNil(first)
        let pulled = await adapter.pullCount
        let remaining = await adapter.bufferedCount
        XCTAssertEqual(pulled, 1)
        XCTAssertEqual(remaining, 255)
        relay.invalidate()
        let afterInvalidation = await iterator.next()
        XCTAssertNil(afterInvalidation)
    }

    func testObserverMapsSystemPowerAuthorizationAndUnknownStates() {
        XCTAssertEqual(BluetoothRadioObserver.availability(.poweredOff), .unavailable)
        XCTAssertEqual(BluetoothRadioObserver.availability(.poweredOn), .available)
        XCTAssertEqual(BluetoothRadioObserver.availability(.unauthorized), .unauthorized)
        XCTAssertEqual(BluetoothRadioObserver.availability(.resetting), .unknown)
        XCTAssertEqual(AccountFlowModel.permission(.init(radioAvailability: .unavailable, bluetoothPoweredOff: true)), .poweredOff)
    }
}

private actor BluetoothProcessingGate {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !waiting.isEmpty }
    func wait() async {
        if !released { await withCheckedContinuation { waiting.append($0) } }
    }
    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// Models the adapter's pull delivery and its 256-event observation admission rule.
private actor AdmissionBoundTestTransport: BluetoothTransport {
    nonisolated let events: AsyncStream<BluetoothEvent>
    private let delivery = AdmissionBoundTestDelivery()
    init() {
        let delivery = self.delivery
        events = AsyncStream(unfolding: { await delivery.next() })
    }
    func execute(_ command: BluetoothCommand) async {}
    func append(_ event: BluetoothEvent) async { await delivery.append(event) }
    var pullCount: Int { get async { await delivery.pulls } }
    var bufferedCount: Int { get async { await delivery.count } }
    var droppedCount: Int { get async { await delivery.dropped } }
}

private actor AdmissionBoundTestDelivery {
    private var backlog: [BluetoothEvent] = []
    private var waiting: CheckedContinuation<BluetoothEvent?, Never>?
    private(set) var pulls = 0
    private(set) var dropped = 0
    var count: Int { backlog.count }
    func append(_ event: BluetoothEvent) {
        if case .peerObserved = event, backlog.count >= 256 { dropped += 1; return }
        if let waiting { self.waiting = nil; waiting.resume(returning: event) }
        else { backlog.append(event) }
    }
    func next() async -> BluetoothEvent? {
        pulls += 1
        if !backlog.isEmpty { return backlog.removeFirst() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiting = $0 }
        } onCancel: { Task { await self.finish() } }
    }
    private func finish() { waiting?.resume(returning: nil); waiting = nil }
}
