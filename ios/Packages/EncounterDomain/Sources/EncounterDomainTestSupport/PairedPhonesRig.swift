import Foundation
import EncounterDomain

/// One real actor runtime backed exclusively by fake radio, storage and clocks.
public struct FakeEncounterPhone: Sendable {
    public let engine: EncounterEngine
    public let transport: FakeBluetoothTransport
    public let clock: ManualEncounterClock
    public let queue: any ReceiptQueue
    public let tokens: InMemoryTokenBatchStore
    public let session: ManualSessionFlag
}

/// Reports a delivery fence failure without leaking frames or receipt evidence.
public enum FakeRigError: Error, Sendable { case deliveryDidNotSettle }

private final class FakeIdentitySource: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private let seed: UInt64
    init(_ seed: UInt64) { self.seed = seed }
    func nonce() -> ExchangeNonce {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        return EncounterSamples.nonce(seed: seed &+ sequence)
    }
    func identity() -> UUID {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        return UUID(uuidString: String(format: "00000000-0000-0000-%04llx-%012llx", seed & 0xffff, sequence))!
    }
}

/// A paired-phones rig fences ordered event delivery rather than sleeping or guessing task timing.
public struct PairedPhonesRig: Sendable {
    public let first: FakeEncounterPhone
    public let second: FakeEncounterPhone
    public let link: FakeBluetoothLink

    /// Creates independent clocks so each phone must earn its own two-minute duration.
    public static func make(approach: PresenceApproach = .heldConnection, firstSession: Bool = false,
                            secondSession: Bool = false, windowAge: TimeInterval = 0,
                            firstQueue: (any ReceiptQueue)? = nil,
                            secondQueue: (any ReceiptQueue)? = nil) async throws -> Self {
        let link = FakeBluetoothLink()
        func phone(_ id: FakePhoneID, session: Bool, queue: (any ReceiptQueue)?) async throws -> FakeEncounterPhone {
            let wall = EncounterSamples.observationTime.addingTimeInterval(windowAge)
            let clock = ManualEncounterClock(wall: wall)
            let transport = await FakeBluetoothTransport(phone: id, link: link, clock: clock)
            let windows = try (0..<48).map { index in
                let from = EncounterSamples.observationTime.addingTimeInterval(Double(index) * 900)
                return try TokenWindow(token: EncounterSamples.token(seed: UInt64(id.rawValue * 1000 + index + 1)),
                                       validFrom: from, validUntil: from.addingTimeInterval(900))
            }
            let tokens = InMemoryTokenBatchStore(batch: try TokenBatch(windows: windows))
            let flag = ManualSessionFlag(session)
            let receipts = queue ?? InMemoryReceiptQueue()
            let source = FakeIdentitySource(UInt64(id.rawValue + 1) * 10000)
            let engine = EncounterEngine(transport: transport, tokenProvider: TokenProvider(store: tokens),
                                         receiptQueue: receipts, clock: clock, approach: approach,
                                         sessionFlag: { await flag.get() }, nonceSource: { source.nonce() },
                                         identitySource: { source.identity() })
            return FakeEncounterPhone(engine: engine, transport: transport, clock: clock, queue: receipts,
                                      tokens: tokens, session: flag)
        }
        let first = try await phone(.first, session: firstSession, queue: firstQueue)
        let second = try await phone(.second, session: secondSession, queue: secondQueue)
        return Self(first: first, second: second, link: link)
    }
    /// Starts both actor runtimes and completes all immediately deliverable fake operations.
    public func start() async throws { await first.engine.start(); await second.engine.start(); try await settle() }
    /// Advances both clocks; optional refresh models a background callback arriving late.
    public func advance(by seconds: TimeInterval, refreshing: Bool = true) async throws {
        // Both phones' time advances before either can dispatch a new radio operation.
        await first.clock.advance(by: seconds, deliverWakeUps: false)
        await second.clock.advance(by: seconds, deliverWakeUps: false)
        await first.clock.advance(by: 0); await second.clock.advance(by: 0)
        if refreshing { await first.engine.refresh(); await second.engine.refresh() }
        try await settle()
    }
    /// Advances one phone only to test independent elapsed-time requirements.
    public func advance(_ phone: FakePhoneID, by seconds: TimeInterval) async throws {
        let target = phone == .first ? first : second
        await target.clock.advance(by: seconds); await target.engine.refresh()
        try await settle()
    }
    /// Stops both phones, fences resulting disconnects, and leaves no live radio link.
    public func stop() async throws { await first.engine.stop(); await second.engine.stop(); try await settle() }
    /// Waits for every emitted delegate event to finish, with a bounded scheduler-yield budget.
    public func settle() async throws {
        for _ in 0..<10000 {
            let emittedFirst = await link.emittedCount(for: .first)
            let emittedSecond = await link.emittedCount(for: .second)
            let handledFirst = await first.engine.processedTransportEventCount
            let handledSecond = await second.engine.processedTransportEventCount
            if emittedFirst == handledFirst && emittedSecond == handledSecond {
                let idleFirst = await first.engine.isIdle, idleSecond = await second.engine.isIdle
                let finalFirst = await link.emittedCount(for: .first)
                let finalSecond = await link.emittedCount(for: .second)
                if idleFirst && idleSecond && finalFirst == handledFirst && finalSecond == handledSecond { return }
            }
            await Task.yield()
        }
        throw FakeRigError.deliveryDidNotSettle
    }
}

/// Local test oracle only: production confirmation belongs to the server.
public enum TestEncounterConfirmation {
    /// Requires reciprocal evidence on two phones, including both joined exchange nonces.
    public static func confirms(_ first: [EncounterReceipt], _ second: [EncounterReceipt]) -> Bool {
        for a in first {
            for b in second where matches(a, b) {
                if a.sessionFlag && b.sessionFlag { return true }
                guard a.hasQualifyingAmbientEvidence, b.hasQualifyingAmbientEvidence else { continue }
                if let prior = a.priorExchangeNonce {
                    guard b.priorExchangeNonce == prior,
                          let originalA = first.first(where: { $0.exchangeNonce == prior && $0.role == a.role }),
                          let originalB = second.first(where: { $0.exchangeNonce == prior && $0.role == b.role }),
                          originalA.priorExchangeNonce == nil, originalB.priorExchangeNonce == nil,
                          matches(originalA, originalB) else { continue }
                    return true
                }
                if a.priorExchangeNonce == nil && b.priorExchangeNonce == nil,
                   let checkpointA = a.checkpoint, let checkpointB = b.checkpoint,
                   reciprocal(checkpointA, checkpointB) { return true }
            }
        }
        return false
    }
    private static func reciprocal(_ a: ReceiptTokenPair, _ b: ReceiptTokenPair) -> Bool {
        a.ownToken != a.peerToken && a.ownToken == b.peerToken && a.peerToken == b.ownToken
    }
    private static func matches(_ a: EncounterReceipt, _ b: EncounterReceipt) -> Bool {
        a.protocolVersion == EncounterProtocol.version && a.protocolVersion == b.protocolVersion && a.role != b.role &&
        a.exchangeNonce == b.exchangeNonce && a.priorExchangeNonce == b.priorExchangeNonce && reciprocal(a.start, b.start)
    }
}

/// A queue with controllable durable-write completion and failures, for response-ordering tests.
public actor ControlledReceiptQueue: ReceiptQueue {
    private let backing = InMemoryReceiptQueue()
    private var hold = false
    private var fail = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var started: [(Int, CheckedContinuation<Void, Never>)] = []
    private var writeCount = 0
    public init() {}
    /// Applies to enqueue and update, never to reads or teardown removals.
    public func setWrites(held: Bool = false, failing: Bool = false) {
        hold = held; fail = failing
        if !held { let waiting = self.held; self.held.removeAll(); for continuation in waiting { continuation.resume() } }
    }
    /// Provides an explicit fence before inspecting the peripheral's withheld response.
    public func waitForWrite(number: Int = 1) async {
        if writeCount >= number { return }
        await withCheckedContinuation { started.append((number, $0)) }
    }
    private func gate() async throws {
        writeCount += 1
        let waiting = started.filter { $0.0 <= writeCount }
        started.removeAll { $0.0 <= writeCount }
        for (_, continuation) in waiting { continuation.resume() }
        if hold { await withCheckedContinuation { held.append($0) } }
        if fail { throw Failure.writeRejected }
    }
    private enum Failure: Error { case writeRejected }
    public func enqueue(_ receipt: EncounterReceipt) async throws { try await gate(); try await backing.enqueue(receipt) }
    public func update(_ receipt: EncounterReceipt) async throws { try await gate(); try await backing.update(receipt) }
    public func pending() async throws -> [EncounterReceipt] { try await backing.pending() }
    public func acknowledge(_ identity: UUID) async throws { try await backing.acknowledge(identity) }
    public func removeExpired(asOf time: Date) async throws { try await backing.removeExpired(asOf: time) }
    public func removeAll() async throws { try await backing.removeAll() }
}
