import Foundation
import XCTest
import EncounterDomain
@testable import EncounterBluetooth

final class WriteAssemblerTests: XCTestCase {
    private func fragment(_ offset: Int, _ bytes: [UInt8],
                          characteristic: String = EncounterProtocol.centralTokenCharacteristicUUID) -> WriteFragment {
        WriteFragment(characteristic: characteristic, offset: offset, value: Data(bytes))
    }

    func testAssemblesOutOfOrderFragmentsByOffset() throws {
        XCTAssertEqual(try WriteAssembler.assemble([
            fragment(3, [4, 5]), fragment(0, [1, 2]), fragment(2, [3])
        ]), Data([1, 2, 3, 4, 5]))
    }

    func testAcceptsExactly64Bytes() throws {
        XCTAssertEqual(try WriteAssembler.assemble([
            fragment(32, Array(repeating: 2, count: 32)),
            fragment(0, Array(repeating: 1, count: 32))
        ]).count, 64)
    }

    func testRejectsGapIncludingMissingInitialFragment() {
        for fragments in [[fragment(1, [1])], [fragment(0, [1]), fragment(2, [2])]] {
            XCTAssertThrowsError(try WriteAssembler.assemble(fragments)) {
                XCTAssertEqual($0 as? WriteAssemblyError, .gap)
            }
        }
    }

    func testRejectsOverlapAndNegativeOffset() {
        for fragments in [[fragment(0, [1, 2]), fragment(1, [3])],
                          [fragment(0, [1]), fragment(0, [2])], [fragment(-1, [1])]] {
            XCTAssertThrowsError(try WriteAssembler.assemble(fragments)) {
                XCTAssertEqual($0 as? WriteAssemblyError, .overlap)
            }
        }
    }

    func testRejectsOverflowAndExtremeOffsetWithoutIntegerOverflow() {
        XCTAssertThrowsError(try WriteAssembler.assemble([fragment(0, Array(repeating: 1, count: 65))])) {
            XCTAssertEqual($0 as? WriteAssemblyError, .overflow)
        }
        XCTAssertThrowsError(try WriteAssembler.assemble([
            fragment(0, Array(repeating: 1, count: 64)), fragment(64, [2])
        ])) { XCTAssertEqual($0 as? WriteAssemblyError, .overflow) }
        XCTAssertThrowsError(try WriteAssembler.assemble([fragment(Int.max, [1])])) {
            XCTAssertEqual($0 as? WriteAssemblyError, .gap)
        }
    }

    func testRejectsWrongCharacteristicAnywhereInCallback() {
        XCTAssertThrowsError(try WriteAssembler.assemble([
            fragment(0, [1]), fragment(1, [2], characteristic: EncounterProtocol.peripheralTokenCharacteristicUUID)
        ])) { XCTAssertEqual($0 as? WriteAssemblyError, .wrongCharacteristic) }
    }

    func testRejectsMissingValueAndDoesNotCarryPartialStateBetweenCallbacks() throws {
        XCTAssertThrowsError(try WriteAssembler.assemble([
            WriteFragment(characteristic: EncounterProtocol.centralTokenCharacteristicUUID, offset: 0, value: nil)
        ])) { XCTAssertEqual($0 as? WriteAssemblyError, .missingValue) }
        XCTAssertEqual(try WriteAssembler.assemble([fragment(0, [1, 2])]), Data([1, 2]))
        XCTAssertThrowsError(try WriteAssembler.assemble([fragment(2, [3])]))
    }
}

final class ReadSnapshotTests: XCTestCase {
    private let peer = PeerHandle()
    private let now = Date(timeIntervalSince1970: 1_000)

    func testContinuationUsesImmutableSnapshotUntilStrictExpiry() {
        var snapshots = ReadSnapshots()
        var source = Data([1, 2, 3, 4])
        let snapshot = BluetoothReadSnapshot(frame: source, validUntil: now.addingTimeInterval(10))
        snapshots.begin(peer, request: .init(1))
        XCTAssertEqual(snapshots.answer(peer, request: .init(1), snapshot: snapshot, now: now), source)
        source[1] = 99
        XCTAssertEqual(snapshots.continuation(peer, offset: 1, now: now.addingTimeInterval(9.999)), Data([2, 3, 4]))
        XCTAssertNil(snapshots.continuation(peer, offset: 1, now: now.addingTimeInterval(10)))
        XCTAssertNil(snapshots.continuation(peer, offset: 1, now: now.addingTimeInterval(11)))
    }

    func testContinuationRejectsAbsentSnapshotAndOffsetsOutsideFrame() {
        var snapshots = ReadSnapshots()
        XCTAssertNil(snapshots.continuation(peer, offset: 1, now: now))
        snapshots.begin(peer, request: .init(1))
        _ = snapshots.answer(peer, request: .init(1), snapshot:
            .init(frame: Data([1, 2, 3]), validUntil: now.addingTimeInterval(10)), now: now)
        for offset in [-1, 0, 3, 4, Int.max] {
            XCTAssertNil(snapshots.continuation(peer, offset: offset, now: now))
        }
        XCTAssertEqual(snapshots.continuation(peer, offset: 2, now: now), Data([3]))
    }

    func testNewReadDiscardsOldSnapshotAndIgnoresStaleAnswer() {
        var snapshots = ReadSnapshots()
        let old = BluetoothReadSnapshot(frame: Data([1, 2]), validUntil: now.addingTimeInterval(10))
        let new = BluetoothReadSnapshot(frame: Data([3, 4]), validUntil: now.addingTimeInterval(10))
        snapshots.begin(peer, request: .init(1))
        _ = snapshots.answer(peer, request: .init(1), snapshot: old, now: now)
        snapshots.begin(peer, request: .init(2))
        XCTAssertNil(snapshots.continuation(peer, offset: 1, now: now))
        XCTAssertNil(snapshots.answer(peer, request: .init(1), snapshot: old, now: now))
        XCTAssertEqual(snapshots.answer(peer, request: .init(2), snapshot: new, now: now), new.frame)
        XCTAssertNil(snapshots.answer(peer, request: .init(2), snapshot: old, now: now))
        XCTAssertEqual(snapshots.continuation(peer, offset: 1, now: now), Data([4]))
    }

    func testDisconnectDropsSnapshotAndPendingAnswer() {
        var snapshots = ReadSnapshots()
        let snapshot = BluetoothReadSnapshot(frame: Data([1, 2]), validUntil: now.addingTimeInterval(10))
        snapshots.begin(peer, request: .init(1))
        _ = snapshots.answer(peer, request: .init(1), snapshot: snapshot, now: now)
        snapshots.drop(peer)
        XCTAssertNil(snapshots.continuation(peer, offset: 1, now: now))
        snapshots.begin(peer, request: .init(2))
        snapshots.drop(peer)
        XCTAssertNil(snapshots.answer(peer, request: .init(2), snapshot: snapshot, now: now))
    }

    func testRefusesNilExpiredAndOversizedAnswers() {
        var snapshots = ReadSnapshots()
        let answers: [BluetoothReadSnapshot?] = [nil,
            .init(frame: Data([1, 2]), validUntil: now),
            .init(frame: Data(repeating: 1, count: 65), validUntil: now.addingTimeInterval(10))]
        for answer in answers {
            snapshots.begin(peer, request: .init(1))
            XCTAssertNil(snapshots.answer(peer, request: .init(1), snapshot: answer, now: now))
            XCTAssertNil(snapshots.continuation(peer, offset: 1, now: now))
        }
    }

    func testSnapshotsAreIndependentForEachCentral() {
        let other = PeerHandle()
        var snapshots = ReadSnapshots()
        for (peer, byte) in [(peer, UInt8(1)), (other, UInt8(2))] {
            snapshots.begin(peer, request: .init(1))
            _ = snapshots.answer(peer, request: .init(1), snapshot:
                .init(frame: Data([byte, byte]), validUntil: now.addingTimeInterval(10)), now: now)
        }
        snapshots.drop(peer)
        XCTAssertEqual(snapshots.continuation(other, offset: 1, now: now), Data([2]))
    }
}

final class LinkLifecycleTests: XCTestCase {
    func testPeripheralConnectsOnSubscriptionAndDisconnectsOnceOnUnsubscription() {
        let peer = PeerHandle()
        var links = PeripheralLinks()
        XCTAssertFalse(links.acceptsRequests(peer))
        XCTAssertTrue(links.subscribe(peer))
        XCTAssertTrue(links.acceptsRequests(peer))
        XCTAssertFalse(links.subscribe(peer))
        XCTAssertTrue(links.unsubscribe(peer))
        XCTAssertFalse(links.acceptsRequests(peer))
        XCTAssertFalse(links.unsubscribe(peer))
        XCTAssertFalse(links.close(peer))
    }

    func testPeripheralLogicalCloseRejectsRequestsUntilUnsubscribeAndSubscribe() {
        let peer = PeerHandle()
        var links = PeripheralLinks()
        XCTAssertTrue(links.subscribe(peer))
        XCTAssertTrue(links.close(peer))
        XCTAssertFalse(links.acceptsRequests(peer))
        XCTAssertFalse(links.close(peer))
        XCTAssertFalse(links.subscribe(peer))
        XCTAssertFalse(links.acceptsRequests(peer))
        XCTAssertFalse(links.unsubscribe(peer))
        XCTAssertTrue(links.subscribe(peer))
        XCTAssertTrue(links.acceptsRequests(peer))
        XCTAssertTrue(links.unsubscribe(peer))
    }

    func testClosingPeripheralDropsReadStateBeforeResubscription() {
        let peer = PeerHandle()
        let now = Date(timeIntervalSince1970: 100)
        var links = PeripheralLinks()
        var snapshots = ReadSnapshots()
        _ = links.subscribe(peer)
        snapshots.begin(peer, request: .init(1))
        _ = snapshots.answer(peer, request: .init(1), snapshot:
            .init(frame: Data([1, 2]), validUntil: now.addingTimeInterval(10)), now: now)
        if links.close(peer) { snapshots.drop(peer) }
        _ = links.unsubscribe(peer)
        _ = links.subscribe(peer)
        XCTAssertNil(snapshots.continuation(peer, offset: 1, now: now))
    }

    func testCentralEveryDisconnectCommandIsAcknowledgedForNeverPendingAndGoneLinks() {
        let peer = PeerHandle()
        let expected = BluetoothEvent.disconnected(.init(peer: peer, role: .central))
        var links = CentralLinks()
        XCTAssertEqual(links.disconnect(peer), expected) // Never established.
        links.begin(peer)
        XCTAssertEqual(links.disconnect(peer), expected) // Pending or established.
        XCTAssertFalse(links.end(peer)) // Late delegate callback emits nothing.
        XCTAssertEqual(links.disconnect(peer), expected) // Already gone.
        XCTAssertEqual(links.disconnect(peer), expected) // Each command gets its own event.
    }

    func testCentralUncommandedLossEmitsOnceAndLaterCommandStillAcknowledged() {
        let peer = PeerHandle()
        var links = CentralLinks()
        links.begin(peer)
        XCTAssertTrue(links.end(peer))
        XCTAssertFalse(links.end(peer))
        XCTAssertEqual(links.disconnect(peer), .disconnected(.init(peer: peer, role: .central)))
        links.begin(peer)
        XCTAssertTrue(links.end(peer))
    }

    func testReciprocalLinksHaveIndependentLifecycles() {
        let peer = PeerHandle()
        var central = CentralLinks()
        var peripheral = PeripheralLinks()
        central.begin(peer)
        _ = peripheral.subscribe(peer)
        _ = central.disconnect(peer)
        XCTAssertTrue(peripheral.acceptsRequests(peer))
        XCTAssertTrue(peripheral.close(peer))
        XCTAssertFalse(central.end(peer))
    }
}

final class ObservationTests: XCTestCase {
    func testThrottlesEachPeerIndependentlyAtTwoSecondBoundary() {
        let peer = PeerHandle(), other = PeerHandle()
        var registry = ObservationRegistry(capacity: 3)
        XCTAssertEqual(registry.observe(peer, now: 10)?.shouldEmit, true)
        XCTAssertEqual(registry.observe(peer, now: 10)?.shouldEmit, false)
        XCTAssertEqual(registry.observe(other, now: 10.5)?.shouldEmit, true)
        XCTAssertEqual(registry.observe(peer, now: 11.999)?.shouldEmit, false)
        XCTAssertEqual(registry.observe(peer, now: 12)?.shouldEmit, true)
        XCTAssertEqual(registry.observe(other, now: 12)?.shouldEmit, false)
        XCTAssertEqual(registry.observe(other, now: 12.5)?.shouldEmit, true)
    }

    func testBoundedRegistryCannotEvictRecentObservationToBypassThrottle() {
        let first = PeerHandle(), second = PeerHandle(), third = PeerHandle()
        var registry = ObservationRegistry(capacity: 2)
        XCTAssertNotNil(registry.observe(first, now: 0))
        XCTAssertNotNil(registry.observe(second, now: 0.5))
        XCTAssertNil(registry.observe(third, now: 1))
        XCTAssertEqual(registry.observe(third, now: 2)?.evicted, first)
        XCTAssertNil(registry.observe(first, now: 2.1))
        XCTAssertEqual(registry.observe(first, now: 2.5)?.evicted, second)
    }
}

final class CombinedRadioTests: XCTestCase {
    func testUnknownUntilBothManagersArePoweredOnAndOnlyEmitsChanges() {
        var radio = CombinedRadio()
        XCTAssertEqual(radio.availability, .unknown)
        XCTAssertNil(radio.update())
        radio.central = .poweredOn
        XCTAssertNil(radio.update())
        radio.peripheral = .poweredOn
        XCTAssertEqual(radio.update(), .available)
        XCTAssertNil(radio.update())
        radio.central = .unavailable
        XCTAssertEqual(radio.update(), .unavailable)
        XCTAssertNil(radio.update())
        radio.central = .poweredOn
        XCTAssertEqual(radio.update(), .available)
    }

    func testEveryCombinationWithUnauthorizedTakingPrecedence() {
        let states: [ManagerRadioState] = [.unknown, .poweredOn, .unauthorized, .unavailable]
        for central in states {
            for peripheral in states {
                var radio = CombinedRadio(central: central, peripheral: peripheral)
                _ = radio.update()
                let expected: RadioAvailability
                if central == .unauthorized || peripheral == .unauthorized { expected = .unauthorized }
                else if central == .unavailable || peripheral == .unavailable { expected = .unavailable }
                else if central == .poweredOn && peripheral == .poweredOn { expected = .available }
                else { expected = .unknown }
                XCTAssertEqual(radio.availability, expected)
                XCTAssertNil(radio.update())
            }
        }
    }
}
