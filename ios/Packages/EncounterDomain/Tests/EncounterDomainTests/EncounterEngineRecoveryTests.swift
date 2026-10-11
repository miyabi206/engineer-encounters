import Foundation
import XCTest
import EncounterDomain
import EncounterDomainTestSupport

@MainActor
final class EncounterEngineRecoveryTests: XCTestCase {
    private func startSingle(_ rig: PairedPhonesRig) async throws {
        await rig.link.setObservations(to: .second, enabled: false)
        try await rig.start()
    }
    private func connectCount(_ commands: [BluetoothCommand]) -> Int {
        commands.filter { if case .connect = $0 { true } else { false } }.count
    }
    private func successCount(_ commands: [BluetoothCommand]) -> Int {
        commands.filter { if case .answerWrite(_, _, true) = $0 { true } else { false } }.count
    }
    private func receipts(_ phone: FakeEncounterPhone) async throws -> [EncounterReceipt] { try await phone.queue.pending() }

    func testClockAloneDrivesCheckpointAndReconnectWithSilentPeripheralDisconnects() async throws {
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            let rig = try await PairedPhonesRig.make(approach: approach)
            await rig.link.setSilentPeripheralDisconnects()
            try await startSingle(rig)
            try await rig.advance(by: 119, refreshing: false)
            let earlyA = try await receipts(rig.first), earlyB = try await receipts(rig.second)
            XCTAssertFalse(TestEncounterConfirmation.confirms(earlyA, earlyB))
            try await rig.advance(by: 1, refreshing: false)
            let a = try await receipts(rig.first), b = try await receipts(rig.second)
            XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
            XCTAssertTrue(a.filter(\.hasQualifyingAmbientEvidence).allSatisfy { $0.observedDuration == 120 })
            let links = await rig.link.activeLinkCount; XCTAssertEqual(links, 0)
            try await rig.stop()
        }
    }

    func testSilentPeripheralCannotEvictCentralAndStaleHeldAttemptIsReplaced() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.setSilentPeripheralDisconnects()
        try await startSingle(rig)
        let initial = try await receipts(rig.second)
        await rig.second.transport.execute(.disconnect(.init(peer: FakePhoneID.first.peerHandle, role: .peripheral)))
        let links = await rig.link.activeLinkCount; XCTAssertEqual(links, 1)
        try await rig.advance(by: 60, refreshing: false)
        // A fresh foreground scan keeps this still-nearby peer eligible for one retry.
        await rig.first.transport.inject(.peerObserved(FakePhoneID.second.peerHandle)); try await rig.settle()
        await rig.link.breakLink(central: .first); try await rig.settle()
        let stale = try await receipts(rig.second); XCTAssertEqual(stale, initial)
        try await rig.advance(by: 10, refreshing: false)
        let newA = try await receipts(rig.first), newB = try await receipts(rig.second)
        XCTAssertEqual(newA.count, 1); XCTAssertEqual(newB.count, 1)
        XCTAssertNotEqual(newB.first?.id, initial.first?.id)
        XCTAssertFalse(TestEncounterConfirmation.confirms(newA, newB))
        try await rig.advance(by: 119, refreshing: false)
        let earlyA = try await receipts(rig.first), earlyB = try await receipts(rig.second)
        XCTAssertFalse(TestEncounterConfirmation.confirms(earlyA, earlyB))
        try await rig.advance(by: 1, refreshing: false)
        let a = try await receipts(rig.first), b = try await receipts(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testStopAndRestartWithinTenSecondsBeginsAFreshWorkingExchange() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.setSilentPeripheralDisconnects()
        try await rig.start()
        let initial = try await receipts(rig.first)
        try await rig.advance(by: 1, refreshing: false); try await rig.stop()
        try await rig.advance(by: 1, refreshing: false); try await rig.start()
        let restarted = try await receipts(rig.first)
        XCTAssertEqual(restarted.count, 2)
        XCTAssertTrue(Set(initial.map(\.exchangeNonce)).isDisjoint(with: Set(restarted.map(\.exchangeNonce))))
        try await rig.advance(by: 120, refreshing: false)
        let a = try await receipts(rig.first), b = try await receipts(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testDroppedConnectionFailureRetriesOnceUsingOnlyTheRuntimeWakeUp() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.setAutomaticConnections(false)
        try await startSingle(rig)
        try await rig.advance(by: 10, refreshing: false)
        var commands = await rig.first.transport.commands(); XCTAssertEqual(connectCount(commands), 1)
        try await rig.advance(by: 10, refreshing: false)
        commands = await rig.first.transport.commands(); XCTAssertEqual(connectCount(commands), 2)
        try await rig.advance(by: 10, refreshing: false)
        try await rig.advance(by: 10, refreshing: false)
        commands = await rig.first.transport.commands(); XCTAssertEqual(connectCount(commands), 2)
        try await rig.stop()
    }

    func testSecondExchangeNeverJoinsUnrelatedShortContacts() async throws {
        let rig = try await PairedPhonesRig.make(approach: .secondExchange)
        await rig.link.setSilentPeripheralDisconnects()
        try await startSingle(rig)
        let first = try await receipts(rig.first)
        try await rig.advance(by: 60, refreshing: false)
        // Reusing a provisional handle after a peer's process loss supplies no original nonce.
        await rig.first.engine.stop(); await rig.first.engine.start(); try await rig.settle()
        let unrelatedA = try await receipts(rig.first), unrelatedB = try await receipts(rig.second)
        XCTAssertFalse(TestEncounterConfirmation.confirms(unrelatedA, unrelatedB))
        XCTAssertFalse(unrelatedA.contains(where: \.hasQualifyingAmbientEvidence))
        XCTAssertFalse(unrelatedB.contains(where: \.hasQualifyingAmbientEvidence))
        XCTAssertFalse(first.contains { receipt in unrelatedA.contains { $0.priorExchangeNonce == receipt.exchangeNonce } })
        // The resulting phase mismatch must fail cleanly; a later fresh attempt can work.
        try await rig.stop()
        try await rig.advance(by: 1, refreshing: false); try await rig.start()
        try await rig.advance(by: 120, refreshing: false)
        let a = try await receipts(rig.first), b = try await receipts(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testPeripheralCheckpointAt119IsRefusedAndAt120IsAccepted() async throws {
        let rig = try await PairedPhonesRig.make()
        try await startSingle(rig)
        await rig.link.delay([.incomingWrite])
        await rig.first.clock.advance(by: 120, deliverWakeUps: false)
        await rig.second.clock.advance(by: 119, deliverWakeUps: false)
        await rig.first.clock.advance(by: 0); await rig.second.clock.advance(by: 0)
        try await rig.settle()
        let deliveries = await rig.link.pendingDeliveries()
        let firstWrite = try XCTUnwrap(deliveries.first)
        await rig.link.release(firstWrite.id); try await rig.settle()
        var commands = await rig.second.transport.commands()
        XCTAssertEqual(successCount(commands), 1)
        XCTAssertTrue(commands.contains { if case .answerWrite(_, _, false) = $0 { true } else { false } })
        let early = try await receipts(rig.second); XCTAssertFalse(early.contains(where: \.hasQualifyingAmbientEvidence))
        await rig.link.delay([])
        await rig.second.clock.advance(by: 1)
        await rig.first.clock.advance(by: 10)
        try await rig.settle()
        commands = await rig.second.transport.commands(); XCTAssertEqual(successCount(commands), 2)
        let a = try await receipts(rig.first), b = try await receipts(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        XCTAssertEqual(b.first?.observedDuration, 120)
        try await rig.stop()
    }

    func testCheckpointQueueFailureNeverAnswersSuccessAndFreshAttemptCanRecover() async throws {
        let queue = ControlledReceiptQueue()
        let rig = try await PairedPhonesRig.make(secondQueue: queue)
        try await startSingle(rig)
        await queue.setWrites(failing: true)
        try await rig.advance(by: 120, refreshing: false)
        let commands = await rig.second.transport.commands(); XCTAssertEqual(successCount(commands), 1)
        XCTAssertTrue(commands.contains { if case .answerWrite(_, _, false) = $0 { true } else { false } })
        let failedA = try await receipts(rig.first), failedB = try await receipts(rig.second)
        XCTAssertFalse(TestEncounterConfirmation.confirms(failedA, failedB))
        XCTAssertFalse(failedB.contains(where: \.hasQualifyingAmbientEvidence))
        await queue.setWrites()
        await rig.first.transport.inject(.peerObserved(FakePhoneID.second.peerHandle)); try await rig.settle()
        try await rig.advance(by: 10, refreshing: false)
        try await rig.advance(by: 120, refreshing: false)
        let a = try await receipts(rig.first), b = try await receipts(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testCentralEnqueueFailureLeavesOnlyPeripheralCandidateAndRetriesAutomatically() async throws {
        let queue = ControlledReceiptQueue(); await queue.setWrites(failing: true)
        let rig = try await PairedPhonesRig.make(secondSession: true, firstQueue: queue)
        await rig.link.setSilentPeripheralDisconnects()
        try await startSingle(rig)
        let failedA = try await receipts(rig.first), candidate = try await receipts(rig.second)
        XCTAssertTrue(failedA.isEmpty); XCTAssertEqual(candidate.count, 1)
        XCTAssertFalse(TestEncounterConfirmation.confirms(failedA, candidate))
        await queue.setWrites()
        try await rig.advance(by: 10, refreshing: false)
        let fresh = try await receipts(rig.first); XCTAssertEqual(fresh.count, 1)
        XCTAssertNotEqual(fresh.first?.exchangeNonce, candidate.first?.exchangeNonce)
        try await rig.advance(by: 120, refreshing: false)
        let a = try await receipts(rig.first), b = try await receipts(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testTokenRollBetweenCheckpointReadAndWriteRecoversWithinTheSameAttempt() async throws {
        for approach in [PresenceApproach.heldConnection, .secondExchange] {
            let rig = try await PairedPhonesRig.make(approach: approach, windowAge: 779)
            await rig.link.setSilentPeripheralDisconnects()
            try await startSingle(rig)
            let initial = try await receipts(rig.first)
            await rig.link.delay([.incomingWrite])
            try await rig.advance(by: 120, refreshing: false)
            try await rig.advance(by: 1, refreshing: false)
            await rig.link.delay([]); await rig.link.releaseAll(); try await rig.settle()
            let refused = await rig.second.transport.commands(); XCTAssertEqual(successCount(refused), 1)
            try await rig.advance(by: 10, refreshing: false)
            let a = try await receipts(rig.first), b = try await receipts(rig.second)
            XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
            XCTAssertEqual(a.first?.id, initial.first?.id)
            XCTAssertTrue(a.filter(\.hasQualifyingAmbientEvidence).allSatisfy { $0.observedDuration == 131 })
            try await rig.stop()
        }
    }

    func testTokenGapMidAttemptDiscardsPresenceAndReplenishmentStartsFresh() async throws {
        let rig = try await PairedPhonesRig.make(windowAge: 890)
        let stored = try await rig.first.tokens.load()
        let batch = try XCTUnwrap(stored)
        try await rig.first.tokens.save(TokenBatch(windows: [batch.windows[0], batch.windows[2]]))
        try await startSingle(rig)
        let initial = try await receipts(rig.first)
        try await rig.advance(by: 10, refreshing: false)
        let gapA = try await receipts(rig.first), gapB = try await receipts(rig.second)
        XCTAssertTrue(gapA.isEmpty); XCTAssertTrue(gapB.isEmpty)
        let paused = await rig.first.transport.commands(); XCTAssertTrue(paused.contains(.stopDiscovery))
        try await rig.advance(by: 900, refreshing: false)
        let fresh = try await receipts(rig.first)
        XCTAssertEqual(fresh.count, 1); XCTAssertNotEqual(fresh.first?.id, initial.first?.id)
        try await rig.advance(by: 120, refreshing: false)
        let a = try await receipts(rig.first), b = try await receipts(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testRadioLossMidAttemptDiscardsPresenceAndRecoversAfterAvailabilityReturns() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.link.setSilentPeripheralDisconnects()
        try await startSingle(rig)
        let initial = try await receipts(rig.first)
        try await rig.advance(by: 60, refreshing: false)
        await rig.first.transport.inject(.availabilityChanged(.unavailable)); try await rig.settle()
        let lost = try await receipts(rig.first); XCTAssertTrue(lost.isEmpty)
        await rig.first.transport.inject(.availabilityChanged(.available)); try await rig.settle()
        try await rig.advance(by: 10, refreshing: false)
        let fresh = try await receipts(rig.first)
        XCTAssertEqual(fresh.count, 1); XCTAssertNotEqual(fresh.first?.id, initial.first?.id)
        try await rig.advance(by: 120, refreshing: false)
        let a = try await receipts(rig.first), b = try await receipts(rig.second)
        XCTAssertTrue(TestEncounterConfirmation.confirms(a, b))
        try await rig.stop()
    }

    func testFirstStartSweepsProcessLossReceiptsBeforeEnablingParticipation() async throws {
        let queue = ControlledReceiptQueue()
        let unfinished = EncounterSamples.receipt(1)
        var session = EncounterSamples.receipt(2); session.sessionFlag = true
        var checkpoint = EncounterSamples.receipt(3); checkpoint.checkpoint = checkpoint.start; checkpoint.observedDuration = 120
        let joined = EncounterReceipt(id: EncounterSamples.receipt(4).id, role: .central, exchangeNonce: EncounterSamples.nonce(seed: 4),
                                      priorExchangeNonce: EncounterSamples.nonce(seed: 3), start: checkpoint.start, observedDuration: 120)
        var final = EncounterSamples.receipt(5); final.isFinalEvidence = true
        var early = EncounterSamples.receipt(6); early.checkpoint = early.start; early.observedDuration = 119
        for receipt in [unfinished, session, checkpoint, joined, final, early] { try await queue.enqueue(receipt) }
        await queue.setWrites(held: true)
        let rig = try await PairedPhonesRig.make(firstQueue: queue)
        await rig.link.setAutomaticConnections(false)
        let starting = Task { await rig.first.engine.start() }
        await queue.waitForWrite(number: 7)
        let before = await rig.first.transport.commands(); XCTAssertFalse(before.contains(.startDiscovery))
        await queue.setWrites(); await starting.value
        await rig.second.engine.start(); try await rig.settle()
        let recovered = try await receipts(rig.first)
        XCTAssertEqual(Set(recovered.map(\.id)), Set([session.id, checkpoint.id, joined.id, final.id]))
        XCTAssertTrue(recovered.allSatisfy(\.isFinalEvidence))
        XCTAssertEqual(recovered.first { $0.id == session.id }?.observedDuration, 0)
        XCTAssertEqual(recovered.first { $0.id == checkpoint.id }?.observedDuration, 120)
        XCTAssertEqual(recovered.first { $0.id == final.id }, final)
        let after = await rig.first.transport.commands(); XCTAssertTrue(after.contains(.startDiscovery))
        XCTAssertFalse(after.contains { if case .read = $0 { true } else { false } })
        try await rig.stop()
        try await queue.enqueue(EncounterSamples.receipt(7))
        try await rig.start()
        let subsequent = try await receipts(rig.first); XCTAssertTrue(subsequent.contains { $0.id == EncounterSamples.receipt(7).id })
        try await rig.stop()
    }

    func testDifferentPresenceApproachesFailCleanly() async throws {
        let rig = try await PairedPhonesRig.make()
        await rig.second.engine.selectPresenceApproach(.secondExchange)
        try await startSingle(rig)
        try await rig.advance(by: 120, refreshing: false)
        let a = try await receipts(rig.first), b = try await receipts(rig.second)
        XCTAssertFalse(TestEncounterConfirmation.confirms(a, b))
        XCTAssertFalse(a.contains(where: \.hasQualifyingAmbientEvidence))
        XCTAssertFalse(b.contains(where: \.hasQualifyingAmbientEvidence))
        try await rig.stop()
    }
}
