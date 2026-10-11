#if DEVELOPMENT_BUILD || INTERNAL_BUILD
import EncounterDomain
import EncounterDomainTestSupport
import Foundation
import XCTest
@testable import EngineerEncounters

final class EncounterRuntimeTests: XCTestCase {
    @MainActor
    func testDefaultApproachDisconnectsCentralLinkAfterFirstExchange() async throws {
        let clock = ManualEncounterClock(), link = FakeBluetoothLink()
        let transport = await FakeBluetoothTransport(phone: .first, link: link, clock: clock)
        let otherTransport = await FakeBluetoothTransport(phone: .second, link: link, clock: clock)
        let queue = InMemoryReceiptQueue()
        let ownStore = InMemoryTokenBatchStore(batch: try EncounterSamples.batch())
        let otherWindow = try TokenWindow(token: EncounterSamples.token(seed: 999),
            validFrom: EncounterSamples.observationTime, validUntil: EncounterSamples.observationTime.addingTimeInterval(900))
        let otherStore = InMemoryTokenBatchStore(batch: try TokenBatch(windows: [otherWindow]))
        let other = EncounterEngine(transport: otherTransport, tokenProvider: TokenProvider(store: otherStore),
            receiptQueue: InMemoryReceiptQueue(), clock: clock, sessionFlag: { false })
        let runtime = EncounterRuntime(transportFactory: { transport }, queueOpener: { queue },
            tokenStore: ownStore, clock: clock)
        var exchanges = 0
        runtime.observeEvents { if case .exchangeCompleted(role: .central, nonceDigest: _) = $0 { exchanges += 1 } }
        await link.setObservations(to: .second, enabled: false)
        await other.start()
        try await eventually {
            let idle = await other.isIdle, commands = await otherTransport.commands()
            return idle && commands.contains(.startDiscovery)
        }
        await runtime.start()
        let key = BluetoothConnection(peer: FakePhoneID.second.peerHandle, role: .central)
        try await eventually {
            let commands = await transport.commands()
            return exchanges == 1 && commands.contains(.disconnect(key))
        }
        let receipts = try await queue.pending()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.role, .central)
        XCTAssertNil(receipts.first?.priorExchangeNonce)
        let time = await clock.now(); XCTAssertEqual(time.monotonic, 0)
        await runtime.stop(); await other.stop()
    }

    @MainActor
    func testParticipationOffNeverBuildsTransportIncludingSummaryAndReset() async throws {
        let queue = InMemoryReceiptQueue()
        let clock = ManualEncounterClock()
        let link = FakeBluetoothLink()
        var builds = 0
        let runtime = EncounterRuntime(transportFactory: {
            builds += 1
            return await FakeBluetoothTransport(phone: .first, link: link, clock: clock)
        }, queueOpener: { queue }, tokenStore: InMemoryTokenBatchStore(), clock: clock)
        await runtime.refreshLocalSummary()
        await runtime.refresh()
        let reset = await runtime.resetTrial()
        XCTAssertTrue(reset)
        await runtime.stop()
        XCTAssertEqual(builds, 0)
        XCTAssertEqual(runtime.status.pendingReceiptCount, 0)
    }

    @MainActor
    func testResetSucceedsOnlyAfterVerifyingQueueIsEmpty() async throws {
        let queue = RecoverableReceiptQueue()
        try await queue.enqueue(EncounterSamples.receipt())
        await queue.setRetainOnClear(true)
        let runtime = EncounterRuntime(queueOpener: { queue }, tokenStore: InMemoryTokenBatchStore())
        var confirmations = 0
        let rejected = await runtime.resetTrial { confirmations += 1 }
        XCTAssertFalse(rejected)
        XCTAssertEqual(confirmations, 0)
        XCTAssertFalse(runtime.status.storageUnavailable)
        await queue.setRetainOnClear(false)
        let confirmed = await runtime.resetTrial { confirmations += 1 }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(confirmations, 1)
        XCTAssertFalse(runtime.status.storageUnavailable)
        let pending = try await queue.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    @MainActor
    func testFailedQueueOpenRecoversAndRetryStartsEngine() async throws {
        let queue = InMemoryReceiptQueue()
        let clock = ManualEncounterClock()
        let link = FakeBluetoothLink()
        var opens = 0
        var builds = 0
        let runtime = EncounterRuntime(transportFactory: {
            builds += 1
            return await FakeBluetoothTransport(phone: .first, link: link, clock: clock)
        }, queueOpener: {
            opens += 1
            if opens == 1 { throw RuntimeTestFailure.storage }
            return queue
        }, tokenStore: InMemoryTokenBatchStore(batch: try EncounterSamples.batch()), clock: clock)
        await runtime.start()
        XCTAssertTrue(runtime.status.storageUnavailable)
        XCTAssertEqual(builds, 0)
        // A successful summary read clears the failure, even before Retry.
        await runtime.refreshLocalSummary()
        XCTAssertFalse(runtime.status.storageUnavailable)
        await runtime.start() // The same operation used by S22 Retry.
        try await eventually { runtime.status.discoveryOn }
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(builds, 1)
        await runtime.stop()
    }

    @MainActor
    func testSuccessfulQueueReadAndParticipationSwitchRecoverExistingEngine() async throws {
        let queue = RecoverableReceiptQueue()
        let clock = ManualEncounterClock()
        let link = FakeBluetoothLink()
        var builds = 0
        let runtime = EncounterRuntime(transportFactory: {
            builds += 1
            return await FakeBluetoothTransport(phone: .first, link: link, clock: clock)
        }, queueOpener: { queue }, tokenStore: InMemoryTokenBatchStore(batch: try EncounterSamples.batch()), clock: clock)
        await runtime.start()
        try await eventually { runtime.status.discoveryOn }
        await queue.setReadFailure(true)
        // Summary failure cannot stop an engine that is still participating.
        await runtime.refreshLocalSummary()
        XCTAssertNil(runtime.status.pendingReceiptCount)
        XCTAssertFalse(runtime.status.storageUnavailable)
        XCTAssertTrue(runtime.status.discoveryOn)
        await runtime.stop()
        XCTAssertTrue(runtime.status.storageUnavailable)
        await queue.setReadFailure(false)
        await runtime.refreshLocalSummary()
        XCTAssertFalse(runtime.status.storageUnavailable)
        await runtime.start()
        try await eventually { runtime.status.discoveryOn }
        XCTAssertEqual(builds, 1)
        await runtime.stop()
    }

    @MainActor
    func testEngineEventsReachTrialRecorderThroughInjectedFakeTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = TrialLog(fileURL: directory.appending(path: "trials.json"), now: { EncounterSamples.observationTime })
        let recorder = TrialRecorder(log: log, now: { EncounterSamples.observationTime })
        recorder.beginIfNeeded(metadata: TrialMetadata(buildKind: "Development", appVersion: "0.1", appBuild: "1",
            iOSVersion: "26", deviceModel: "test", presenceApproach: "heldConnection", participationEnabled: true,
            bluetoothAvailability: "unknown", batteryLevel: nil))
        let clock = ManualEncounterClock()
        let link = FakeBluetoothLink()
        let transport = await FakeBluetoothTransport(phone: .first, link: link, clock: clock)
        let queue = InMemoryReceiptQueue()
        let runtime = EncounterRuntime(transportFactory: { transport }, queueOpener: { queue },
            tokenStore: InMemoryTokenBatchStore(batch: try EncounterSamples.batch()), clock: clock)
        runtime.observeEvents { recorder.record($0) }
        await runtime.start()
        try await eventually { runtime.status.discoveryOn }
        // No second phone is attached: the real engine records discovery and a failed attempt.
        await transport.inject(.peerObserved(FakePhoneID.second.peerHandle))
        try await eventually {
            log.records.first?.distinctPeerCount == 1 && log.records.first?.attemptEnds.isEmpty == false
        }
        let record = try XCTUnwrap(log.records.first)
        XCTAssertEqual(record.metadata.bluetoothAvailability, "available")
        XCTAssertNotNil(record.discoveryElapsedSeconds)
        let saved = try JSONDecoder().decode([TrialRecord].self, from: Data(contentsOf: log.fileURL))
        XCTAssertEqual(saved.first, record)
        await runtime.stop()
    }

    #if DEVELOPMENT_BUILD
    @MainActor
    func testTokenPauseDuringLongLockedRunTopsUpAndRefreshesWithoutForegroundAction() async throws {
        let clock = ManualEncounterClock()
        let link = FakeBluetoothLink()
        let queue = InMemoryReceiptQueue()
        let store = InMemoryTokenBatchStore()
        let runtime = EncounterRuntime(transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: link, clock: clock)
        }, queueOpener: { queue }, tokenStore: store, clock: clock)
        var pauses = 0
        runtime.observeEvents { if case .participationPausedForLackOfToken = $0 { pauses += 1 } }
        await runtime.start()
        try await eventually { runtime.status.discoveryOn }
        await clock.advance(by: 13 * 3600)
        try await eventually { pauses == 1 && runtime.status.discoveryOn && !runtime.status.pausedForLackOfToken }
        let time = await clock.now()
        let batch = try await store.load()
        XCTAssertTrue(try XCTUnwrap(batch).windows.contains { $0.contains(time.wall) })
        await runtime.stop()
    }

    @MainActor
    func testFailedTokenTopUpDoesNotLoop() async throws {
        let clock = ManualEncounterClock()
        let link = FakeBluetoothLink()
        let queue = InMemoryReceiptQueue()
        let store = FailAfterFirstTokenSave()
        let runtime = EncounterRuntime(transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: link, clock: clock)
        }, queueOpener: { queue }, tokenStore: store, clock: clock)
        await runtime.start()
        try await eventually { runtime.status.discoveryOn }
        await clock.advance(by: 13 * 3600)
        try await eventually { await store.saveAttempts == 2 && runtime.status.pausedForLackOfToken }
        // Drain scheduler work to detect an accidental retry loop after the failing save.
        for _ in 0..<1000 { await Task.yield() }
        let attempts = await store.saveAttempts
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(runtime.status.discoveryOn)
        await runtime.stop()
    }
    #endif

    @MainActor
    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<10000 {
            if await condition() { return }
            await Task.yield()
        }
        throw RuntimeTestFailure.didNotSettle
    }
}

private enum RuntimeTestFailure: Error { case storage, didNotSettle }

private actor RecoverableReceiptQueue: ReceiptQueue {
    private let backing = InMemoryReceiptQueue()
    private var readFailure = false
    private var retainOnClear = false
    func setReadFailure(_ value: Bool) { readFailure = value }
    func setRetainOnClear(_ value: Bool) { retainOnClear = value }
    func enqueue(_ receipt: EncounterReceipt) async throws { try await backing.enqueue(receipt) }
    func update(_ receipt: EncounterReceipt) async throws { try await backing.update(receipt) }
    func pending() async throws -> [EncounterReceipt] {
        if readFailure { throw RuntimeTestFailure.storage }
        return try await backing.pending()
    }
    func acknowledge(_ identity: UUID) async throws { try await backing.acknowledge(identity) }
    func removeExpired(asOf time: Date) async throws { try await backing.removeExpired(asOf: time) }
    func removeAll() async throws {
        if !retainOnClear { try await backing.removeAll() }
    }
}

#if DEVELOPMENT_BUILD
private actor FailAfterFirstTokenSave: TokenBatchStore {
    private var batch: TokenBatch?
    private(set) var saveAttempts = 0
    func load() async throws -> TokenBatch? { batch }
    func save(_ batch: TokenBatch) async throws {
        saveAttempts += 1
        if saveAttempts > 1 { throw RuntimeTestFailure.storage }
        self.batch = batch
    }
    func clear() async throws { batch = nil }
}
#endif
#endif
