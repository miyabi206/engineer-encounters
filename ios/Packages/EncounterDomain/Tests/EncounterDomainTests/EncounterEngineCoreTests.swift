import Foundation
import XCTest
import EncounterDomain
import EncounterDomainTestSupport

final class EncounterEngineCoreTests: XCTestCase {
    private func peer(_ index: Int = 1) -> PeerHandle {
        PeerHandle(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
    }
    private func context(_ seconds: TimeInterval = 0, token: TokenWindow? = nil) -> EncounterEngineContext {
        EncounterEngineContext(time: .init(monotonic: seconds, wall: EncounterSamples.observationTime.addingTimeInterval(seconds)),
                               tokenWindow: token ?? (try! EncounterSamples.batch(count: 1).windows[0]), sessionFlag: false)
    }
    private func commands(_ output: EncounterEngineOutput) -> [BluetoothCommand] {
        output.effects.compactMap { if case .transport(let command) = $0 { command } else { nil } }
    }
    private func ended(_ output: EncounterEngineOutput, _ reason: EncounterAttemptEndReason) -> Bool {
        output.effects.contains { if case .event(.attemptEnded(_, reason)) = $0 { true } else { false } }
    }
    private func started(approach: PresenceApproach = .heldConnection) -> EncounterEngineCore {
        let source = CoreTestNonceSource()
        var core = EncounterEngineCore(approach: approach, nonceSource: { source.next() })
        _ = core.receive(.start, context: context())
        _ = core.receive(.transport(.availabilityChanged(.available)), context: context())
        return core
    }
    private func readID(_ output: EncounterEngineOutput) throws -> BluetoothRequestID {
        try XCTUnwrap(commands(output).compactMap { if case .read(_, let id) = $0 { id } else { nil } }.first)
    }
    private func save(_ output: EncounterEngineOutput) throws -> (UInt64, EncounterReceipt) {
        try XCTUnwrap(output.effects.compactMap { effect -> (UInt64, EncounterReceipt)? in
            if case .queue(let id?, let write) = effect {
                switch write {
                case .enqueue(let receipt), .update(let receipt): return (id, receipt)
                default: break
                }
            }
            return nil
        }.first)
    }
    private func offered(_ output: EncounterEngineOutput) throws -> ExchangeFrame {
        let bytes = try XCTUnwrap(commands(output).compactMap {
            if case .answerRead(_, _, let snapshot?) = $0 { snapshot.frame } else { nil }
        }.first)
        return try ExchangeFrame.decode(bytes)
    }
    private func completePeripheral(_ core: inout EncounterEngineCore, peer peerHandle: PeerHandle? = nil,
                                    token: TokenWindow? = nil) throws -> EncounterReceipt {
        let key = BluetoothConnection(peer: peerHandle ?? peer(), role: .peripheral)
        _ = core.receive(.transport(.connected(key)), context: context(token: token))
        let frame = try offered(core.receive(.transport(.incomingRead(key.peer, .init(1))), context: context(token: token)))
        let write = try ExchangeFrame(phase: .initialExchange, token: EncounterSamples.token(seed: 999), nonce: frame.nonce)
        let (id, receipt) = try save(core.receive(.transport(.incomingWrite(key.peer, .init(2), write.encoded())), context: context(token: token)))
        _ = core.receive(.queueResult(id, success: true), context: context(token: token))
        return receipt
    }
    private func completeCentral(_ core: inout EncounterEngineCore, token: TokenWindow? = nil,
                                 seconds: TimeInterval = 0) throws -> EncounterReceipt {
        let key = BluetoothConnection(peer: peer(), role: .central)
        _ = core.receive(.transport(.peerObserved(key.peer)), context: context(seconds, token: token))
        let read = try readID(core.receive(.transport(.connected(key)), context: context(seconds, token: token)))
        let frame = try ExchangeFrame(phase: .initialExchange, token: EncounterSamples.token(seed: 999), nonce: EncounterSamples.nonce(seed: 1))
        let write = core.receive(.transport(.frameRead(key.peer, read, frame.encoded())), context: context(seconds, token: token))
        let writeID = try XCTUnwrap(commands(write).compactMap { if case .write(_, let id, _) = $0 { id } else { nil } }.first)
        let (id, receipt) = try save(core.receive(.transport(.writeAcknowledged(key.peer, writeID)), context: context(seconds, token: token)))
        _ = core.receive(.queueResult(id, success: true), context: context(seconds, token: token))
        return receipt
    }

    func testDefaultApproachUsesSecondExchange() throws {
        var core = EncounterEngineCore()
        _ = core.receive(.start, context: context())
        _ = core.receive(.transport(.availabilityChanged(.available)), context: context())
        let first = try completePeripheral(&core)
        let key = BluetoothConnection(peer: peer(), role: .peripheral)
        _ = core.receive(.transport(.disconnected(key)), context: context())
        _ = core.receive(.transport(.connected(key)), context: context(120))
        let frame = try offered(core.receive(.transport(.incomingRead(key.peer, .init(3))), context: context(120)))
        XCTAssertEqual(frame.phase, .reconnectEvidence)
        XCTAssertNotEqual(frame.nonce, first.exchangeNonce)
    }

    func testObservedPeersDropTheOldestAt256WithoutRenewingDuplicateObservations() {
        var core = EncounterEngineCore()
        for index in 1...256 { _ = core.receive(.transport(.peerObserved(peer(index))), context: context()) }
        let duplicate = core.receive(.transport(.peerObserved(peer(1))), context: context())
        XCTAssertFalse(duplicate.effects.contains { if case .event(.peerFirstObserved) = $0 { true } else { false } })
        _ = core.receive(.transport(.peerObserved(peer(257))), context: context())
        let retained = core.receive(.transport(.peerObserved(peer(2))), context: context())
        XCTAssertFalse(retained.effects.contains { if case .event(.peerFirstObserved) = $0 { true } else { false } })
        let dropped = core.receive(.transport(.peerObserved(peer(1))), context: context())
        XCTAssertTrue(dropped.effects.contains { if case .event(.peerFirstObserved(peer(1))) = $0 { true } else { false } })
    }

    // Freeze wall time to prove nonce retention follows only monotonic time.
    private func ledgerContext(_ seconds: TimeInterval) -> EncounterEngineContext {
        EncounterEngineContext(time: .init(monotonic: seconds, wall: EncounterSamples.observationTime),
                               tokenWindow: try! EncounterSamples.batch(count: 1).windows[0], sessionFlag: false)
    }
    private func offerToCentral(_ core: inout EncounterEngineCore, nonce: ExchangeNonce,
                                seconds: TimeInterval, peer index: Int) throws -> EncounterEngineOutput {
        let key = BluetoothConnection(peer: peer(index), role: .central)
        _ = core.receive(.transport(.peerObserved(key.peer)), context: ledgerContext(seconds))
        let read = try readID(core.receive(.transport(.connected(key)), context: ledgerContext(seconds)))
        let frame = try ExchangeFrame(phase: .initialExchange, token: EncounterSamples.token(seed: 999), nonce: nonce)
        return core.receive(.transport(.frameRead(key.peer, read, frame.encoded())), context: ledgerContext(seconds))
    }
    private func consume(_ core: inout EncounterEngineCore, index: Int, seconds: TimeInterval) throws {
        let key = BluetoothConnection(peer: peer(index), role: .central)
        let write = try offerToCentral(&core, nonce: EncounterSamples.nonce(seed: UInt64(index)), seconds: seconds, peer: index)
        let request = try XCTUnwrap(commands(write).compactMap { if case .write(_, let id, _) = $0 { id } else { nil } }.first)
        let (id, _) = try save(core.receive(.transport(.writeAcknowledged(key.peer, request)), context: ledgerContext(seconds)))
        _ = core.receive(.queueResult(id, success: true), context: ledgerContext(seconds))
        _ = core.receive(.transport(.disconnected(key)), context: ledgerContext(seconds))
    }

    func testConsumedNonceLedgerRejectsRetainedReplaysAndDropsOldestAbove4096() throws {
        var core = started()
        for index in 1...4097 { try consume(&core, index: index, seconds: Double(index) * 10) }
        let replay = try offerToCentral(&core, nonce: EncounterSamples.nonce(seed: 2), seconds: 41_000, peer: 5000)
        XCTAssertTrue(ended(replay, .invalidFrame))
        let oldest = try offerToCentral(&core, nonce: EncounterSamples.nonce(seed: 1), seconds: 41_000, peer: 5001)
        XCTAssertTrue(commands(oldest).contains { if case .write = $0 { true } else { false } })
    }

    func testConsumedNoncesExpireAt48HoursOfMonotonicTimeEvenAcrossStop() throws {
        var core = started()
        try consume(&core, index: 1, seconds: 0)
        _ = core.receive(.stop, context: ledgerContext(1))
        _ = core.receive(.start, context: ledgerContext(1))
        let retained = try offerToCentral(&core, nonce: EncounterSamples.nonce(seed: 1),
                                         seconds: EncounterProtocol.receiptLifetime - 1, peer: 2)
        XCTAssertTrue(ended(retained, .invalidFrame))
        let expired = try offerToCentral(&core, nonce: EncounterSamples.nonce(seed: 1),
                                        seconds: EncounterProtocol.receiptLifetime, peer: 3)
        XCTAssertTrue(commands(expired).contains { if case .write = $0 { true } else { false } })
    }

    func testReturningCentralIsRefusedUntilFiveSecondsAfterAnAttemptWithoutEvidence() throws {
        for completedExchange in [false, true] {
            var core = started()
            let key = BluetoothConnection(peer: peer(), role: .peripheral)
            if completedExchange { _ = try completePeripheral(&core) }
            else { _ = core.receive(.transport(.connected(key)), context: context()) }
            _ = core.receive(.transport(.disconnected(key)), context: context(1))
            let early = core.receive(.transport(.connected(key)), context: context(5.999))
            XCTAssertTrue(commands(early).contains(.disconnect(key)))
            let read = core.receive(.transport(.incomingRead(key.peer, .init(10))), context: context(5.999))
            XCTAssertTrue(commands(read).contains(.answerRead(key.peer, .init(10), nil)))
            _ = core.receive(.transport(.connected(key)), context: context(6))
            let fresh = try offered(core.receive(.transport(.incomingRead(key.peer, .init(11))), context: context(6)))
            XCTAssertEqual(fresh.phase, .initialExchange)
        }
    }

    func testPeripheralPauseTableDropsOldestAbove256() throws {
        var core = started()
        for index in 1...257 {
            let key = BluetoothConnection(peer: peer(index), role: .peripheral)
            _ = core.receive(.transport(.connected(key)), context: context())
            _ = core.receive(.transport(.disconnected(key)), context: context())
        }
        let retained = BluetoothConnection(peer: peer(2), role: .peripheral)
        XCTAssertTrue(commands(core.receive(.transport(.connected(retained)), context: context(1))).contains(.disconnect(retained)))
        let dropped = BluetoothConnection(peer: peer(1), role: .peripheral)
        _ = core.receive(.transport(.connected(dropped)), context: context(1))
        _ = try offered(core.receive(.transport(.incomingRead(dropped.peer, .init(1))), context: context(1)))
    }

    func testCentralThatReachedEvidenceMayReturnImmediately() throws {
        var core = started()
        let first = try completePeripheral(&core)
        let key = BluetoothConnection(peer: peer(), role: .peripheral)
        let frame = try offered(core.receive(.transport(.incomingRead(key.peer, .init(3))), context: context(120)))
        let write = try ExchangeFrame(phase: frame.phase, token: first.start.peerToken, nonce: frame.nonce)
        let (id, _) = try save(core.receive(.transport(.incomingWrite(key.peer, .init(4), write.encoded())), context: context(120)))
        XCTAssertTrue(ended(core.receive(.queueResult(id, success: true), context: context(120)), .evidenceReached))
        let connected = core.receive(.transport(.connected(key)), context: context(120))
        XCTAssertFalse(commands(connected).contains(.disconnect(key)))
        let fresh = try offered(core.receive(.transport(.incomingRead(key.peer, .init(5))), context: context(120)))
        XCTAssertEqual(fresh.phase, .initialExchange)
    }

    private func finishEvidence(_ core: inout EncounterEngineCore, first: EncounterReceipt,
                                approach: PresenceApproach, peer peerHandle: PeerHandle? = nil,
                                seconds: TimeInterval = 120, savedAt: TimeInterval = 123) throws {
        let key = BluetoothConnection(peer: peerHandle ?? peer(), role: first.role)
        let output: EncounterEngineOutput
        if key.role == .peripheral {
            if approach == .secondExchange {
                _ = core.receive(.transport(.connected(key)), context: ledgerContext(seconds))
            }
            let frame = try offered(core.receive(.transport(.incomingRead(key.peer, .init(30))), context: ledgerContext(seconds)))
            let write = try ExchangeFrame(phase: frame.phase, token: first.start.peerToken, nonce: frame.nonce,
                priorNonce: approach == .secondExchange ? first.exchangeNonce : nil)
            output = core.receive(.transport(.incomingWrite(key.peer, .init(31), write.encoded())), context: ledgerContext(seconds))
        } else {
            var ready = core.receive(.wakeUp, context: ledgerContext(seconds))
            if approach == .secondExchange {
                XCTAssertTrue(commands(ready).contains(.connect(key.peer)))
                ready = core.receive(.transport(.connected(key)), context: ledgerContext(seconds))
            }
            let read = try readID(ready)
            let frame = try ExchangeFrame(phase: approach == .heldConnection ? .heldConnectionCheckpoint : .reconnectEvidence,
                token: first.start.peerToken,
                nonce: approach == .heldConnection ? first.exchangeNonce : EncounterSamples.nonce(seed: 2))
            let write = core.receive(.transport(.frameRead(key.peer, read, frame.encoded())), context: ledgerContext(seconds))
            let request = try XCTUnwrap(commands(write).compactMap { if case .write(_, let id, _) = $0 { id } else { nil } }.first)
            output = core.receive(.transport(.writeAcknowledged(key.peer, request)), context: ledgerContext(seconds))
        }
        let (id, receipt) = try save(output)
        XCTAssertTrue(receipt.hasQualifyingAmbientEvidence)
        XCTAssertTrue(ended(core.receive(.queueResult(id, success: true), context: ledgerContext(savedAt)), .evidenceReached))
        _ = core.receive(.transport(.disconnected(key)), context: ledgerContext(savedAt))
    }

    private func reachEvidence(_ core: inout EncounterEngineCore, role: ExchangeRole,
                               approach: PresenceApproach) throws {
        let first = try role == .central ? completeCentral(&core) : completePeripheral(&core)
        if approach == .secondExchange {
            _ = core.receive(.transport(.disconnected(.init(peer: peer(), role: role))), context: ledgerContext(0))
        }
        try finishEvidence(&core, first: first, approach: approach)
    }

    func testCentralEvidencePausesNewOutgoingAttemptsUntilExactly15MinutesAfterEnd() throws {
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            var core = started(approach: approach)
            try reachEvidence(&core, role: .central, approach: approach)
            let early = core.receive(.transport(.peerObserved(peer())), context: ledgerContext(133))
            XCTAssertFalse(commands(early).contains(.connect(peer())))
            let pending = core.receive(.transport(.peerObserved(peer())), context: ledgerContext(1022))
            XCTAssertFalse(commands(pending).contains(.connect(peer())))
            XCTAssertEqual(pending.wakeUpDeadline, 1023)
            let expired = core.receive(.wakeUp, context: ledgerContext(1023))
            XCTAssertEqual(commands(expired), [.connect(peer())])
            XCTAssertGreaterThan(try XCTUnwrap(expired.wakeUpDeadline), 1023)
        }
    }

    func testPeripheralEvidencePausesOutgoingAttemptsToTheSameHandleUntilExactly15Minutes() throws {
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            var core = started(approach: approach)
            try reachEvidence(&core, role: .peripheral, approach: approach)
            XCTAssertFalse(commands(core.receive(.transport(.peerObserved(peer())), context: ledgerContext(133))).contains(.connect(peer())))
            let pending = core.receive(.transport(.peerObserved(peer())), context: ledgerContext(1022))
            XCTAssertFalse(commands(pending).contains(.connect(peer())))
            XCTAssertEqual(pending.wakeUpDeadline, 1023)
            XCTAssertEqual(commands(core.receive(.wakeUp, context: ledgerContext(1023))), [.connect(peer())])
        }
    }

    func testEvidencePauseExpiryDoesNotDialAStalePendingPeer() throws {
        var core = started()
        try reachEvidence(&core, role: .central, approach: .heldConnection)
        _ = core.receive(.transport(.peerObserved(peer())), context: ledgerContext(133))
        XCTAssertFalse(commands(core.receive(.wakeUp, context: ledgerContext(1023))).contains(.connect(peer())))
        XCTAssertEqual(commands(core.receive(.transport(.peerObserved(peer())), context: ledgerContext(1023))), [.connect(peer())])
    }

    func testResetClearsEvidencePauseForEitherRole() throws {
        for role in [ExchangeRole.central, .peripheral] {
            var core = started()
            try reachEvidence(&core, role: role, approach: .heldConnection)
            _ = core.receive(.reset, context: ledgerContext(124))
            _ = core.receive(.start, context: ledgerContext(125))
            XCTAssertEqual(commands(core.receive(.transport(.peerObserved(peer())), context: ledgerContext(125))), [.connect(peer())])
        }
    }

    func testStopThenStartKeepsEvidencePauseForEitherRole() throws {
        for role in [ExchangeRole.central, .peripheral] {
            var core = started()
            try reachEvidence(&core, role: role, approach: .heldConnection)
            _ = core.receive(.stop, context: ledgerContext(124))
            _ = core.receive(.start, context: ledgerContext(125))
            XCTAssertFalse(commands(core.receive(.transport(.peerObserved(peer())), context: ledgerContext(125))).contains(.connect(peer())))
            let pending = core.receive(.transport(.peerObserved(peer())), context: ledgerContext(1022))
            XCTAssertEqual(pending.wakeUpDeadline, 1023)
            XCTAssertEqual(commands(core.receive(.wakeUp, context: ledgerContext(1023))), [.connect(peer())])
        }
    }

    func testEvidencePauseTableDropsOldestAbove256() throws {
        var core = started(approach: .secondExchange)
        var first: [EncounterReceipt] = []
        for index in 1...257 {
            first.append(try completePeripheral(&core, peer: peer(index)))
            _ = core.receive(.transport(.disconnected(.init(peer: peer(index), role: .peripheral))), context: ledgerContext(0))
        }
        for index in 1...257 {
            try finishEvidence(&core, first: first[index - 1], approach: .secondExchange,
                               peer: peer(index), savedAt: 120)
        }
        for index in [2, 257] {
            XCTAssertFalse(commands(core.receive(.transport(.peerObserved(peer(index))), context: ledgerContext(121))).contains(.connect(peer(index))))
        }
        XCTAssertEqual(commands(core.receive(.transport(.peerObserved(peer(1))), context: ledgerContext(121))), [.connect(peer(1))])
    }

    func testExistingCentralAttemptCompletesDespitePeripheralEvidencePausingTheSameHandle() throws {
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            var core = started(approach: approach)
            let peripheral = try completePeripheral(&core)
            if approach == .secondExchange {
                _ = core.receive(.transport(.disconnected(.init(peer: peer(), role: .peripheral))), context: ledgerContext(0))
            }
            let central = try completeCentral(&core, seconds: 1)
            if approach == .secondExchange {
                _ = core.receive(.transport(.disconnected(.init(peer: peer(), role: .central))), context: ledgerContext(1))
            }
            try finishEvidence(&core, first: peripheral, approach: approach, savedAt: 120)
            try finishEvidence(&core, first: central, approach: approach, seconds: 121, savedAt: 121)
            XCTAssertFalse(commands(core.receive(.transport(.peerObserved(peer())), context: ledgerContext(131))).contains(.connect(peer())))
            let renewed = core.receive(.transport(.peerObserved(peer())), context: ledgerContext(1020))
            XCTAssertFalse(commands(renewed).contains(.connect(peer())))
            XCTAssertEqual(renewed.wakeUpDeadline, 1021)
            XCTAssertEqual(commands(core.receive(.wakeUp, context: ledgerContext(1021))), [.connect(peer())])
        }
    }

    func testEveryRetryableCentralEndRetriesOnceWithoutAnotherObservation() throws {
        for reason in [EncounterAttemptEndReason.connectTimeout, .operationTimeout, .failed, .invalidFrame, .disconnected, .storageFailure] {
            var core = started()
            let key = BluetoothConnection(peer: peer(), role: .central)
            let first = core.receive(.transport(.peerObserved(key.peer)), context: context())
            XCTAssertEqual(commands(first), [.connect(key.peer)])
            let output: EncounterEngineOutput
            let endTime: TimeInterval
            switch reason {
            case .connectTimeout:
                endTime = 10; output = core.receive(.wakeUp, context: context(endTime))
            case .disconnected:
                _ = try readID(core.receive(.transport(.connected(key)), context: context()))
                endTime = 0; output = core.receive(.transport(.disconnected(key)), context: context())
            default:
                let read = try readID(core.receive(.transport(.connected(key)), context: context()))
                endTime = reason == .operationTimeout ? 5 : 0
                switch reason {
                case .operationTimeout: output = core.receive(.wakeUp, context: context(endTime))
                case .failed: output = core.receive(.transport(.readFailed(key.peer, read)), context: context())
                case .invalidFrame: output = core.receive(.transport(.frameRead(key.peer, read, Data([0]))), context: context())
                default:
                    let frame = try ExchangeFrame(phase: .initialExchange, token: EncounterSamples.token(seed: 999), nonce: EncounterSamples.nonce())
                    let write = core.receive(.transport(.frameRead(key.peer, read, frame.encoded())), context: context())
                    let writeID = try XCTUnwrap(commands(write).compactMap { if case .write(_, let id, _) = $0 { id } else { nil } }.first)
                    let (saveID, _) = try save(core.receive(.transport(.writeAcknowledged(key.peer, writeID)), context: context()))
                    output = core.receive(.queueResult(saveID, success: false), context: context())
                }
            }
            XCTAssertTrue(ended(output, reason), "\(reason)")
            XCTAssertEqual(output.wakeUpDeadline, endTime + 10)
            let early = core.receive(.wakeUp, context: context(endTime + 9))
            XCTAssertFalse(commands(early).contains(.connect(key.peer)))
            let retry = core.receive(.wakeUp, context: context(endTime + 10))
            XCTAssertEqual(commands(retry), [.connect(key.peer)])
            _ = core.receive(.transport(.connectFailed(key.peer)), context: context(endTime + 10))
            let forgotten = core.receive(.wakeUp, context: context(endTime + 20))
            XCTAssertFalse(commands(forgotten).contains(.connect(key.peer)))
        }
    }

    func testObservationDuringBackoffIsRememberedAndRenewsOneRetry() {
        var core = started()
        _ = core.receive(.transport(.peerObserved(peer())), context: context())
        _ = core.receive(.transport(.connectFailed(peer())), context: context(1))
        let deferred = core.receive(.transport(.peerObserved(peer())), context: context(2))
        XCTAssertFalse(commands(deferred).contains(.connect(peer())))
        XCTAssertEqual(deferred.wakeUpDeadline, 11)
        XCTAssertEqual(commands(core.receive(.wakeUp, context: context(11))), [.connect(peer())])
        _ = core.receive(.transport(.connectFailed(peer())), context: context(12))
        XCTAssertEqual(commands(core.receive(.wakeUp, context: context(22))), [.connect(peer())])
        _ = core.receive(.transport(.connectFailed(peer())), context: context(23))
        XCTAssertFalse(commands(core.receive(.wakeUp, context: context(33))).contains(.connect(peer())))
    }

    func testFullPoolAndClosingPeerStartOnTheFirstFreeSlot() {
        var core = started()
        for index in 1...4 { _ = core.receive(.transport(.peerObserved(peer(index))), context: context()) }
        let full = core.receive(.transport(.peerObserved(peer(5))), context: context())
        XCTAssertTrue(commands(full).isEmpty)
        XCTAssertEqual(core.activeConnectionCount, 4)
        let closed = core.receive(.wakeUp, context: context(10))
        XCTAssertEqual(core.activeConnectionCount, 4)
        XCTAssertEqual(closed.wakeUpDeadline, 20)
        _ = core.receive(.transport(.peerObserved(peer(1))), context: context(19))
        let freed = core.receive(.transport(.disconnected(.init(peer: peer(1), role: .central))), context: context(19))
        XCTAssertTrue(commands(freed).contains(.connect(peer(5))))
        let retry = core.receive(.wakeUp, context: context(20))
        XCTAssertTrue(commands(retry).contains(.connect(peer(1))))
        XCTAssertLessThanOrEqual(core.activeConnectionCount, 4)
    }

    func testMissingDisconnectCallbacksExpireAndCannotWedgeThePool() {
        var core = started()
        for index in 1...5 { _ = core.receive(.transport(.peerObserved(peer(index))), context: context()) }
        _ = core.receive(.wakeUp, context: context(10))
        XCTAssertEqual(core.activeConnectionCount, 4)
        let freed = core.receive(.wakeUp, context: context(20))
        XCTAssertEqual(commands(freed), [.connect(peer(5)), .connect(peer(1)), .connect(peer(2)), .connect(peer(3))])
        XCTAssertEqual(core.activeConnectionCount, 4)
    }

    func testNineContinuouslyObservedPeersAreDialledInInsertionOrderBeforeRetries() {
        var core = started()
        let peers = [1, 2, 3, 4, 9, 8, 7, 6, 5].map { peer($0) }
        var dialled: [PeerHandle] = []
        // Foreground scans re-report all peers; missing teardown callbacks still release slots.
        for seconds in stride(from: 0.0, through: 60, by: 2) {
            for peer in peers {
                let output = core.receive(.transport(.peerObserved(peer)), context: context(seconds))
                dialled += commands(output).compactMap { if case .connect(let peer) = $0 { peer } else { nil } }
                XCTAssertLessThanOrEqual(core.activeConnectionCount, EncounterProtocol.activeConnectionLimit)
            }
        }
        XCTAssertEqual(Array(dialled.prefix(peers.count)), peers)
        XCTAssertEqual(Set(dialled), Set(peers))
        XCTAssertGreaterThan(dialled.count, peers.count)
    }

    func testSilentPendingPeerExpiresWhileNewObservationsKeepAnotherPeerEligible() throws {
        var core = started()
        for index in 1...4 { _ = try completePeripheral(&core, peer: peer(index)) }
        let silent = core.receive(.transport(.peerObserved(peer(5))), context: context())
        _ = core.receive(.transport(.peerObserved(peer(6))), context: context())
        XCTAssertTrue(commands(silent).isEmpty)
        XCTAssertEqual(silent.wakeUpDeadline, 30)
        _ = core.receive(.transport(.peerObserved(peer(6))), context: context(29))
        let expired = core.receive(.wakeUp, context: context(30))
        XCTAssertEqual(expired.wakeUpDeadline, 59)
        let freed = core.receive(.transport(.disconnected(.init(peer: peer(1), role: .peripheral))), context: context(31))
        XCTAssertEqual(commands(freed), [.connect(peer(6))])
        XCTAssertEqual(core.activeConnectionCount, 4)
        // A later real discovery can bring the forgotten peer back into range.
        _ = core.receive(.transport(.peerObserved(peer(5))), context: context(32))
        let rediscovered = core.receive(.transport(.disconnected(.init(peer: peer(2), role: .peripheral))), context: context(32))
        XCTAssertEqual(commands(rediscovered), [.connect(peer(5))])
    }

    func testAutomaticRetryUsesLastRealObservationInsteadOfTerminationTime() throws {
        for observedAgain in [false, true] {
            var core = started()
            _ = try completeCentral(&core)
            if observedAgain { _ = core.receive(.transport(.peerObserved(peer())), context: context(20)) }
            _ = core.receive(.transport(.disconnected(.init(peer: peer(), role: .central))), context: context(35))
            let retry = core.receive(.wakeUp, context: context(45))
            XCTAssertEqual(commands(retry).contains(.connect(peer())), observedAgain)
        }
    }

    func testConnectingAttemptIgnoresDisconnectedAndEndsOnConnectFailed() {
        var core = started()
        let key = BluetoothConnection(peer: peer(), role: .central)
        _ = core.receive(.transport(.peerObserved(key.peer)), context: context())
        let stray = core.receive(.transport(.disconnected(key)), context: context(1))
        XCTAssertTrue(stray.effects.isEmpty)
        XCTAssertEqual(core.activeConnectionCount, 1)
        XCTAssertEqual(stray.wakeUpDeadline, 10)
        let failed = core.receive(.transport(.connectFailed(key.peer)), context: context(2))
        XCTAssertTrue(ended(failed, .failed))
        XCTAssertEqual(core.activeConnectionCount, 0)
    }

    func testImmediateRestartIgnoresLateDisconnectedAfterANewConnectingAttemptBegins() throws {
        var core = started()
        let key = BluetoothConnection(peer: peer(), role: .central)
        _ = core.receive(.transport(.peerObserved(key.peer)), context: context())
        let stopped = core.receive(.stop, context: context(1))
        XCTAssertTrue(commands(stopped).contains(.disconnect(key)))
        _ = core.receive(.start, context: context(1))
        _ = core.receive(.transport(.peerObserved(key.peer)), context: context(1))
        // The cancelled link's teardown callback arrives after its slot grace period.
        let redial = core.receive(.wakeUp, context: context(11))
        XCTAssertEqual(commands(redial), [.connect(key.peer)])
        let late = core.receive(.transport(.disconnected(key)), context: context(11))
        XCTAssertTrue(late.effects.isEmpty)
        XCTAssertEqual(core.activeConnectionCount, 1)
        _ = try readID(core.receive(.transport(.connected(key)), context: context(11)))
    }

    func testRadioLossDropsClosingEntriesIncludingThoseCreatedDuringTeardown() {
        var core = started()
        for index in 1...4 { _ = core.receive(.transport(.peerObserved(peer(index))), context: context()) }
        _ = core.receive(.wakeUp, context: context(10))
        _ = core.receive(.transport(.availabilityChanged(.unavailable)), context: context(11))
        XCTAssertEqual(core.activeConnectionCount, 0)
        _ = core.receive(.transport(.peerObserved(peer(5))), context: context(11))
        let restored = core.receive(.transport(.availabilityChanged(.available)), context: context(12))
        XCTAssertTrue(commands(restored).contains(.connect(peer(5))))
        _ = core.receive(.transport(.availabilityChanged(.unauthorized)), context: context(12))
        XCTAssertEqual(core.activeConnectionCount, 0)
    }

    func testStopAndResetForgetPendingPeersAndDoNotBackOffTheNextStart() {
        for input in [EncounterEngineInput.stop, .reset] {
            var core = started()
            _ = core.receive(.transport(.peerObserved(peer())), context: context())
            _ = core.receive(input, context: context(1))
            _ = core.receive(.transport(.disconnected(.init(peer: peer(), role: .central))), context: context(1))
            let restart = core.receive(.start, context: context(2))
            XCTAssertFalse(commands(restart).contains(.connect(peer())))
            let observed = core.receive(.transport(.peerObserved(peer())), context: context(2))
            XCTAssertTrue(commands(observed).contains(.connect(peer())))
            _ = core.receive(.transport(.connectFailed(peer())), context: context(3))
            _ = core.receive(input, context: context(4))
            XCTAssertFalse(commands(core.receive(.start, context: context(5))).contains(.connect(peer())))
        }
    }

    func testPendingPeerMemoryIsBounded() {
        var core = EncounterEngineCore()
        _ = core.receive(.start, context: context())
        for index in 1...300 { _ = core.receive(.transport(.peerObserved(peer(index))), context: context()) }
        var output = core.receive(.transport(.availabilityChanged(.available)), context: context())
        var attempted: Set<PeerHandle> = []
        var connects = commands(output).compactMap { if case .connect(let peer) = $0 { peer } else { nil } }
        while let next = connects.popLast() {
            attempted.insert(next)
            output = core.receive(.transport(.connectFailed(next)), context: context())
            connects += commands(output).compactMap { if case .connect(let peer) = $0 { peer } else { nil } }
        }
        XCTAssertEqual(attempted.count, 256)
    }

    func testRepeatedIncomingReadsCannotExtendPreExchangeLifetime() throws {
        var core = started()
        let key = BluetoothConnection(peer: peer(), role: .peripheral)
        _ = core.receive(.transport(.connected(key)), context: context())
        for seconds in [4.0, 8, 12, 16, 19] {
            let output = core.receive(.transport(.incomingRead(key.peer, .init(UInt64(seconds)))), context: context(seconds))
            _ = try offered(output)
            XCTAssertLessThanOrEqual(try XCTUnwrap(output.wakeUpDeadline), 20)
        }
        let expired = core.receive(.transport(.incomingRead(key.peer, .init(20))), context: context(20))
        XCTAssertTrue(ended(expired, .operationTimeout))
        XCTAssertTrue(commands(expired).contains(.answerRead(key.peer, .init(20), nil)))
    }

    func testNewPeripheralLinkReplacesAStaleHeldAttemptWithoutDisconnectingTheNewLink() throws {
        var core = started()
        let receipt = try completePeripheral(&core)
        let key = BluetoothConnection(peer: peer(), role: .peripheral)
        let connected = core.receive(.transport(.connected(key)), context: context(60))
        XCTAssertTrue(ended(connected, .disconnected))
        XCTAssertFalse(commands(connected).contains(.disconnect(key)))
        XCTAssertTrue(connected.effects.contains { if case .queue(nil, .remove(receipt.id)) = $0 { true } else { false } })
        let frame = try offered(core.receive(.transport(.incomingRead(key.peer, .init(3))), context: context(60)))
        XCTAssertEqual(frame.phase, .initialExchange)
    }

    func testSecondExchangeReconnectRetainsTheFirstReceiptDespiteMissingDisconnect() throws {
        var core = started(approach: .secondExchange)
        let first = try completePeripheral(&core)
        let key = BluetoothConnection(peer: peer(), role: .peripheral)
        let connected = core.receive(.transport(.connected(key)), context: context(120))
        XCTAssertFalse(ended(connected, .disconnected))
        let frame = try offered(core.receive(.transport(.incomingRead(key.peer, .init(3))), context: context(120)))
        XCTAssertEqual(frame.phase, .reconnectEvidence)
        XCTAssertNotEqual(frame.nonce, first.exchangeNonce)
        let write = try ExchangeFrame(phase: frame.phase, token: first.start.peerToken, nonce: frame.nonce, priorNonce: first.exchangeNonce)
        let (_, receipt) = try save(core.receive(.transport(.incomingWrite(key.peer, .init(4), write.encoded())), context: context(120)))
        XCTAssertEqual(receipt.priorExchangeNonce, first.exchangeNonce)
        XCTAssertTrue(receipt.hasQualifyingAmbientEvidence)
    }

    func testPeripheralRefusesAt119AndAcceptsAt120OnItsOwnClock() throws {
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            var core = started(approach: approach)
            let first = try completePeripheral(&core)
            let key = BluetoothConnection(peer: peer(), role: .peripheral)
            for seconds in [119.0, 120] {
                if approach == .secondExchange { _ = core.receive(.transport(.connected(key)), context: context(seconds)) }
                let frame = try offered(core.receive(.transport(.incomingRead(key.peer, .init(3))), context: context(seconds)))
                let write = try ExchangeFrame(phase: frame.phase, token: first.start.peerToken, nonce: frame.nonce,
                                              priorNonce: approach == .secondExchange ? first.exchangeNonce : nil)
                let output = core.receive(.transport(.incomingWrite(key.peer, .init(4), write.encoded())), context: context(seconds))
                if seconds == 119 {
                    XCTAssertTrue(commands(output).contains(.answerWrite(key.peer, .init(4), success: false)))
                    XCTAssertFalse(ended(output, .invalidFrame))
                } else {
                    let (id, receipt) = try save(output)
                    XCTAssertEqual(receipt.observedDuration, 120)
                    let saved = core.receive(.queueResult(id, success: true), context: context(seconds))
                    XCTAssertTrue(commands(saved).contains(.answerWrite(key.peer, .init(4), success: true)))
                }
            }
        }
    }

    func testTokenRollDuringPeripheralCheckpointOrReconnectIsARetriableRefusal() throws {
        let old = try EncounterSamples.batch(start: EncounterSamples.observationTime.addingTimeInterval(-779), count: 2)
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            var core = started(approach: approach)
            let first = try completePeripheral(&core, token: old.windows[0])
            let key = BluetoothConnection(peer: peer(), role: .peripheral)
            if approach == .secondExchange { _ = core.receive(.transport(.connected(key)), context: context(120, token: old.windows[0])) }
            let frame = try offered(core.receive(.transport(.incomingRead(key.peer, .init(3))), context: context(120, token: old.windows[0])))
            let write = try ExchangeFrame(phase: frame.phase, token: first.start.peerToken, nonce: frame.nonce,
                                          priorNonce: approach == .secondExchange ? first.exchangeNonce : nil)
            let refused = core.receive(.transport(.incomingWrite(key.peer, .init(4), write.encoded())), context: context(121, token: old.windows[1]))
            XCTAssertTrue(commands(refused).contains(.answerWrite(key.peer, .init(4), success: false)))
            XCTAssertFalse(ended(refused, .invalidFrame))
            let fresh = try offered(core.receive(.transport(.incomingRead(key.peer, .init(5))), context: context(121, token: old.windows[1])))
            let retry = try ExchangeFrame(phase: fresh.phase, token: first.start.peerToken, nonce: fresh.nonce,
                                          priorNonce: approach == .secondExchange ? first.exchangeNonce : nil)
            let (_, receipt) = try save(core.receive(.transport(.incomingWrite(key.peer, .init(6), retry.encoded())), context: context(121, token: old.windows[1])))
            XCTAssertEqual((receipt.checkpoint ?? receipt.start).ownToken, old.windows[1].token)
            XCTAssertTrue(receipt.hasQualifyingAmbientEvidence)
        }
    }

    func testCentralRestartsReadBeforeWritingWhenOwnWindowRolls() throws {
        let old = try EncounterSamples.batch(start: EncounterSamples.observationTime.addingTimeInterval(-779), count: 2)
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            var core = started(approach: approach)
            let first = try completeCentral(&core, token: old.windows[0])
            let key = BluetoothConnection(peer: peer(), role: .central)
            if approach == .secondExchange {
                _ = core.receive(.transport(.disconnected(key)), context: context(token: old.windows[0]))
            }
            var output = core.receive(.wakeUp, context: context(120, token: old.windows[0]))
            if approach == .secondExchange { output = core.receive(.transport(.connected(key)), context: context(120, token: old.windows[0])) }
            let read = try readID(output)
            let frame = try ExchangeFrame(phase: approach == .heldConnection ? .heldConnectionCheckpoint : .reconnectEvidence,
                                          token: EncounterSamples.token(seed: 999),
                                          nonce: approach == .heldConnection ? first.exchangeNonce : EncounterSamples.nonce(seed: 2))
            let restarted = core.receive(.transport(.frameRead(key.peer, read, frame.encoded())), context: context(121, token: old.windows[1]))
            let nextRead = try readID(restarted)
            XCTAssertFalse(commands(restarted).contains { if case .write = $0 { true } else { false } })
            let write = core.receive(.transport(.frameRead(key.peer, nextRead, frame.encoded())), context: context(121, token: old.windows[1]))
            let data = try XCTUnwrap(commands(write).compactMap { if case .write(_, _, let data) = $0 { data } else { nil } }.first)
            XCTAssertEqual(try ExchangeFrame.decode(data).token, old.windows[1].token)
        }
    }

    private func prepareStep(_ core: inout EncounterEngineCore, role: ExchangeRole, approach: PresenceApproach,
                             first: EncounterReceipt?, seconds: TimeInterval, token: TokenWindow) throws -> EncounterEngineOutput {
        let key = BluetoothConnection(peer: peer(), role: role)
        if role == .peripheral {
            if first == nil || approach == .secondExchange {
                _ = core.receive(.transport(.connected(key)), context: context(seconds, token: token))
            }
            let frame = try offered(core.receive(.transport(.incomingRead(key.peer, .init(30))), context: context(seconds, token: token)))
            let write = try ExchangeFrame(phase: frame.phase, token: EncounterSamples.token(seed: 999), nonce: frame.nonce,
                priorNonce: frame.phase == .reconnectEvidence ? first?.exchangeNonce : nil)
            return core.receive(.transport(.incomingWrite(key.peer, .init(31), write.encoded())), context: context(seconds, token: token))
        }
        var output: EncounterEngineOutput
        if first == nil {
            _ = core.receive(.transport(.peerObserved(key.peer)), context: context(seconds, token: token))
            output = core.receive(.transport(.connected(key)), context: context(seconds, token: token))
        } else {
            if approach == .secondExchange { _ = core.receive(.transport(.disconnected(key)), context: context(token: token)) }
            output = core.receive(.wakeUp, context: context(seconds, token: token))
            if approach == .secondExchange { output = core.receive(.transport(.connected(key)), context: context(seconds, token: token)) }
        }
        let read = try readID(output)
        let phase: ExchangePhase = first == nil ? .initialExchange :
            (approach == .heldConnection ? .heldConnectionCheckpoint : .reconnectEvidence)
        let frame = try ExchangeFrame(phase: phase, token: EncounterSamples.token(seed: 999),
            nonce: phase == .heldConnectionCheckpoint ? first!.exchangeNonce : EncounterSamples.nonce(seed: 50))
        return core.receive(.transport(.frameRead(key.peer, read, frame.encoded())), context: context(seconds, token: token))
    }

    func testCentralRechecksOwnWindowAtAcknowledgementAndRetriesOnlyPresenceSteps() throws {
        for initial in [true, false] {
            for approach in [PresenceApproach.heldConnection, .secondExchange] {
                let seconds = initial ? 0.0 : 120
                let batch = try EncounterSamples.batch(start: EncounterSamples.observationTime.addingTimeInterval(seconds - 899), count: 2)
                var core = started(approach: approach)
                let first = initial ? nil : try completeCentral(&core, token: batch.windows[0])
                let write = try prepareStep(&core, role: .central, approach: approach, first: first, seconds: seconds, token: batch.windows[0])
                let request = try XCTUnwrap(commands(write).compactMap { if case .write(_, let id, _) = $0 { id } else { nil } }.first)
                let refused = core.receive(.transport(.writeAcknowledged(peer(), request)), context: context(seconds + 1, token: batch.windows[1]))
                XCTAssertFalse(refused.effects.contains { if case .queue = $0 { true } else { false } })
                XCTAssertEqual(ended(refused, .invalidFrame), initial)
                if !initial {
                    var retry = core.receive(.wakeUp, context: context(seconds + 11, token: batch.windows[1]))
                    if approach == .secondExchange {
                        XCTAssertTrue(commands(retry).contains(.connect(peer())))
                        retry = core.receive(.transport(.connected(.init(peer: peer(), role: .central))), context: context(seconds + 11, token: batch.windows[1]))
                    }
                    _ = try readID(retry)
                }
            }
        }
    }

    func testSaveCompletionRechecksOwnWindowForBothRolesAndRestoresRetriablePresenceSteps() throws {
        for initial in [true, false] {
            for approach in [PresenceApproach.heldConnection, .secondExchange] {
                for role in [ExchangeRole.central, .peripheral] {
                    let seconds = initial ? 0.0 : 120
                    let batch = try EncounterSamples.batch(start: EncounterSamples.observationTime.addingTimeInterval(seconds - 899), count: 2)
                    var core = started(approach: approach)
                    let first: EncounterReceipt?
                    if initial { first = nil }
                    else if role == .central { first = try completeCentral(&core, token: batch.windows[0]) }
                    else { first = try completePeripheral(&core, token: batch.windows[0]) }
                    var output = try prepareStep(&core, role: role, approach: approach, first: first, seconds: seconds, token: batch.windows[0])
                    if role == .central {
                        let request = try XCTUnwrap(commands(output).compactMap { if case .write(_, let id, _) = $0 { id } else { nil } }.first)
                        output = core.receive(.transport(.writeAcknowledged(peer(), request)), context: context(seconds, token: batch.windows[0]))
                    }
                    let (id, receipt) = try save(output)
                    let refused = core.receive(.queueResult(id, success: true), context: context(seconds + 1, token: batch.windows[1]))
                    XCTAssertEqual(ended(refused, .invalidFrame), initial)
                    XCTAssertFalse(refused.effects.contains {
                        if case .event(.exchangeCompleted) = $0 { return true }
                        if case .event(.evidenceReached) = $0 { return true }
                        return false
                    })
                    if role == .peripheral { XCTAssertTrue(commands(refused).contains(.answerWrite(peer(), .init(31), success: false))) }
                    if !initial && approach == .heldConnection {
                        XCTAssertTrue(refused.effects.contains { if case .queue(nil, .update(first!)) = $0 { true } else { false } })
                    } else {
                        XCTAssertTrue(refused.effects.contains { if case .queue(nil, .remove(receipt.id)) = $0 { true } else { false } })
                    }
                    if !initial && role == .peripheral {
                        let fresh = try offered(core.receive(.transport(.incomingRead(peer(), .init(32))), context: context(seconds + 1, token: batch.windows[1])))
                        XCTAssertEqual(fresh.token, batch.windows[1].token)
                        XCTAssertEqual(fresh.phase, approach == .heldConnection ? .heldConnectionCheckpoint : .reconnectEvidence)
                    }
                }
            }
        }
    }
}

private final class CoreTestNonceSource: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 100
    func next() -> ExchangeNonce {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        return EncounterSamples.nonce(seed: sequence)
    }
}
