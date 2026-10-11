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

    func testDefaultApproachDisconnectsCentralLinkAfterFirstExchange() async throws {
        let transport = RuntimeTransport(), store = RuntimeTokenStore(try EncounterSamples.batch())
        let queue = InMemoryReceiptQueue(), clock = ManualEncounterClock()
        let engine = EncounterEngine(transport: transport, tokenProvider: TokenProvider(store: store),
                                     receiptQueue: queue, clock: clock, sessionFlag: { false })
        let peer = FakePhoneID.second.peerHandle
        let key = BluetoothConnection(peer: peer, role: .central)
        await engine.start(); try await idle(engine, processed: 1)
        await transport.emit(.peerObserved(peer)); try await idle(engine, processed: 2)
        await transport.emit(.connected(key)); try await idle(engine, processed: 3)
        let reading = await transport.commands()
        let read = try XCTUnwrap(reading.compactMap { if case .read(_, let id) = $0 { id } else { nil } }.first)
        let frame = try ExchangeFrame(phase: .initialExchange, token: EncounterSamples.token(seed: 999),
                                      nonce: EncounterSamples.nonce())
        await transport.emit(.frameRead(peer, read, frame.encoded())); try await idle(engine, processed: 4)
        let writing = await transport.commands()
        let write = try XCTUnwrap(writing.compactMap { if case .write(_, let id, _) = $0 { id } else { nil } }.first)
        await transport.emit(.writeAcknowledged(peer, write)); try await idle(engine, processed: 5)
        let receipts = try await queue.pending()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.role, .central)
        XCTAssertEqual(receipts.first?.exchangeNonce, frame.nonce)
        let completed = await transport.commands()
        XCTAssertTrue(completed.contains(.disconnect(key)))
        let time = await clock.now(); XCTAssertEqual(time.monotonic, 0)
        await engine.stop(); await transport.finish()
    }

    private func seedExpiry(_ queue: RuntimeExpiryQueue, expiresAt: Date) async throws -> (EncounterReceipt, EncounterReceipt) {
        func receipt(_ index: Int) -> EncounterReceipt {
            let sample = EncounterSamples.receipt(index)
            return EncounterReceipt(id: sample.id, role: sample.role, exchangeNonce: sample.exchangeNonce,
                start: .init(ownToken: sample.start.ownToken, peerToken: sample.start.peerToken,
                             observedAt: expiresAt.addingTimeInterval(-EncounterProtocol.receiptLifetime)), isFinalEvidence: true)
        }
        let live = receipt(1), terminal = receipt(2)
        try await queue.enqueue(live); try await queue.enqueue(terminal); try await queue.acknowledge(terminal.id)
        return (live, terminal)
    }

    private func assertExpired(_ queue: RuntimeExpiryQueue, _ receipts: (EncounterReceipt, EncounterReceipt)) async throws {
        let pending = try await queue.pending(); XCTAssertTrue(pending.isEmpty)
        // An expired terminal identity no longer suppresses a duplicate insertion.
        try await queue.enqueue(receipts.0)
        try await queue.enqueue(receipts.1)
        let reinserted = try await queue.pending(); XCTAssertEqual(reinserted, [receipts.0, receipts.1])
        try await queue.removeAll()
    }

    func testEveryStartAndRefreshExpireReceiptsAndTombstonesUsingCurrentWallTime() async throws {
        let queue = RuntimeExpiryQueue(), clock = ManualEncounterClock()
        let transport = RuntimeTransport(), store = RuntimeTokenStore(try EncounterSamples.batch())
        let engine = engine(transport, store, clock, queue: queue)
        let wall = (await clock.now()).wall
        var seeded = try await seedExpiry(queue, expiresAt: wall.addingTimeInterval(-1))
        var unfinished = seeded.0; unfinished.isFinalEvidence = false
        try await queue.update(unfinished)
        await engine.start(); try await idle(engine, processed: 1)
        try await assertExpired(queue, seeded)
        // Start also maintains while already participating, and after a stop.
        for stopped in [false, true] {
            if stopped { await engine.stop() }
            await clock.advance(by: 0, wallBy: 1)
            seeded = try await seedExpiry(queue, expiresAt: (await clock.now()).wall.addingTimeInterval(-1))
            await engine.start()
            try await assertExpired(queue, seeded)
        }
        await clock.advance(by: 0, wallBy: 1)
        seeded = try await seedExpiry(queue, expiresAt: (await clock.now()).wall.addingTimeInterval(-1))
        await engine.refresh(); try await assertExpired(queue, seeded)
        let times = await queue.maintenanceTimes
        XCTAssertEqual(times, (0...3).map { wall.addingTimeInterval(Double($0)) })
        await engine.stop()
        seeded = try await seedExpiry(queue, expiresAt: (await clock.now()).wall.addingTimeInterval(-1))
        await engine.refresh(); try await assertExpired(queue, seeded)
        await engine.stop(); await transport.finish()
    }

    func testRunningMaintenanceExpiresReceiptsAndTombstonesAtFifteenMonotonicMinutes() async throws {
        let queue = RuntimeExpiryQueue(), clock = ManualEncounterClock()
        let transport = RuntimeTransport(), store = RuntimeTokenStore(try EncounterSamples.batch(count: 3))
        let engine = engine(transport, store, clock, queue: queue)
        await engine.start(); try await idle(engine, processed: 1)
        let wall = (await clock.now()).wall
        let seeded = try await seedExpiry(queue, expiresAt: wall.addingTimeInterval(1))
        await clock.advance(by: 899); try await idle(engine, processed: 1)
        let before = try await queue.pending(); XCTAssertEqual(before, [seeded.0])
        let beforeTimes = await queue.maintenanceTimes; XCTAssertEqual(beforeTimes, [wall])
        await clock.advance(by: 1); try await idle(engine, processed: 1)
        try await assertExpired(queue, seeded)
        let times = await queue.maintenanceTimes; XCTAssertEqual(times, [wall, wall.addingTimeInterval(900)])
        await engine.stop()
        await clock.advance(by: 1800); try await idle(engine, processed: 1)
        let stoppedTimes = await queue.maintenanceTimes; XCTAssertEqual(stoppedTimes, times)
        await transport.finish()
    }

    func testFailedExpiryDoesNotDisableParticipationOrSpinAndRetriesAtNextMaintenance() async throws {
        let queue = RuntimeExpiryQueue(), clock = ManualEncounterClock()
        await queue.setFailing(true)
        let transport = RuntimeTransport(), store = RuntimeTokenStore(try EncounterSamples.batch(count: 3))
        let engine = engine(transport, store, clock, queue: queue)
        await engine.start(); try await idle(engine, processed: 1)
        let commands = await transport.commands(); XCTAssertTrue(commands.contains(.startDiscovery))
        await clock.advance(by: 900); try await idle(engine, processed: 1)
        let failedTimes = await queue.maintenanceTimes; XCTAssertEqual(failedTimes.count, 2)
        await transport.emit(.availabilityChanged(.available)); try await idle(engine, processed: 2)
        await clock.advance(by: 899, wallBy: -50_000); try await idle(engine, processed: 2)
        let unchanged = await queue.maintenanceTimes; XCTAssertEqual(unchanged.count, 2)
        let wall = (await clock.now()).wall
        let seeded = try await seedExpiry(queue, expiresAt: wall.addingTimeInterval(-1))
        await queue.setFailing(false)
        await clock.advance(by: 1, wallBy: 0); try await idle(engine, processed: 2)
        try await assertExpired(queue, seeded)
        let retried = await queue.maintenanceTimes; XCTAssertEqual(retried.count, 3)
        XCTAssertEqual(retried.last, wall)
        await engine.stop(); await transport.finish()
    }

    func testCompletionContextRechecksTimeAfterAnAsyncSessionCallback() async throws {
        let batch = try EncounterSamples.batch(start: EncounterSamples.observationTime.addingTimeInterval(-899), count: 2)
        let transport = RuntimeTransport(), store = RuntimeTokenStore(batch), clock = ManualEncounterClock()
        let flag = RuntimeSessionGate(), queue = RuntimeExpiryQueue()
        let engine = EncounterEngine(transport: transport, tokenProvider: TokenProvider(store: store), receiptQueue: queue,
                                     clock: clock, sessionFlag: { await flag.get() })
        await engine.start(); try await idle(engine, processed: 1)
        let peer = PeerHandle(), key = BluetoothConnection(peer: peer, role: .central)
        await transport.emit(.peerObserved(peer)); try await idle(engine, processed: 2)
        await transport.emit(.connected(key)); try await idle(engine, processed: 3)
        let reads = await transport.commands()
        let read = try XCTUnwrap(reads.compactMap { if case .read(_, let id) = $0 { id } else { nil } }.last)
        let frame = try ExchangeFrame(phase: .initialExchange, token: EncounterSamples.token(seed: 999), nonce: EncounterSamples.nonce())
        await transport.emit(.frameRead(peer, read, frame.encoded())); try await idle(engine, processed: 4)
        let writes = await transport.commands()
        let write = try XCTUnwrap(writes.compactMap { if case .write(_, let id, _) = $0 { id } else { nil } }.last)
        await flag.holdNext()
        await transport.emit(.writeAcknowledged(peer, write))
        await flag.waitUntilHeld()
        await clock.advance(by: 1, deliverWakeUps: false)
        await flag.release(); try await idle(engine, processed: 5)
        let enqueues = await queue.enqueues; XCTAssertEqual(enqueues, 0)
        let commands = await transport.commands()
        XCTAssertTrue(commands.contains(.disconnect(key)))
        XCTAssertFalse(commands.contains(.stopDiscovery))
        await engine.stop(); await transport.finish()
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

    func testStoppedTransportEventsDoNotCacheTokensAndRestartServesTheReplacedBatch() async throws {
        for reset in [false, true] {
            let batch = try EncounterSamples.batch(count: 1)
            let transport = RuntimeTransport(), store = RuntimeTokenStore(batch), clock = ManualEncounterClock()
            let engine = engine(transport, store, clock)
            await engine.start(); try await idle(engine, processed: 1)
            if reset { await engine.reset() } else { await engine.stop() }
            let before = await store.loads
            await transport.emit(.availabilityChanged(.available)); try await idle(engine, processed: 2)
            let afterEvent = await store.loads; XCTAssertEqual(afterEvent, before)
            await engine.refresh()
            let afterRefresh = await store.loads; XCTAssertEqual(afterRefresh, before)
            let replacement = try TokenWindow(token: EncounterSamples.token(seed: 999),
                                              validFrom: batch.windows[0].validFrom, validUntil: batch.windows[0].validUntil)
            await store.save(try TokenBatch(windows: [replacement]))
            await engine.start()
            let afterStart = await store.loads; XCTAssertEqual(afterStart, before + 1)
            let key = BluetoothConnection(peer: PeerHandle(), role: .peripheral)
            await transport.emit(.connected(key)); await transport.emit(.incomingRead(key.peer, .init(1)))
            try await idle(engine, processed: 4)
            let commands = await transport.commands()
            let snapshot = try XCTUnwrap(commands.compactMap { if case .answerRead(_, _, let value?) = $0 { value } else { nil } }.last)
            XCTAssertEqual(try ExchangeFrame.decode(snapshot.frame).token, replacement.token)
            await engine.stop(); await transport.finish()
        }
    }

    func testStartReloadsAValidCachedWindowEvenWhenAlreadyRunning() async throws {
        let batch = try EncounterSamples.batch(count: 1)
        let transport = RuntimeTransport(), store = RuntimeTokenStore(batch), clock = ManualEncounterClock()
        let engine = engine(transport, store, clock)
        await engine.start(); try await idle(engine, processed: 1)
        let before = await store.loads
        let replacement = try TokenWindow(token: EncounterSamples.token(seed: 999),
                                          validFrom: batch.windows[0].validFrom, validUntil: batch.windows[0].validUntil)
        await store.save(try TokenBatch(windows: [replacement]))
        await engine.start()
        let after = await store.loads; XCTAssertEqual(after, before + 1)
        let key = BluetoothConnection(peer: PeerHandle(), role: .peripheral)
        await transport.emit(.connected(key)); await transport.emit(.incomingRead(key.peer, .init(1)))
        try await idle(engine, processed: 3)
        let commands = await transport.commands()
        let snapshot = try XCTUnwrap(commands.compactMap { if case .answerRead(_, _, let value?) = $0 { value } else { nil } }.last)
        XCTAssertEqual(try ExchangeFrame.decode(snapshot.frame).token, replacement.token)
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

private actor RuntimeExpiryQueue: ReceiptQueue {
    private let backing = InMemoryReceiptQueue()
    private var failing = false
    private(set) var maintenanceTimes: [Date] = []
    private(set) var enqueues = 0
    func setFailing(_ value: Bool) { failing = value }
    func enqueue(_ receipt: EncounterReceipt) async throws { enqueues += 1; try await backing.enqueue(receipt) }
    func update(_ receipt: EncounterReceipt) async throws { try await backing.update(receipt) }
    func pending() async throws -> [EncounterReceipt] { try await backing.pending() }
    func acknowledge(_ identity: UUID) async throws { try await backing.acknowledge(identity) }
    func removeExpired(asOf time: Date) async throws {
        maintenanceTimes.append(time)
        if failing { throw Failure.maintenance }
        try await backing.removeExpired(asOf: time)
    }
    func removeAll() async throws { try await backing.removeAll() }
    private enum Failure: Error { case maintenance }
}

private actor RuntimeSessionGate {
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func holdNext() { shouldHold = true }
    func get() async -> Bool {
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { held = $0; waiting?.resume(); waiting = nil }
        }
        return false
    }
    func waitUntilHeld() async {
        if held == nil { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { held?.resume(); held = nil }
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
