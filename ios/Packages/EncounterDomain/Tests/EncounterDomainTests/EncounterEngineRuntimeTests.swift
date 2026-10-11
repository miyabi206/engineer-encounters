import Foundation
import XCTest
import EncounterDomain
import EncounterDomainTestSupport

@MainActor
final class EncounterEngineRuntimeTests: XCTestCase {
    private func idle(_ engine: EncounterEngine, processed: UInt64) async throws {
        for _ in 0..<10000 {
            if await engine.processedTransportEventCount >= processed, await engine.isIdle { return }
            await Task.yield()
        }
        throw FakeRigError.deliveryDidNotSettle
    }
    private func engine(_ transport: RuntimeTransport, _ store: RuntimeTokenStore,
                        _ clock: ManualEncounterClock, queue: any ReceiptQueue = InMemoryReceiptQueue()) -> EncounterEngine {
        EncounterEngine(transport: transport, tokenProvider: TokenProvider(store: store), receiptQueue: queue,
                        clock: clock, sessionFlag: { false })
    }

    func testCurrentWindowCacheSurvivesStoreErrorsAndReloadsOnRefreshStopResetAndExpiry() async throws {
        let batch = try EncounterSamples.batch(count: 2)
        let transport = RuntimeTransport(), store = RuntimeTokenStore(batch), clock = ManualEncounterClock()
        let engine = engine(transport, store, clock)
        await engine.start(); try await idle(engine, processed: 1)
        let initialLoads = await store.loads; XCTAssertEqual(initialLoads, 1)
        let peer = PeerHandle(), key = BluetoothConnection(peer: PeerHandle(), role: .peripheral)
        await store.setFailingLoads(true)
        await transport.emit(.peerObserved(peer)); try await idle(engine, processed: 2)
        let afterObservation = await store.loads; XCTAssertEqual(afterObservation, initialLoads)
        await engine.refresh()
        let afterRefresh = await store.loads; XCTAssertEqual(afterRefresh, initialLoads + 1)
        let valid = await transport.commands()
        XCTAssertTrue(valid.contains(.connect(peer)))
        XCTAssertFalse(valid.contains(.disconnect(.init(peer: peer, role: .central))))
        await engine.stop(); await engine.start()
        let afterRestart = await transport.commands()
        XCTAssertEqual(afterRestart.filter { $0 == .startDiscovery }.count, 1)
        await store.setFailingLoads(false); await engine.refresh()
        let resumed = await transport.commands()
        XCTAssertEqual(resumed.filter { $0 == .startDiscovery }.count, 2)
        let beforeExpiry = await store.loads
        await clock.advance(by: 900)
        try await idle(engine, processed: 2)
        let expiredLoads = await store.loads; XCTAssertEqual(expiredLoads, beforeExpiry + 1)
        await transport.emit(.connected(key)); await transport.emit(.incomingRead(key.peer, .init(1)))
        try await idle(engine, processed: 4)
        let reads = await transport.commands()
        let snapshot = try XCTUnwrap(reads.compactMap { if case .answerRead(_, _, let value?) = $0 { value } else { nil } }.last)
        XCTAssertEqual(try ExchangeFrame.decode(snapshot.frame).token, batch.windows[1].token)
        await engine.reset()
        let beforeResetStart = await store.loads
        await engine.start()
        let afterResetStart = await store.loads; XCTAssertEqual(afterResetStart, beforeResetStart + 1)
        await engine.stop(); await transport.finish()
    }

    func testRecoveryFailureKeepsParticipationDisabledUntilASuccessfulStart() async throws {
        let queue = ControlledReceiptQueue()
        var session = EncounterSamples.receipt(); session.sessionFlag = true
        try await queue.enqueue(session); await queue.setWrites(failing: true)
        let transport = RuntimeTransport(), store = RuntimeTokenStore(try EncounterSamples.batch()), clock = ManualEncounterClock()
        let engine = engine(transport, store, clock, queue: queue)
        await engine.start(); try await idle(engine, processed: 1)
        let before = await transport.commands(); XCTAssertFalse(before.contains(.startDiscovery))
        await queue.setWrites(); await engine.start()
        let after = await transport.commands(); XCTAssertTrue(after.contains(.startDiscovery))
        let recovered = try await queue.pending(); XCTAssertEqual(recovered.count, 1)
        XCTAssertTrue(recovered[0].isFinalEvidence); XCTAssertEqual(recovered[0].observedDuration, 0)
        await engine.stop(); await transport.finish()
    }

    func testUnconsumedDiagnosticStreamRetainsOnlyTheNewest256Events() async throws {
        let transport = RuntimeTransport(), store = RuntimeTokenStore(try EncounterSamples.batch()), clock = ManualEncounterClock()
        var engine: EncounterEngine? = engine(transport, store, clock)
        let events = try XCTUnwrap(engine).events
        await engine?.start()
        for _ in 0..<600 { await transport.emit(.availabilityChanged(.available)) }
        try await idle(try XCTUnwrap(engine), processed: 601)
        await engine?.stop()
        engine = nil
        var recorded: [EncounterEngineEvent] = []
        for await event in events { recorded.append(event) }
        XCTAssertEqual(recorded.count, 256)
        XCTAssertEqual(recorded.last, .discoveryChanged(false))
        XCTAssertFalse(recorded.contains(.discoveryChanged(true)))
        await transport.finish()
    }

    func testFinishedTransportStreamReportsUnavailableAndStopsParticipation() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.setObservations(to: .second, enabled: false)
        try await rig.start()
        let events = rig.first.engine.events
        await rig.link.finishEvents(on: .first)
        for _ in 0..<10000 {
            let commands = await rig.first.transport.commands()
            if commands.contains(.stopDiscovery) { break }
            await Task.yield()
        }
        await rig.first.engine.stop()
        let commands = await rig.first.transport.commands()
        XCTAssertTrue(commands.contains(.stopDiscovery))
        let discarded = try await rig.first.queue.pending(); XCTAssertTrue(discarded.isEmpty)
        var iterator = events.makeAsyncIterator()
        var unavailable = false
        while let event = await iterator.next() {
            if event == .radioAvailability(.unavailable) { unavailable = true }
            if event == .discoveryChanged(false) { break }
        }
        XCTAssertTrue(unavailable)
        await rig.first.engine.start()
        let restarted = await rig.first.transport.commands()
        XCTAssertEqual(restarted.filter { $0 == .startDiscovery }.count, 1)
        try await rig.stop()
    }
}

private actor RuntimeTokenStore: TokenBatchStore {
    private var batch: TokenBatch?
    private var failing = false
    private(set) var loads = 0
    init(_ batch: TokenBatch) { self.batch = batch }
    func setFailingLoads(_ value: Bool) { failing = value }
    func load() throws -> TokenBatch? {
        loads += 1
        if failing { throw Failure.load }
        return batch
    }
    func save(_ batch: TokenBatch) { self.batch = batch }
    func clear() { batch = nil }
    private enum Failure: Error { case load }
}

private actor RuntimeTransport: BluetoothTransport {
    nonisolated let events: AsyncStream<BluetoothEvent>
    private let continuation: AsyncStream<BluetoothEvent>.Continuation
    private var log: [BluetoothCommand] = []
    init() {
        let stream = AsyncStream<BluetoothEvent>.makeStream()
        events = stream.stream; continuation = stream.continuation
        continuation.yield(.availabilityChanged(.available))
    }
    func execute(_ command: BluetoothCommand) { log.append(command) }
    func emit(_ event: BluetoothEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
    func commands() -> [BluetoothCommand] { log }
}
