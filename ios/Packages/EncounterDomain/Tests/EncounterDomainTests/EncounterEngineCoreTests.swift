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
    private func completeCentral(_ core: inout EncounterEngineCore, token: TokenWindow? = nil) throws -> EncounterReceipt {
        let key = BluetoothConnection(peer: peer(), role: .central)
        _ = core.receive(.transport(.peerObserved(key.peer)), context: context(token: token))
        let read = try readID(core.receive(.transport(.connected(key)), context: context(token: token)))
        let frame = try ExchangeFrame(phase: .initialExchange, token: EncounterSamples.token(seed: 999), nonce: EncounterSamples.nonce(seed: 1))
        let write = core.receive(.transport(.frameRead(key.peer, read, frame.encoded())), context: context(token: token))
        let writeID = try XCTUnwrap(commands(write).compactMap { if case .write(_, let id, _) = $0 { id } else { nil } }.first)
        let (id, receipt) = try save(core.receive(.transport(.writeAcknowledged(key.peer, writeID)), context: context(token: token)))
        _ = core.receive(.queueResult(id, success: true), context: context(token: token))
        return receipt
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
