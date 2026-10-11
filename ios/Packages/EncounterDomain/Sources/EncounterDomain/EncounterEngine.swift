import Foundation

/// Thin serialized I/O shell; all exchange and deadline policy lives in EncounterEngineCore.
public actor EncounterEngine {
    /// Supplies privacy-safe diagnostics in order, retaining the newest 256 unconsumed events.
    public nonisolated let events: AsyncStream<EncounterEngineEvent>
    private let continuation: AsyncStream<EncounterEngineEvent>.Continuation
    private let transport: any BluetoothTransport
    private let tokens: TokenProvider
    private let queue: any ReceiptQueue
    private let clock: any EncounterClock
    private let sessionFlag: @Sendable () async -> Bool
    private var core: EncounterEngineCore
    private var eventTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var wakeGeneration: UInt64 = 0
    private var wakeDeadline: TimeInterval?
    private var cachedWindow: TokenWindow?
    private var recoveredReceipts = false
    private var transportFinished = false
    private struct Pending {
        let input: EncounterEngineInput
        let completion: CheckedContinuation<Void, Never>
        let isTransport: Bool
        let reloadToken: Bool
    }
    private var pending: [Pending] = []
    private var draining = false

    /// Counts fully handled delegate events, allowing deterministic fake delivery fences.
    public private(set) var processedTransportEventCount: UInt64 = 0

    /// A delivery fence also waits for already-due runtime wake-ups, without triggering one.
    public var isIdle: Bool {
        get async {
            let time = await clock.now()
            return !draining && pending.isEmpty && (wakeDeadline.map { $0 > time.monotonic } ?? true)
        }
    }

    /// Session flags always come from the caller; this engine never chooses encounter kind.
    public init(transport: any BluetoothTransport, tokenProvider: TokenProvider, receiptQueue: any ReceiptQueue,
                clock: any EncounterClock = SystemEncounterClock(), approach: PresenceApproach = .heldConnection,
                sessionFlag: @escaping @Sendable () async -> Bool,
                nonceSource: @escaping @Sendable () -> ExchangeNonce = { ExchangeNonce() },
                identitySource: @escaping @Sendable () -> UUID = { UUID() }) {
        self.transport = transport; tokens = tokenProvider; queue = receiptQueue; self.clock = clock
        self.sessionFlag = sessionFlag
        core = EncounterEngineCore(approach: approach, nonceSource: nonceSource, identitySource: identitySource)
        let stream = AsyncStream<EncounterEngineEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = stream.stream; continuation = stream.continuation
    }

    deinit { eventTask?.cancel(); wakeTask?.cancel(); continuation.finish() }

    /// Enables participation only while the radio and a valid token are available.
    public func start() async {
        guard !transportFinished else { return }
        if eventTask == nil {
            let stream = transport.events
            eventTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await self?.submit(.transport(event), isTransport: true)
                }
                if !Task.isCancelled { await self?.transportEnded() }
            }
        }
        await submit(.start)
    }
    /// Cancels connections and deadlines and finalizes or discards unresolved evidence.
    public func stop() async { await submit(.stop) }
    /// Stops participation, clears the queue and abandons every nonce and attempt.
    public func reset() async { await submit(.reset) }
    /// Changes only attempts begun after this selection is processed.
    public func selectPresenceApproach(_ approach: PresenceApproach) async { await submit(.selectApproach(approach)) }
    /// Re-evaluates tokens and every deadline after foregrounding or replenishment.
    public func refresh() async { await submit(.wakeUp, reloadToken: true) }

    private func transportEnded() async {
        transportFinished = true
        await submit(.transport(.availabilityChanged(.unavailable)))
        await submit(.stop)
    }
    private func submit(_ input: EncounterEngineInput, isTransport: Bool = false, reloadToken: Bool = false) async {
        await withCheckedContinuation { completion in
            pending.append(Pending(input: input, completion: completion, isTransport: isTransport, reloadToken: reloadToken))
            if !draining {
                draining = true
                Task { await self.drain() }
            }
        }
    }
    private func context(reloadToken: Bool = false, starting: Bool = false) async -> EncounterEngineContext {
        let time = await clock.now()
        if core.isRunning || starting {
            if cachedWindow?.contains(time.wall) != true { cachedWindow = nil }
            if reloadToken || starting || cachedWindow == nil {
                do { cachedWindow = try await tokens.window(at: time.wall) }
                catch { /* A valid cached window survives a transient store read failure. */ }
            }
        } else { cachedWindow = nil }
        let flag = await sessionFlag()
        return EncounterEngineContext(time: time, tokenWindow: cachedWindow, sessionFlag: flag)
    }
    private func recoverReceipts() async -> Bool {
        guard !recoveredReceipts else { return true }
        do {
            for var receipt in try await queue.pending() where !receipt.isFinalEvidence {
                if receipt.sessionFlag || receipt.hasQualifyingAmbientEvidence {
                    receipt.isFinalEvidence = true
                    try await queue.update(receipt)
                } else { try await queue.acknowledge(receipt.id) }
            }
            recoveredReceipts = true
            return true
        } catch {
            continuation.yield(.receiptStorageFailed)
            return false
        }
    }
    private func drain() async {
        while !pending.isEmpty {
            let next = pending.removeFirst()
            let starting: Bool
            if case .start = next.input {
                guard await recoverReceipts() else { next.completion.resume(); continue }
                starting = true
            } else { starting = false }
            let context = await context(reloadToken: next.reloadToken, starting: starting)
            let output = core.receive(next.input, context: context)
            if !core.isRunning { cachedWindow = nil }
            let deadline = await apply(output)
            schedule(deadline)
            if next.isTransport { processedTransportEventCount &+= 1 }
            next.completion.resume()
        }
        draining = false
    }
    private func apply(_ output: EncounterEngineOutput) async -> TimeInterval? {
        var deadline = output.wakeUpDeadline
        for effect in output.effects {
            switch effect {
            case .event(let event): continuation.yield(event)
            case .transport(let command): await transport.execute(command)
            case .queue(let id, let write):
                var success = true
                do {
                    switch write {
                    case .enqueue(let receipt): try await queue.enqueue(receipt)
                    case .update(let receipt): try await queue.update(receipt)
                    case .remove(let identity): try await queue.acknowledge(identity)
                    case .removeAll: try await queue.removeAll()
                    }
                } catch { success = false }
                if let id {
                    let context = await context()
                    deadline = await apply(core.receive(.queueResult(id, success: success), context: context))
                } else if !success { continuation.yield(.receiptStorageFailed) }
            }
        }
        return deadline
    }
    private func schedule(_ deadline: TimeInterval?) {
        guard deadline != wakeDeadline else { return }
        wakeTask?.cancel(); wakeTask = nil; wakeDeadline = deadline; wakeGeneration &+= 1
        guard let deadline else { return }
        let generation = wakeGeneration
        let clock = clock
        wakeTask = Task { [weak self] in
            do {
                try await clock.wait(until: deadline)
                guard !Task.isCancelled else { return }
                await self?.woke(generation)
            } catch { /* Cancellation is the clock's ordinary teardown path. */ }
        }
    }
    private func woke(_ generation: UInt64) async {
        guard generation == wakeGeneration else { return }
        wakeDeadline = nil; wakeTask = nil
        await submit(.wakeUp)
    }
}
