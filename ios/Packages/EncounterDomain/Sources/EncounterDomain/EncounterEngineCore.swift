import Foundation

/// Selection is captured when a new attempt starts; existing attempts retain their approach.
public enum PresenceApproach: Sendable, Equatable { case heldConnection, secondExchange }

/// Terminal reasons contain no frame bytes, tokens, nonces or wall timestamps.
public enum EncounterAttemptEndReason: Sendable, Equatable {
    case evidenceReached, connectTimeout, operationTimeout, failed, invalidFrame, disconnected
    case expired, stopped, reset, unavailable, noToken, storageFailure
}

/// Diagnostic events expose only temporary handles, digest labels and monotonic durations.
public enum EncounterEngineEvent: Sendable, Equatable {
    case radioAvailability(RadioAvailability)
    case discoveryChanged(Bool)
    case peerFirstObserved(PeerHandle)
    case exchangeCompleted(role: ExchangeRole, nonceDigest: String)
    case evidenceReached(role: ExchangeRole, nonceDigest: String, observedDuration: TimeInterval)
    case attemptEnded(role: ExchangeRole, reason: EncounterAttemptEndReason)
    case participationPausedForLackOfToken
    case receiptStorageFailed
}

/// Every reducer input carries a fresh time, token window and externally decided session flag.
public struct EncounterEngineContext: Sendable {
    public let time: EncounterTime
    public let tokenWindow: TokenWindow?
    public let sessionFlag: Bool
    public init(time: EncounterTime, tokenWindow: TokenWindow?, sessionFlag: Bool) {
        self.time = time; self.tokenWindow = tokenWindow; self.sessionFlag = sessionFlag
    }
}

/// External inputs and storage outcomes; the core never sleeps or performs I/O.
public enum EncounterEngineInput: Sendable {
    case start, stop, reset, wakeUp
    case selectApproach(PresenceApproach)
    case transport(BluetoothEvent)
    case queueResult(UInt64, success: Bool)
}

/// Queue effects preserve the storage package's existing identity and durability contract.
public enum EncounterQueueWrite: Sendable {
    case enqueue(EncounterReceipt), update(EncounterReceipt), remove(UUID), removeAll
}

/// Ordered effects; a queue effect with an identifier must be fed back as queueResult.
public enum EncounterEngineEffect: Sendable {
    case transport(BluetoothCommand)
    case queue(UInt64?, EncounterQueueWrite)
    case event(EncounterEngineEvent)
}

/// The deadline is advisory: every input also re-evaluates all expired deadlines.
public struct EncounterEngineOutput: Sendable {
    public let effects: [EncounterEngineEffect]
    public let wakeUpDeadline: TimeInterval?
}

/// Synchronous protocol and presence reducer, deterministic with injected nonce/identity sources.
public struct EncounterEngineCore: Sendable {
    private enum Stage: Sendable, Equatable { case connecting, reading, writing, ready, saving(UInt64), waiting }
    private struct Attempt: Sendable {
        let connection: BluetoothConnection
        let approach: PresenceApproach
        var stage: Stage
        var connected: Bool
        var deadline: TimeInterval?
        var operation: BluetoothRequestID?
        var offered: ExchangeFrame?
        var offeredUntil: Date?
        var pair: ReceiptTokenPair?
        var first: EncounterReceipt?
        var firstCompletedAt: TimeInterval?
        var retryAt: TimeInterval?
    }
    private struct Save: Sendable {
        let connection: BluetoothConnection
        let receipt: EncounterReceipt
        let incomingRequest: BluetoothRequestID?
        let isCheckpoint: Bool
        let original: EncounterReceipt?
    }
    private var attempts: [BluetoothConnection: Attempt] = [:]
    private var closing: Set<BluetoothConnection> = []
    private var saves: [UInt64: Save] = [:]
    private var backoff: [PeerHandle: TimeInterval] = [:]
    private var observed: Set<PeerHandle> = []
    private var consumedNonces: Set<ExchangeNonce> = []
    private var sequence: UInt64 = 0
    private var running = false
    private var discovering = false
    private var paused = false
    private var radio: RadioAvailability = .unknown
    private var approach: PresenceApproach
    private let nonceSource: @Sendable () -> ExchangeNonce
    private let identitySource: @Sendable () -> UUID

    /// Inject secure randomness in production and repeatable sources in tests.
    public init(approach: PresenceApproach = .heldConnection,
                nonceSource: @escaping @Sendable () -> ExchangeNonce = { ExchangeNonce() },
                identitySource: @escaping @Sendable () -> UUID = { UUID() }) {
        self.approach = approach; self.nonceSource = nonceSource; self.identitySource = identitySource
    }

    /// Includes incoming connections and outgoing pending connects in the four-slot limit.
    public var activeConnectionCount: Int {
        let active = Set(attempts.values.filter { $0.connected || $0.stage == .connecting }.map(\.connection))
        return active.union(closing).count
    }

    /// Reduces one ordered input; supplied monotonic time must never run backwards.
    public mutating func receive(_ input: EncounterEngineInput, context: EncounterEngineContext) -> EncounterEngineOutput {
        currentMonotonic = context.time.monotonic
        var effects: [EncounterEngineEffect] = []
        expire(context, effects: &effects)
        if case .transport = input { reconcile(context, effects: &effects) }
        if case .queueResult = input { reconcile(context, effects: &effects) }
        switch input {
        case .start: running = true
        case .stop, .reset:
            running = false
            for key in sortedKeys() { end(key, reason: isReset(input) ? .reset : .stopped, effects: &effects) }
            effects.append(.transport(.stopDiscovery))
            if discovering { effects.append(.event(.discoveryChanged(false))) }
            discovering = false
            observed.removeAll()
            if isReset(input) {
                backoff.removeAll(); consumedNonces.removeAll()
                effects.append(.queue(nil, .removeAll))
            }
        case .selectApproach(let selected): approach = selected
        case .wakeUp: break
        case .transport(let event): handle(event, context, effects: &effects)
        case .queueResult(let id, let success): saved(id, success, context, effects: &effects)
        }
        reconcile(context, effects: &effects)
        if canParticipate(context) {
            for key in sortedKeys() {
                guard var attempt = attempts[key], key.role == .central, attempt.stage == .waiting,
                      let firstAt = attempt.firstCompletedAt,
                      context.time.monotonic >= (attempt.retryAt ?? firstAt + EncounterProtocol.ambientPresenceThreshold) else { continue }
                if attempt.approach == .heldConnection {
                    beginRead(&attempt, context, effects: &effects)
                    attempts[key] = attempt
                } else if !closing.contains(key), activeConnectionCount < EncounterProtocol.activeConnectionLimit {
                    attempt.stage = .connecting
                    attempt.deadline = context.time.monotonic + EncounterProtocol.connectTimeout
                    attempt.retryAt = nil
                    attempts[key] = attempt
                    effects.append(.transport(.connect(key.peer)))
                }
            }
        }
        return EncounterEngineOutput(effects: effects, wakeUpDeadline: nextDeadline(context))
    }

    private func isReset(_ input: EncounterEngineInput) -> Bool { if case .reset = input { true } else { false } }
    private func sortedKeys() -> [BluetoothConnection] {
        attempts.keys.sorted {
            if $0.peer.id == $1.peer.id { return $0.role.rawValue < $1.role.rawValue }
            return $0.peer.id.uuidString < $1.peer.id.uuidString
        }
    }
    private mutating func nextID() -> UInt64 { sequence &+= 1; return sequence }
    private func window(_ context: EncounterEngineContext) -> TokenWindow? {
        guard let value = context.tokenWindow, value.contains(context.time.wall) else { return nil }
        return value
    }
    private func canParticipate(_ context: EncounterEngineContext) -> Bool {
        running && radio == .available && window(context) != nil
    }
    private mutating func reconcile(_ context: EncounterEngineContext, effects: inout [EncounterEngineEffect]) {
        let lacksToken = running && window(context) == nil
        if lacksToken && !paused { effects.append(.event(.participationPausedForLackOfToken)) }
        paused = lacksToken
        let desired = canParticipate(context)
        if desired != discovering {
            discovering = desired
            effects.append(.transport(desired ? .startDiscovery : .stopDiscovery))
            effects.append(.event(.discoveryChanged(desired)))
        }
        if !desired {
            for key in sortedKeys() {
                end(key, reason: lacksToken ? .noToken : (running ? .unavailable : .stopped), effects: &effects)
            }
        }
    }
    private mutating func expire(_ context: EncounterEngineContext, effects: inout [EncounterEngineEffect]) {
        for key in sortedKeys() {
            guard let attempt = attempts[key] else { continue }
            if let firstAt = attempt.firstCompletedAt,
               context.time.monotonic >= firstAt + EncounterProtocol.presenceAttemptLimit {
                end(key, reason: .expired, effects: &effects)
            } else if let deadline = attempt.deadline, context.time.monotonic >= deadline {
                end(key, reason: attempt.stage == .connecting ? .connectTimeout : .operationTimeout, effects: &effects)
            }
        }
        backoff = backoff.filter { $0.value > context.time.monotonic }
    }
    private func nextDeadline(_ context: EncounterEngineContext) -> TimeInterval? {
        guard running else { return nil }
        var dates: [TimeInterval] = []
        if let token = window(context) {
            dates.append(context.time.monotonic + token.validUntil.timeIntervalSince(context.time.wall))
        } else { dates.append(context.time.monotonic + EncounterProtocol.duplicateAttemptBackoff) }
        for attempt in attempts.values {
            if let deadline = attempt.deadline { dates.append(deadline) }
            if let firstAt = attempt.firstCompletedAt {
                dates.append(firstAt + EncounterProtocol.presenceAttemptLimit)
                if attempt.connection.role == .central && attempt.stage == .waiting {
                    let checkpoint = attempt.retryAt ?? firstAt + EncounterProtocol.ambientPresenceThreshold
                    // A full connection pool must not cause an already-due timer spin.
                    if checkpoint > context.time.monotonic { dates.append(checkpoint) }
                }
            }
        }
        return dates.min()
    }
    private mutating func handle(_ event: BluetoothEvent, _ context: EncounterEngineContext,
                                 effects: inout [EncounterEngineEffect]) {
        switch event {
        case .availabilityChanged(let value):
            radio = value; effects.append(.event(.radioAvailability(value)))
        case .peerObserved(let peer):
            if observed.insert(peer).inserted { effects.append(.event(.peerFirstObserved(peer))) }
            let key = BluetoothConnection(peer: peer, role: .central)
            guard canParticipate(context), attempts[key] == nil, !closing.contains(key), backoff[peer] == nil,
                  activeConnectionCount < EncounterProtocol.activeConnectionLimit else { return }
            attempts[key] = Attempt(connection: key, approach: approach, stage: .connecting, connected: false,
                                    deadline: context.time.monotonic + EncounterProtocol.connectTimeout)
            backoff[peer] = context.time.monotonic + EncounterProtocol.duplicateAttemptBackoff
            effects.append(.transport(.connect(peer)))
        case .connected(let key):
            guard canParticipate(context), !closing.contains(key) else { requestDisconnect(key, effects: &effects); return }
            if key.role == .central {
                guard var attempt = attempts[key], attempt.stage == .connecting else {
                    requestDisconnect(key, effects: &effects); return
                }
                attempt.connected = true
                beginRead(&attempt, context, effects: &effects)
                attempts[key] = attempt
            } else if var attempt = attempts[key] {
                if attempt.approach == .secondExchange && attempt.stage == .waiting && !attempt.connected {
                    guard activeConnectionCount < EncounterProtocol.activeConnectionLimit else {
                        requestDisconnect(key, effects: &effects); return
                    }
                    attempt.connected = true; attempt.stage = .ready
                    attempt.deadline = context.time.monotonic + EncounterProtocol.operationTimeout
                    attempts[key] = attempt
                }
            } else if activeConnectionCount < EncounterProtocol.activeConnectionLimit {
                attempts[key] = Attempt(connection: key, approach: approach, stage: .ready, connected: true,
                                        deadline: context.time.monotonic + EncounterProtocol.operationTimeout)
            } else { requestDisconnect(key, effects: &effects) }
        case .connectFailed(let peer):
            let key = BluetoothConnection(peer: peer, role: .central)
            closing.remove(key)
            if var failed = attempts[key], failed.stage == .connecting {
                failed.connected = false; failed.stage = .ready; attempts[key] = failed
                end(key, reason: .failed, effects: &effects)
            }
        case .frameRead(let peer, let id, let data):
            let key = BluetoothConnection(peer: peer, role: .central)
            guard var attempt = attempts[key], attempt.stage == .reading, attempt.operation == id else { return }
            guard canParticipate(context), let ownWindow = window(context),
                  let frame = try? ExchangeFrame.decode(data), frame.phase == phase(attempt), frame.priorNonce == nil,
                  (attempt.first == nil ? !consumedNonces.contains(frame.nonce) :
                    (attempt.approach == .heldConnection ? frame.nonce == attempt.first?.exchangeNonce :
                        frame.nonce != attempt.first?.exchangeNonce && !consumedNonces.contains(frame.nonce))) else {
                end(key, reason: .invalidFrame, effects: &effects); return
            }
            attempt.offered = frame
            attempt.pair = ReceiptTokenPair(ownToken: ownWindow.token, peerToken: frame.token, observedAt: context.time.wall)
            let writeID = BluetoothRequestID(nextID())
            let write = try! ExchangeFrame(phase: frame.phase, token: ownWindow.token, nonce: frame.nonce,
                                           priorNonce: frame.phase == .reconnectEvidence ? attempt.first?.exchangeNonce : nil)
            attempt.operation = writeID; attempt.stage = .writing
            attempt.deadline = context.time.monotonic + EncounterProtocol.operationTimeout
            attempts[key] = attempt
            effects.append(.transport(.write(peer, writeID, write.encoded())))
        case .readFailed(let peer, let id):
            let key = BluetoothConnection(peer: peer, role: .central)
            if attempts[key]?.stage == .reading && attempts[key]?.operation == id { end(key, reason: .failed, effects: &effects) }
        case .writeFailed(let peer, let id):
            let key = BluetoothConnection(peer: peer, role: .central)
            guard var attempt = attempts[key], attempt.stage == .writing, attempt.operation == id else { return }
            if phase(attempt) != .initialExchange {
                // An early peer-side checkpoint refusal may be retried within this attempt.
                attempt.stage = .waiting; attempt.deadline = nil; attempt.operation = nil
                attempt.offered = nil
                attempt.retryAt = context.time.monotonic + EncounterProtocol.duplicateAttemptBackoff
                if attempt.approach == .secondExchange {
                    attempt.connected = false; requestDisconnect(key, effects: &effects)
                }
                attempts[key] = attempt
            } else { end(key, reason: .failed, effects: &effects) }
        case .writeAcknowledged(let peer, let id):
            let key = BluetoothConnection(peer: peer, role: .central)
            guard let attempt = attempts[key], attempt.stage == .writing, attempt.operation == id,
                  let frame = attempt.offered, let pair = attempt.pair else { return }
            persist(attempt, frame: frame, pair: pair, request: nil, context, effects: &effects)
        case .disconnected(let key):
            closing.remove(key)
            guard var attempt = attempts[key] else { return }
            if attempt.approach == .secondExchange && attempt.stage == .waiting {
                attempt.connected = false; attempts[key] = attempt
            } else {
                attempt.connected = false
                if attempt.stage == .connecting { attempt.stage = .ready }
                attempts[key] = attempt
                end(key, reason: .disconnected, effects: &effects)
            }
        case .incomingRead(let peer, let id):
            let key = BluetoothConnection(peer: peer, role: .peripheral)
            guard canParticipate(context), let ownWindow = window(context), var attempt = attempts[key], attempt.connected,
                  attempt.stage == .ready || (attempt.stage == .waiting && attempt.approach == .heldConnection) else {
                effects.append(.transport(.answerRead(peer, id, nil))); return
            }
            let currentPhase = phase(attempt)
            let nonce = currentPhase == .heldConnectionCheckpoint ? attempt.first!.exchangeNonce : nonceSource()
            let frame = try! ExchangeFrame(phase: currentPhase, token: ownWindow.token, nonce: nonce)
            attempt.offered = frame; attempt.offeredUntil = ownWindow.validUntil
            attempt.stage = .ready; attempt.deadline = context.time.monotonic + EncounterProtocol.operationTimeout
            attempts[key] = attempt
            effects.append(.transport(.answerRead(peer, id, .init(frame: frame.encoded(), validUntil: ownWindow.validUntil))))
        case .incomingWrite(let peer, let id, let data):
            let key = BluetoothConnection(peer: peer, role: .peripheral)
            guard canParticipate(context), let attempt = attempts[key], attempt.connected, attempt.stage == .ready,
                  let offered = attempt.offered, let until = attempt.offeredUntil, context.time.wall < until,
                  let frame = try? ExchangeFrame.decode(data), frame.nonce == offered.nonce, frame.phase == offered.phase,
                  (frame.phase == .reconnectEvidence ? frame.priorNonce == attempt.first?.exchangeNonce : frame.priorNonce == nil) else {
                effects.append(.transport(.answerWrite(peer, id, success: false)))
                if attempts[key] != nil { end(key, reason: .invalidFrame, effects: &effects) }
                return
            }
            if let firstAt = attempt.firstCompletedAt,
               context.time.monotonic - firstAt < EncounterProtocol.ambientPresenceThreshold {
                var waiting = attempt
                waiting.stage = .waiting; waiting.deadline = nil; waiting.offered = nil
                attempts[key] = waiting
                effects.append(.transport(.answerWrite(peer, id, success: false)))
                return
            }
            let pair = ReceiptTokenPair(ownToken: offered.token, peerToken: frame.token, observedAt: context.time.wall)
            persist(attempt, frame: frame, pair: pair, request: id, context, effects: &effects)
        case .restored(let connections):
            for key in connections {
                guard let live = attempts[key], live.connected else {
                    requestDisconnect(key, effects: &effects); continue
                }
            }
        }
    }
    private func phase(_ attempt: Attempt) -> ExchangePhase {
        guard attempt.first != nil else { return .initialExchange }
        return attempt.approach == .heldConnection ? .heldConnectionCheckpoint : .reconnectEvidence
    }
    private mutating func beginRead(_ attempt: inout Attempt, _ context: EncounterEngineContext,
                                    effects: inout [EncounterEngineEffect]) {
        let id = BluetoothRequestID(nextID())
        attempt.stage = .reading; attempt.operation = id; attempt.offered = nil; attempt.retryAt = nil
        attempt.deadline = context.time.monotonic + EncounterProtocol.operationTimeout
        effects.append(.transport(.read(attempt.connection.peer, id)))
    }
    private mutating func persist(_ attempt: Attempt, frame: ExchangeFrame, pair: ReceiptTokenPair,
                                  request: BluetoothRequestID?, _ context: EncounterEngineContext,
                                  effects: inout [EncounterEngineEffect]) {
        var receipt: EncounterReceipt
        let checkpoint = frame.phase == .heldConnectionCheckpoint
        if checkpoint {
            receipt = attempt.first!
            receipt.checkpoint = pair
            receipt.observedDuration = context.time.monotonic - attempt.firstCompletedAt!
        } else {
            receipt = EncounterReceipt(id: identitySource(), role: attempt.connection.role, exchangeNonce: frame.nonce,
                                       priorExchangeNonce: frame.phase == .reconnectEvidence ? attempt.first?.exchangeNonce : nil,
                                       start: pair, observedDuration: attempt.firstCompletedAt.map { context.time.monotonic - $0 } ?? 0,
                                       sessionFlag: attempt.first?.sessionFlag ?? context.sessionFlag)
        }
        let id = nextID()
        saves[id] = Save(connection: attempt.connection, receipt: receipt, incomingRequest: request,
                         isCheckpoint: checkpoint, original: attempt.first)
        var saving = attempt; saving.stage = .saving(id)
        saving.deadline = context.time.monotonic + EncounterProtocol.operationTimeout
        attempts[attempt.connection] = saving
        effects.append(.queue(id, checkpoint ? .update(receipt) : .enqueue(receipt)))
    }
    private mutating func saved(_ id: UInt64, _ success: Bool, _ context: EncounterEngineContext,
                                effects: inout [EncounterEngineEffect]) {
        guard let save = saves.removeValue(forKey: id) else { return }
        guard var attempt = attempts[save.connection], attempt.stage == .saving(id) else {
            if success {
                if save.isCheckpoint, let original = save.original, original.sessionFlag {
                    finalize(original, preserve: true, effects: &effects)
                } else { effects.append(.queue(nil, .remove(save.receipt.id))) }
            }
            return
        }
        guard success else {
            if let request = save.incomingRequest { effects.append(.transport(.answerWrite(save.connection.peer, request, success: false))) }
            effects.append(.event(.receiptStorageFailed))
            end(save.connection, reason: .storageFailure, effects: &effects)
            return
        }
        consumedNonces.insert(save.receipt.exchangeNonce)
        if let request = save.incomingRequest { effects.append(.transport(.answerWrite(save.connection.peer, request, success: true))) }
        if save.receipt.hasQualifyingAmbientEvidence {
            // The original exchange must survive too: reconnect confirmation matches both nonces.
            if save.receipt.priorExchangeNonce != nil, let first = attempt.first { finalize(first, preserve: true, effects: &effects) }
            attempt.first = save.receipt; attempts[save.connection] = attempt
            if !save.isCheckpoint {
                effects.append(.event(.exchangeCompleted(role: save.connection.role, nonceDigest: save.receipt.exchangeNonce.diagnosticDigest)))
            }
            effects.append(.event(.evidenceReached(role: save.connection.role, nonceDigest: save.receipt.exchangeNonce.diagnosticDigest,
                                                   observedDuration: save.receipt.observedDuration)))
            end(save.connection, reason: .evidenceReached, effects: &effects)
        } else {
            attempt.first = save.receipt; attempt.firstCompletedAt = context.time.monotonic
            attempt.stage = .waiting; attempt.deadline = nil; attempt.operation = nil; attempt.offered = nil
            attempts[save.connection] = attempt
            consumedNonces.insert(save.receipt.exchangeNonce)
            effects.append(.event(.exchangeCompleted(role: save.connection.role, nonceDigest: save.receipt.exchangeNonce.diagnosticDigest)))
            if save.connection.role == .central && attempt.approach == .secondExchange {
                attempt.connected = false; attempts[save.connection] = attempt
                requestDisconnect(save.connection, effects: &effects)
            }
        }
    }
    private mutating func end(_ key: BluetoothConnection, reason: EncounterAttemptEndReason,
                              effects: inout [EncounterEngineEffect]) {
        guard let attempt = attempts.removeValue(forKey: key) else { return }
        if attempt.connected || attempt.stage == .connecting { requestDisconnect(key, effects: &effects) }
        if case .saving(let id) = attempt.stage, let request = saves[id]?.incomingRequest {
            effects.append(.transport(.answerWrite(key.peer, request, success: false)))
        }
        if let receipt = attempt.first { finalize(receipt, preserve: false, effects: &effects) }
        // Use the termination input's time, recorded by expire/receive, rather than a clock read.
        if key.role == .central { backoff[key.peer] = currentMonotonic + EncounterProtocol.duplicateAttemptBackoff }
        effects.append(.event(.attemptEnded(role: key.role, reason: reason)))
    }
    private var currentMonotonic: TimeInterval = 0
    private mutating func requestDisconnect(_ key: BluetoothConnection, effects: inout [EncounterEngineEffect]) {
        if closing.insert(key).inserted { effects.append(.transport(.disconnect(key))) }
    }
    private func finalize(_ original: EncounterReceipt, preserve: Bool, effects: inout [EncounterEngineEffect]) {
        if preserve || original.hasQualifyingAmbientEvidence || original.sessionFlag {
            var receipt = original; receipt.isFinalEvidence = true
            effects.append(.queue(nil, .update(receipt)))
        } else { effects.append(.queue(nil, .remove(original.id))) }
    }
}
