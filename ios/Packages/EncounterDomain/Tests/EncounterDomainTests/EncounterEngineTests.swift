import Foundation
import XCTest
import EncounterDomain
import EncounterDomainTestSupport

@MainActor
final class EncounterEngineTests: XCTestCase {
    private func evidence(_ phone: FakeEncounterPhone) async throws -> [EncounterReceipt] { try await phone.queue.pending() }
    private func startSingle(_ rig: PairedPhonesRig) async throws {
        // The second endpoint starts discovery last; dropping its observation leaves only first as central.
        await rig.link.dropNext(.observation)
        try await rig.start()
    }
    private func connectCount(_ commands: [BluetoothCommand]) -> Int {
        commands.filter { if case .connect = $0 { true } else { false } }.count
    }
    private func successCount(_ commands: [BluetoothCommand]) -> Int {
        commands.filter { if case .answerWrite(_, _, true) = $0 { true } else { false } }.count
    }

    func testHeldConnectionNeedsARealCheckpointAt120OnBothPhones() async throws {
        let rig = try await PairedPhonesRig.make()
        try await rig.start()
        let initialA = try await evidence(rig.first), initialB = try await evidence(rig.second)
        XCTAssertEqual(initialA.count, 2); XCTAssertEqual(initialB.count, 2)
        XCTAssertEqual(Set(initialA.map(\.exchangeNonce)), Set(initialB.map(\.exchangeNonce)))
        XCTAssertFalse(TestEncounterConfirmation.confirms(initialA, initialB))
        try await rig.advance(by: 119)
        let at119A = try await evidence(rig.first), at119B = try await evidence(rig.second)
        XCTAssertFalse(at119A.contains(where: \.hasQualifyingAmbientEvidence))
        XCTAssertFalse(at119B.contains(where: \.hasQualifyingAmbientEvidence))
        try await rig.advance(by: 1)
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertEqual(a.count, 2); XCTAssertEqual(b.count, 2)
        XCTAssertTrue(a.allSatisfy { $0.hasQualifyingAmbientEvidence && $0.observedDuration == 120 && $0.isFinalEvidence })
        XCTAssertTrue(b.allSatisfy { $0.hasQualifyingAmbientEvidence && $0.observedDuration == 120 && $0.isFinalEvidence })
        XCTAssertEqual(Set(a.map(\.id)), Set(initialA.map(\.id)))
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        XCTAssertFalse(TestEncounterConfirmation.confirms(a, []))
        let links = await rig.link.activeLinkCount; XCTAssertEqual(links, 0)
        try await rig.stop()
    }

    func testSecondExchangeJoinsBothFreshNoncesAndKeepsOriginalPairs() async throws {
        let rig = try await PairedPhonesRig.make(approach: .secondExchange)
        try await rig.start()
        let initialA = try await evidence(rig.first), initialB = try await evidence(rig.second)
        let links = await rig.link.activeLinkCount; XCTAssertEqual(links, 0)
        try await rig.advance(by: 119)
        let at119A = try await evidence(rig.first), at119B = try await evidence(rig.second)
        XCTAssertEqual(at119A, initialA); XCTAssertEqual(at119B, initialB)
        try await rig.advance(by: 1)
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertEqual(a.count, 4); XCTAssertEqual(b.count, 4)
        let joinedA = a.filter { $0.priorExchangeNonce != nil }, joinedB = b.filter { $0.priorExchangeNonce != nil }
        XCTAssertEqual(joinedA.count, 2); XCTAssertEqual(joinedB.count, 2)
        XCTAssertTrue(joinedA.allSatisfy { $0.hasQualifyingAmbientEvidence && $0.observedDuration == 120 && $0.isFinalEvidence })
        XCTAssertTrue(joinedB.allSatisfy { $0.hasQualifyingAmbientEvidence && $0.observedDuration == 120 && $0.isFinalEvidence })
        XCTAssertTrue(a.allSatisfy(\.isFinalEvidence)); XCTAssertTrue(b.allSatisfy(\.isFinalEvidence))
        XCTAssertTrue(joinedA.allSatisfy { second in initialA.contains { $0.exchangeNonce == second.priorExchangeNonce && $0.exchangeNonce != second.exchangeNonce } })
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        XCTAssertFalse(TestEncounterConfirmation.confirms(joinedA, joinedB))
        XCTAssertFalse(TestEncounterConfirmation.confirms(a, []))
        try await rig.stop()
    }

    func testEachPhoneMeasures120IndependentlyAndEarlyRefusalCanRetry() async throws {
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            let rig = try await PairedPhonesRig.make(approach: approach)
            try await rig.start()
            try await rig.advance(.first, by: 120)
            try await rig.advance(.second, by: 119)
            let earlyA = try await evidence(rig.first), earlyB = try await evidence(rig.second)
            XCTAssertFalse(earlyA.contains(where: \.hasQualifyingAmbientEvidence))
            XCTAssertFalse(earlyB.contains(where: \.hasQualifyingAmbientEvidence))
            try await rig.advance(.second, by: 1)
            let a = try await evidence(rig.first), b = try await evidence(rig.second)
            XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
            try await rig.advance(.first, by: 10)
            let finalA = try await evidence(rig.first), finalB = try await evidence(rig.second)
            XCTAssertEqual(finalA.filter(\.hasQualifyingAmbientEvidence).count, 2)
            XCTAssertEqual(finalB.filter(\.hasQualifyingAmbientEvidence).count, 2)
            try await rig.stop()
        }
    }

    func testLateCallbackInsideBoundQualifiesButAfterBoundDoesNot() async throws {
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            let late = try await PairedPhonesRig.make(approach: approach)
            try await late.start(); try await late.advance(by: 299)
            let a = try await evidence(late.first), b = try await evidence(late.second)
            XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
            XCTAssertTrue(a.filter(\.hasQualifyingAmbientEvidence).allSatisfy { $0.observedDuration == 299 })
            try await late.stop()
            let expired = try await PairedPhonesRig.make(approach: approach)
            try await expired.start(); try await expired.advance(by: 301)
            let expiredA = try await evidence(expired.first), expiredB = try await evidence(expired.second)
            XCTAssertTrue(expiredA.isEmpty); XCTAssertTrue(expiredB.isEmpty)
            XCTAssertFalse(TestEncounterConfirmation.confirms(expiredA, expiredB))
            let links = await expired.link.activeLinkCount; XCTAssertEqual(links, 0)
            try await expired.stop()
        }
    }

    func testShortBrokenContactsAreDiscardedAndNeverAccumulated() async throws {
        let rig = try await PairedPhonesRig.make()
        try await rig.start(); try await rig.advance(by: 60)
        await rig.link.breakLink(); try await rig.settle()
        let droppedA = try await evidence(rig.first), droppedB = try await evidence(rig.second)
        XCTAssertTrue(droppedA.isEmpty); XCTAssertTrue(droppedB.isEmpty)
        try await rig.advance(by: 11)
        await rig.first.transport.inject(.peerObserved(FakePhoneID.second.peerHandle))
        await rig.second.transport.inject(.peerObserved(FakePhoneID.first.peerHandle))
        try await rig.settle(); try await rig.advance(by: 119)
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertEqual(a.count, 2); XCTAssertFalse(a.contains(where: \.hasQualifyingAmbientEvidence))
        XCTAssertFalse(TestEncounterConfirmation.confirms(a, b))
        await rig.link.breakLink(); try await rig.settle()
        let finalA = try await evidence(rig.first); XCTAssertTrue(finalA.isEmpty)
        try await rig.stop()
    }

    func testOneSessionStillNeedsAmbientEvidenceAndFinalShortSessionReceiptSurvives() async throws {
        let rig = try await PairedPhonesRig.make(firstSession: true)
        try await startSingle(rig); try await rig.advance(by: 119)
        let initialA = try await evidence(rig.first), initialB = try await evidence(rig.second)
        XCTAssertTrue(initialA.allSatisfy(\.sessionFlag)); XCTAssertTrue(initialB.allSatisfy { !$0.sessionFlag })
        XCTAssertFalse(TestEncounterConfirmation.confirms(initialA, initialB))
        try await rig.advance(by: 1)
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
        let short = try await PairedPhonesRig.make(firstSession: true)
        try await startSingle(short); await short.link.breakLink(); try await short.settle()
        let retained = try await evidence(short.first), discarded = try await evidence(short.second)
        XCTAssertEqual(retained.count, 1); XCTAssertTrue(retained[0].isFinalEvidence)
        XCTAssertTrue(discarded.isEmpty)
        XCTAssertFalse(TestEncounterConfirmation.confirms(retained, discarded))
        try await short.stop()
    }

    func testStartingSessionDoesNotRetroactivelyChangeInitialFlag() async throws {
        let rig = try await PairedPhonesRig.make()
        try await startSingle(rig)
        await rig.first.session.set(true); await rig.second.session.set(true)
        try await rig.advance(by: 120)
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(a.allSatisfy { !$0.sessionFlag }); XCTAssertTrue(b.allSatisfy { !$0.sessionFlag })
        try await rig.stop()
    }

    func testRotationRetainsBothPairsForBothApproaches() async throws {
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            let rig = try await PairedPhonesRig.make(approach: approach, windowAge: 890)
            try await startSingle(rig)
            let originalA = try await evidence(rig.first), originalB = try await evidence(rig.second)
            try await rig.advance(by: 120)
            let a = try await evidence(rig.first), b = try await evidence(rig.second)
            XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
            XCTAssertEqual(a[0].start, originalA[0].start); XCTAssertEqual(b[0].start, originalB[0].start)
            let finalA = a.first(where: \.hasQualifyingAmbientEvidence)!
            let finalB = b.first(where: \.hasQualifyingAmbientEvidence)!
            let pairA = finalA.checkpoint ?? finalA.start, pairB = finalB.checkpoint ?? finalB.start
            XCTAssertNotEqual(pairA.ownToken, originalA[0].start.ownToken)
            XCTAssertNotEqual(pairB.ownToken, originalB[0].start.ownToken)
            XCTAssertEqual(pairA.ownToken, pairB.peerToken); XCTAssertEqual(pairA.peerToken, pairB.ownToken)
            try await rig.stop()
        }
    }

    func testMalformedOversizedAndUnknownVersionReadsAreRejected() async throws {
        let valid = try ExchangeFrame(phase: .initialExchange, token: EncounterSamples.token(), nonce: EncounterSamples.nonce()).encoded()
        var unknown = valid; unknown[0] = 99
        for bytes in [Data([1, 2]), Data(repeating: 0, count: 65), unknown] {
            let rig = try await PairedPhonesRig.make()
            await rig.link.delay([.frameRead]); try await startSingle(rig)
            let delivery = await rig.link.pendingDeliveries().first!
            guard case .frameRead(let peer, let id, _) = delivery.event else { return XCTFail("Expected read") }
            await rig.link.release(delivery.id, replacing: .frameRead(peer, id, bytes)); try await rig.settle()
            let a = try await evidence(rig.first), b = try await evidence(rig.second)
            XCTAssertTrue(a.isEmpty); XCTAssertTrue(b.isEmpty)
            try await rig.stop()
        }
    }

    func testMalformedOversizedUnknownVersionAndStaleNonceWritesAreRejected() async throws {
        for mode in 0..<4 {
            let rig = try await PairedPhonesRig.make()
            await rig.link.delay([.incomingWrite]); try await startSingle(rig)
            let delivery = await rig.link.pendingDeliveries().first!
            guard case .incomingWrite(let peer, let id, let data) = delivery.event else { return XCTFail("Expected write") }
            var bytes = data
            if mode == 0 { bytes = Data([1]) }
            if mode == 1 { bytes = Data(repeating: 0, count: 65) }
            if mode == 2 { bytes[0] = 88 }
            if mode == 3 {
                let frame = try ExchangeFrame.decode(data)
                bytes = try ExchangeFrame(phase: frame.phase, token: frame.token, nonce: EncounterSamples.nonce(seed: 999)).encoded()
            }
            await rig.link.release(delivery.id, replacing: .incomingWrite(peer, id, bytes)); try await rig.settle()
            let a = try await evidence(rig.first), b = try await evidence(rig.second)
            XCTAssertTrue(a.isEmpty); XCTAssertTrue(b.isEmpty)
            let commands = await rig.second.transport.commands(); XCTAssertEqual(successCount(commands), 0)
            try await rig.stop()
        }
    }

    func testNewReadInvalidatesPreviouslyServedNonce() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.delay([.incomingWrite]); try await startSingle(rig)
        let old = await rig.link.pendingDeliveries().first!
        await rig.second.transport.inject(.incomingRead(FakePhoneID.first.peerHandle, .init(999)))
        try await rig.settle()
        await rig.link.release(old.id); try await rig.settle()
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(a.isEmpty); XCTAssertTrue(b.isEmpty)
        try await rig.stop()
    }

    func testConnectTimeoutAndTenSecondDuplicateBackoff() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.setAutomaticConnections(false); try await rig.start()
        let peer = FakePhoneID.second.peerHandle
        for _ in 0..<8 { await rig.first.transport.inject(.peerObserved(peer)) }
        try await rig.settle()
        var commands = await rig.first.transport.commands(); XCTAssertEqual(connectCount(commands), 1)
        try await rig.advance(by: 10)
        commands = await rig.first.transport.commands()
        XCTAssertTrue(commands.contains(.disconnect(.init(peer: peer, role: .central))))
        await rig.first.transport.inject(.peerObserved(peer)); try await rig.settle()
        commands = await rig.first.transport.commands(); XCTAssertEqual(connectCount(commands), 1)
        try await rig.advance(by: 9)
        await rig.first.transport.inject(.peerObserved(peer)); try await rig.settle()
        commands = await rig.first.transport.commands(); XCTAssertEqual(connectCount(commands), 1)
        try await rig.advance(by: 1)
        await rig.first.transport.inject(.peerObserved(peer)); try await rig.settle()
        commands = await rig.first.transport.commands(); XCTAssertEqual(connectCount(commands), 2)
        try await rig.stop()
    }

    func testReadAndWriteOperationsTimeOutAtFiveSeconds() async throws {
        for kind in [FakeDeliveryKind.frameRead, .incomingWrite] {
            let rig = try await PairedPhonesRig.make()
            await rig.link.delay([kind]); try await startSingle(rig)
            try await rig.advance(by: 5)
            let a = try await evidence(rig.first), b = try await evidence(rig.second)
            XCTAssertTrue(a.isEmpty); XCTAssertTrue(b.isEmpty)
            let links = await rig.link.activeLinkCount; XCTAssertEqual(links, 0)
            await rig.link.releaseAll(); try await rig.settle()
            let late = try await evidence(rig.first); XCTAssertTrue(late.isEmpty)
            try await rig.stop()
        }
    }

    func testLostWriteResponseLeavesOnlyPeripheralReceiptAndCannotConfirm() async throws {
        let rig = try await PairedPhonesRig.make(firstSession: true, secondSession: true)
        await rig.link.withholdWriteAcknowledgements(to: .first)
        try await startSingle(rig)
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(a.isEmpty); XCTAssertEqual(b.count, 1)
        XCTAssertFalse(TestEncounterConfirmation.confirms(a, b))
        try await rig.advance(by: 5)
        let finalA = try await evidence(rig.first), finalB = try await evidence(rig.second)
        XCTAssertTrue(finalA.isEmpty); XCTAssertEqual(finalB.count, 1); XCTAssertTrue(finalB[0].isFinalEvidence)
        XCTAssertFalse(TestEncounterConfirmation.confirms(finalA, finalB))
        try await rig.stop()
    }

    func testPeripheralRespondsOnlyAfterDurableEnqueueAndFailsWhenQueueThrows() async throws {
        let queue = ControlledReceiptQueue()
        await queue.setWrites(held: true)
        let rig = try await PairedPhonesRig.make(secondQueue: queue)
        await rig.link.dropNext(.observation)
        await rig.first.engine.start(); await rig.second.engine.start()
        await queue.waitForWrite()
        let before = await rig.second.transport.commands()
        XCTAssertEqual(successCount(before), 0)
        let pendingBefore = try await queue.pending(); XCTAssertTrue(pendingBefore.isEmpty)
        await queue.setWrites(); try await rig.settle()
        let after = await rig.second.transport.commands()
        XCTAssertEqual(successCount(after), 1)
        let stored = try await queue.pending(); XCTAssertEqual(stored.count, 1)
        let central = try await evidence(rig.first); XCTAssertEqual(central.count, 1)
        try await rig.stop()
        let throwing = ControlledReceiptQueue(); await throwing.setWrites(failing: true)
        let failed = try await PairedPhonesRig.make(secondQueue: throwing)
        try await startSingle(failed)
        let failedCommands = await failed.second.transport.commands()
        XCTAssertEqual(successCount(failedCommands), 0)
        XCTAssertTrue(failedCommands.contains { if case .answerWrite(_, _, false) = $0 { true } else { false } })
        let failedA = try await evidence(failed.first), failedB = try await evidence(failed.second)
        XCTAssertTrue(failedA.isEmpty); XCTAssertTrue(failedB.isEmpty)
        try await failed.stop()
    }

    func testDisconnectBeforeCheckpointEndsHeldPresence() async throws {
        let rig = try await PairedPhonesRig.make()
        try await startSingle(rig); try await rig.advance(by: 119)
        await rig.link.breakLink(); try await rig.settle(); try await rig.advance(by: 1)
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(a.isEmpty); XCTAssertTrue(b.isEmpty)
        XCTAssertFalse(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testReorderedDisconnectBeforeAcknowledgementCannotCompleteCentralExchange() async throws {
        let rig = try await PairedPhonesRig.make(firstSession: true, secondSession: true)
        await rig.link.delay([.writeAcknowledgement, .disconnected]); try await startSingle(rig)
        await rig.link.breakLink()
        let held = await rig.link.pendingDeliveries()
        for delivery in held where FakeDeliveryKind(delivery.event) == .disconnected { await rig.link.release(delivery.id) }
        try await rig.settle()
        for delivery in held where FakeDeliveryKind(delivery.event) == .writeAcknowledgement { await rig.link.release(delivery.id) }
        try await rig.settle()
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(a.isEmpty); XCTAssertEqual(b.count, 1)
        XCTAssertFalse(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testUnsolicitedAndDuplicateAcknowledgementsAreIgnored() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.delay([.frameRead]); try await startSingle(rig)
        await rig.first.transport.inject(.writeAcknowledged(FakePhoneID.second.peerHandle, .init(777)))
        try await rig.settle()
        let before = try await evidence(rig.first); XCTAssertTrue(before.isEmpty)
        await rig.link.releaseAll(); try await rig.settle()
        let writes = await rig.first.transport.commands()
        guard let id = writes.compactMap({ command -> BluetoothRequestID? in if case .write(_, let id, _) = command { id } else { nil } }).first else {
            return XCTFail("Expected write")
        }
        await rig.first.transport.inject(.writeAcknowledged(FakePhoneID.second.peerHandle, id)); try await rig.settle()
        let after = try await evidence(rig.first); XCTAssertEqual(after.count, 1)
        try await rig.stop()
    }

    func testFourConnectionLimitIncludesPendingConnectsAndIncomingConnections() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.setAutomaticConnections(false); try await rig.start()
        for index in 10..<20 {
            let peer = PeerHandle(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
            await rig.first.transport.inject(.peerObserved(peer))
        }
        try await rig.settle()
        let commands = await rig.first.transport.commands(); XCTAssertEqual(connectCount(commands), 4)
        let incoming = BluetoothConnection(peer: PeerHandle(), role: .peripheral)
        await rig.first.transport.inject(.connected(incoming)); try await rig.settle()
        let after = await rig.first.transport.commands(); XCTAssertTrue(after.contains(.disconnect(incoming)))
        try await rig.stop()
    }

    func testNoTokenMeansNoConnectOrReadParticipationAndReplenishmentResumes() async throws {
        let rig = try await PairedPhonesRig.make()
        try await rig.first.tokens.clear(); try await rig.start()
        let peer = FakePhoneID.second.peerHandle
        await rig.first.transport.inject(.peerObserved(peer))
        await rig.first.transport.inject(.connected(.init(peer: peer, role: .peripheral)))
        await rig.first.transport.inject(.incomingRead(peer, .init(999))); try await rig.settle()
        let paused = await rig.first.transport.commands()
        XCTAssertEqual(connectCount(paused), 0); XCTAssertFalse(paused.contains(.startDiscovery))
        XCTAssertTrue(paused.contains(.answerRead(peer, .init(999), nil)))
        try await rig.first.tokens.save(EncounterSamples.batch())
        await rig.first.engine.refresh(); try await rig.settle()
        let resumed = await rig.first.transport.commands(); XCTAssertTrue(resumed.contains(.startDiscovery))
        XCTAssertEqual(connectCount(resumed), 1)
        try await rig.stop()
    }

    func testRestorationWithoutLiveAttemptDisconnectsAndNeverInfersPresence() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.setAutomaticConnections(false)
        let restored = BluetoothConnection(peer: PeerHandle(), role: .central)
        await rig.link.restore(on: .first, connections: [restored])
        try await rig.start()
        let commands = await rig.first.transport.commands(); XCTAssertTrue(commands.contains(.disconnect(restored)))
        XCTAssertFalse(commands.contains { if case .read = $0 { true } else { false } })
        let a = try await evidence(rig.first); XCTAssertTrue(a.isEmpty)
        try await rig.stop()
    }

    func testRestorationKeepsOnlyDemonstrablyLiveConnections() async throws {
        let rig = try await PairedPhonesRig.make()
        try await startSingle(rig)
        let live = BluetoothConnection(peer: FakePhoneID.second.peerHandle, role: .central)
        let unknown = BluetoothConnection(peer: PeerHandle(), role: .peripheral)
        await rig.link.restore(on: .first, connections: [live, unknown]); try await rig.settle()
        let commands = await rig.first.transport.commands()
        XCTAssertFalse(commands.contains(.disconnect(live))); XCTAssertTrue(commands.contains(.disconnect(unknown)))
        try await rig.advance(by: 120)
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testStopCancelsPendingConnectsAndResetClearsQueueAndUsesFreshNonces() async throws {
        let pending = try await PairedPhonesRig.make()
        await pending.link.setAutomaticConnections(false); try await pending.start(); try await pending.stop()
        let commands = await pending.first.transport.commands()
        XCTAssertTrue(commands.contains(.stopDiscovery))
        XCTAssertTrue(commands.contains(.disconnect(.init(peer: FakePhoneID.second.peerHandle, role: .central))))
        let rig = try await PairedPhonesRig.make(firstSession: true, secondSession: true)
        try await rig.start()
        let before = try await evidence(rig.first)
        await rig.first.engine.reset(); await rig.second.engine.reset(); try await rig.settle()
        let clearedA = try await evidence(rig.first), clearedB = try await evidence(rig.second)
        XCTAssertTrue(clearedA.isEmpty); XCTAssertTrue(clearedB.isEmpty)
        let links = await rig.link.activeLinkCount; XCTAssertEqual(links, 0)
        try await rig.start()
        let after = try await evidence(rig.first)
        XCTAssertTrue(Set(before.map(\.exchangeNonce)).isDisjoint(with: Set(after.map(\.exchangeNonce))))
        try await rig.stop()
        for _ in 0..<1000 {
            let firstWaits = await rig.first.clock.pendingWaitCount, secondWaits = await rig.second.clock.pendingWaitCount
            if firstWaits == 0 && secondWaits == 0 { break }
            await Task.yield()
        }
        let waitsA = await rig.first.clock.pendingWaitCount, waitsB = await rig.second.clock.pendingWaitCount
        XCTAssertEqual(waitsA, 0); XCTAssertEqual(waitsB, 0)
    }

    func testChangingApproachAffectsOnlyNewAttempts() async throws {
        let rig = try await PairedPhonesRig.make()
        try await startSingle(rig)
        await rig.first.engine.selectPresenceApproach(.secondExchange)
        await rig.second.engine.selectPresenceApproach(.secondExchange)
        try await rig.advance(by: 120)
        let held = try await evidence(rig.first); XCTAssertNotNil(held[0].checkpoint); XCTAssertNil(held[0].priorExchangeNonce)
        try await rig.advance(by: 10)
        await rig.first.transport.inject(.peerObserved(FakePhoneID.second.peerHandle)); try await rig.settle()
        try await rig.advance(by: 120)
        let after = try await evidence(rig.first)
        XCTAssertEqual(after.filter { $0.priorExchangeNonce != nil }.count, 1)
        try await rig.stop()
    }

    func testWallClockJumpDoesNotSupplyPresenceEvidence() async throws {
        let rig = try await PairedPhonesRig.make()
        try await startSingle(rig)
        await rig.first.clock.advance(by: 119, wallBy: 1800); await rig.second.clock.advance(by: 119, wallBy: 1800)
        await rig.first.engine.refresh(); await rig.second.engine.refresh(); try await rig.settle()
        let early = try await evidence(rig.first); XCTAssertFalse(early.contains(where: \.hasQualifyingAmbientEvidence))
        try await rig.advance(by: 1)
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testTimerAloneNeverSuppliesEvidence() async throws {
        let rig = try await PairedPhonesRig.make()
        try await startSingle(rig)
        await rig.link.delay([.incomingWrite])
        try await rig.advance(by: 120)
        let beforeA = try await evidence(rig.first), beforeB = try await evidence(rig.second)
        XCTAssertFalse(beforeA.contains(where: \.hasQualifyingAmbientEvidence))
        XCTAssertFalse(beforeB.contains(where: \.hasQualifyingAmbientEvidence))
        await rig.link.releaseAll(); try await rig.settle()
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testIncomingCallbackChecksDeadlineEvenWhenWakeWasSuspended() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.delay([.frameRead]); try await startSingle(rig)
        await rig.first.clock.advance(by: 5, deliverWakeUps: false)
        await rig.second.clock.advance(by: 5, deliverWakeUps: false)
        await rig.link.releaseAll(); try await rig.settle()
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(a.isEmpty); XCTAssertTrue(b.isEmpty)
        let commands = await rig.first.transport.commands()
        XCTAssertFalse(commands.contains { if case .write = $0 { true } else { false } })
        try await rig.stop()
    }

    func testSnapshotIsRefusedAfterTokenWindowExpires() async throws {
        let rig = try await PairedPhonesRig.make(windowAge: 899)
        await rig.link.delay([.incomingWrite]); try await startSingle(rig)
        await rig.first.clock.advance(by: 1, deliverWakeUps: false)
        await rig.second.clock.advance(by: 1, deliverWakeUps: false)
        await rig.link.releaseAll(); try await rig.settle()
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(a.isEmpty); XCTAssertTrue(b.isEmpty)
        let commands = await rig.second.transport.commands(); XCTAssertEqual(successCount(commands), 0)
        try await rig.stop()
    }

    func testReconnectRejectsMissingOrUnrelatedPriorNonce() async throws {
        for prior in [ExchangeNonce?.none, EncounterSamples.nonce(seed: 999)] {
            let rig = try await PairedPhonesRig.make(approach: .secondExchange)
            try await startSingle(rig)
            await rig.link.delay([.incomingWrite]); try await rig.advance(by: 120)
            let delivery = await rig.link.pendingDeliveries().first!
            guard case .incomingWrite(let peer, let id, let data) = delivery.event else { return XCTFail("Expected reconnect write") }
            let original = try ExchangeFrame.decode(data)
            let bytes = try ExchangeFrame(phase: .reconnectEvidence, token: original.token, nonce: original.nonce,
                                          priorNonce: prior).encoded()
            await rig.link.release(delivery.id, replacing: .incomingWrite(peer, id, bytes)); try await rig.settle()
            let a = try await evidence(rig.first), b = try await evidence(rig.second)
            XCTAssertFalse(a.contains(where: \.hasQualifyingAmbientEvidence))
            XCTAssertFalse(b.contains(where: \.hasQualifyingAmbientEvidence))
            XCTAssertFalse(TestEncounterConfirmation.confirms(a, b))
            try await rig.stop()
        }
    }

    func testDisconnectInProgressStillOccupiesAConnectionSlot() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.setAutomaticConnections(false); try await rig.start()
        let extra = (10..<14).map { index in
            PeerHandle(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
        }
        for peer in extra.prefix(3) { await rig.first.transport.inject(.peerObserved(peer)) }
        try await rig.settle()
        await rig.link.delay([.disconnected])
        // A deadline requests cancellation; the radio has not yet reported completion.
        await rig.first.clock.advance(by: 10, deliverWakeUps: false)
        await rig.first.engine.refresh(); try await rig.settle()
        await rig.first.transport.inject(.peerObserved(extra[3])); try await rig.settle()
        var commands = await rig.first.transport.commands(); XCTAssertEqual(connectCount(commands), 4)
        await rig.link.releaseAll(); try await rig.settle()
        await rig.first.transport.inject(.peerObserved(extra[3])); try await rig.settle()
        commands = await rig.first.transport.commands(); XCTAssertEqual(connectCount(commands), 5)
        await rig.link.delay([]); try await rig.stop()
    }

    func testStorageCompletionAfterAttemptBoundNeverAnswersSuccessOrRetainsProof() async throws {
        let queue = ControlledReceiptQueue()
        let rig = try await PairedPhonesRig.make(secondQueue: queue)
        try await startSingle(rig)
        await rig.link.delay([.incomingWrite]); try await rig.advance(by: 120)
        await queue.setWrites(held: true)
        await rig.link.releaseAll()
        await queue.waitForWrite(number: 2)
        await rig.first.clock.advance(by: 181, deliverWakeUps: false)
        await rig.second.clock.advance(by: 181, deliverWakeUps: false)
        await rig.first.engine.refresh()
        await queue.setWrites(); try await rig.settle()
        let a = try await evidence(rig.first), b = try await evidence(rig.second)
        XCTAssertTrue(a.isEmpty); XCTAssertTrue(b.isEmpty)
        let commands = await rig.second.transport.commands(); XCTAssertEqual(successCount(commands), 1)
        try await rig.stop()
    }

    func testDiagnosticsContainOnlyDigestsAndMonotonicDurations() async throws {
        let rig = try await PairedPhonesRig.make()
        let events = rig.first.engine.events
        let recording = Task { () -> [EncounterEngineEvent] in
            var result: [EncounterEngineEvent] = []
            for await event in events {
                result.append(event)
                if event == .discoveryChanged(false) { return result }
            }
            return result
        }
        try await rig.start(); try await rig.advance(by: 120); try await rig.stop()
        let recorded = await recording.value
        let receipts = try await evidence(rig.first)
        XCTAssertTrue(recorded.contains(.radioAvailability(.available)))
        XCTAssertTrue(recorded.contains(.discoveryChanged(true)))
        XCTAssertTrue(recorded.contains(.peerFirstObserved(FakePhoneID.second.peerHandle)))
        for receipt in receipts {
            XCTAssertTrue(recorded.contains(.exchangeCompleted(role: receipt.role, nonceDigest: receipt.exchangeNonce.diagnosticDigest)))
            XCTAssertTrue(recorded.contains(.evidenceReached(role: receipt.role, nonceDigest: receipt.exchangeNonce.diagnosticDigest,
                                                            observedDuration: 120)))
            let text = String(describing: recorded)
            XCTAssertFalse(text.contains(String(describing: receipt.exchangeNonce.bytes)))
            XCTAssertFalse(text.contains(String(describing: receipt.start.ownToken.bytes)))
            XCTAssertFalse(text.contains(String(describing: receipt.start.observedAt)))
        }
        XCTAssertEqual(recorded.filter { if case .attemptEnded(_, .evidenceReached) = $0 { true } else { false } }.count, 2)
    }
}
