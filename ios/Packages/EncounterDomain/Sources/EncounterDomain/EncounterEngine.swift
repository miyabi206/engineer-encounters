import Foundation

/// Thin serialized I/O shell; all exchange and deadline policy lives in EncounterEngineCore.
public actor EncounterEngine {
    /// Supplies privacy-safe diagnostics in the order the core produced them.
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
    private struct Pending {
        let input: EncounterEngineInput
        let completion: CheckedContinuation<Void, Never>
        let isTransport: Bool
    }
    private var pending: [Pending] = []
    private var draining = false

    /// Counts fully handled delegate events, allowing deterministic fake delivery fences.
    public private(set) var processedTransportEventCount: UInt64 = 0

    /// Session flags always come from the caller; this engine never chooses encounter kind.
    public init(transport: any BluetoothTransport, tokenProvider: TokenProvider, receiptQueue: any ReceiptQueue,
                clock: any EncounterClock = SystemEncounterClock(), approach: PresenceApproach = .heldConnection,
                sessionFlag: @escaping @Sendable () async -> Bool,
                nonceSource: @escaping @Sendable () -> ExchangeNonce = { ExchangeNonce() },
                identitySource: @escaping @Sendable () -> UUID = { UUID() }) {
        self.transport = transport; tokens = tokenProvider; queue = receiptQueue; self.clock = clock
        self.sessionFlag = sessionFlag
        core = EncounterEngineCore(approach: approach, nonceSource: nonceSource, identitySource: identitySource)
        let stream = AsyncStream<EncounterEngineEvent>.makeStream()
        events = stream.stream; continuation = stream.continuation
    }

    deinit { eventTask?.cancel(); wakeTask?.cancel(); continuation.finish() }

    /// Enables participation only while the radio and a valid token are available.
    public func start() async {
        if eventTask == nil {
            let stream = transport.events
            eventTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await self?.submit(.transport(event), isTransport: true)
                }
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
    public func refresh() async { await submit(.wakeUp) }

    private func submit(_ input: EncounterEngineInput, isTransport: Bool = false) async {
        await withCheckedContinuation { completion in
            pending.append(Pending(input: input, completion: completion, isTransport: isTransport))
            if !draining {
                draining = true
                Task { await self.drain() }
            }
        }
    }
    private func context() async -> EncounterEngineContext {
        let time = await clock.now()
        let token = try? await tokens.window(at: time.wall)
        let flag = await sessionFlag()
        return EncounterEngineContext(time: time, tokenWindow: token, sessionFlag: flag)
    }
    private func drain() async {
        while !pending.isEmpty {
            let next = pending.removeFirst()
            let context = await context()
            let output = core.receive(next.input, context: context)
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
