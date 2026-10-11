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

    func testOversizedBatchIsRejectedBeforeInspectingAnyFragment() {
        var inspected = 0
        XCTAssertThrowsError(try WriteAssembler.validateBatch(Array(0..<9)) { _ in
            inspected += 1
            return Data([1])
        }) { XCTAssertEqual($0 as? WriteAssemblyError, .tooManyFragments) }
        XCTAssertEqual(inspected, 0)
        XCTAssertThrowsError(try WriteAssembler.assemble(Array(repeating: fragment(Int.max, []), count: 9))) {
            XCTAssertEqual($0 as? WriteAssemblyError, .tooManyFragments)
        }
    }

    func testEightFragmentsAreAcceptedAndEmptyValueRejectedBeforeSorting() throws {
        XCTAssertEqual(try WriteAssembler.assemble((0..<8).reversed().map { fragment($0, [UInt8($0)]) }),
                       Data(0..<8))
        XCTAssertThrowsError(try WriteAssembler.assemble([
            fragment(-1, [1]), fragment(Int.max, [])
        ])) { XCTAssertEqual($0 as? WriteAssemblyError, .emptyValue) }
        XCTAssertThrowsError(try WriteAssembler.assemble([fragment(0, [])])) {
            XCTAssertEqual($0 as? WriteAssemblyError, .emptyValue)
        }
    }
}

final class EventAdmissionTests: XCTestCase {
    func testBacklogKeepsArrivalOrderAndDropsOnlyObservationsAtLimit() {
        var backlog = EventBacklog()
        let observed = (0..<256).map { _ in BluetoothEvent.peerObserved(PeerHandle()) }
        for event in observed { XCTAssertTrue(backlog.append(event)) }
        XCTAssertEqual(backlog.count, 256)
        XCTAssertFalse(backlog.append(.peerObserved(PeerHandle())))
        let peer = PeerHandle(), id = BluetoothRequestID(1)
        let connection = BluetoothConnection(peer: peer, role: .peripheral)
        let admitted: [BluetoothEvent] = [
            .connected(connection), .frameRead(peer, id, Data([1])), .readFailed(peer, id),
            .writeAcknowledged(peer, id), .writeFailed(peer, id), .connectFailed(peer),
            .disconnected(connection), .incomingRead(peer, id), .incomingWrite(peer, id, Data([2])),
            .availabilityChanged(.unavailable), .restored([connection])
        ]
        for event in admitted { XCTAssertTrue(backlog.append(event)) }
        XCTAssertEqual(backlog.count, 256 + admitted.count)
        for event in observed + admitted { XCTAssertEqual(backlog.next(), event) }
        XCTAssertNil(backlog.next())
        XCTAssertEqual(backlog.count, 0)
        XCTAssertTrue(backlog.append(.peerObserved(peer)))
        XCTAssertEqual(backlog.next(), .peerObserved(peer))
    }

    func testSubscriptionAdmissionUsesBacklogAndOpenLinkCount() {
        XCTAssertTrue(RadioAdmission.permits(.subscription, backlogCount: 255, openLinkCount: 15))
        XCTAssertFalse(RadioAdmission.permits(.subscription, backlogCount: 256, openLinkCount: 0))
        XCTAssertFalse(RadioAdmission.permits(.subscription, backlogCount: 0, openLinkCount: 16))
        XCTAssertFalse(RadioAdmission.permits(.observation, backlogCount: 257))
        XCTAssertTrue(RadioAdmission.permits(.admittedWork, backlogCount: 300, openLinkCount: 16))
    }

    func testRefusedCentralHasNoLifecycleUntilAdmittedLater() {
        let peer = PeerHandle()
        var links = PeripheralLinks()
        XCTAssertFalse(links.subscribe(peer, backlogCount: 256))
        XCTAssertEqual(links.count, 0)
        XCTAssertFalse(links.acceptsRequests(peer))
        XCTAssertFalse(links.unsubscribe(peer))
        XCTAssertFalse(links.close(peer))
        XCTAssertTrue(links.subscribe(peer, backlogCount: 255))
        XCTAssertTrue(links.acceptsRequests(peer))
        XCTAssertTrue(links.unsubscribe(peer))
        XCTAssertFalse(links.unsubscribe(peer))
    }

    func testLogicalCloseFreesAllSixteenSlotsWhileCentralsStaySubscribed() {
        let peers = (0..<16).map { _ in PeerHandle() }, refused = PeerHandle()
        var links = PeripheralLinks()
        var backlog = EventBacklog()
        for peer in peers {
            XCTAssertTrue(links.subscribe(peer, backlogCount: backlog.count))
            backlog.append(.connected(.init(peer: peer, role: .peripheral)))
        }
        XCTAssertEqual(links.openPeers.count, 16)
        XCTAssertFalse(links.subscribe(refused))
        for peer in peers {
            let closed = links.close(peer)
            XCTAssertTrue(closed)
            if closed { backlog.append(.disconnected(.init(peer: peer, role: .peripheral))) }
        }
        XCTAssertEqual(links.openPeers.count, 0)
        XCTAssertEqual(links.count, 0)
        XCTAssertTrue(links.subscribe(refused, backlogCount: backlog.count))
        backlog.append(.connected(.init(peer: refused, role: .peripheral)))
        for peer in peers {
            XCTAssertFalse(links.acceptsRequests(peer)) // Both ATT callbacks refuse unknown centrals.
            let closed = links.close(peer), unsubscribed = links.unsubscribe(peer)
            XCTAssertFalse(closed)
            XCTAssertFalse(unsubscribed)
            if closed || unsubscribed { backlog.append(.disconnected(.init(peer: peer, role: .peripheral))) }
        }
        for peer in peers { XCTAssertEqual(backlog.next(), .connected(.init(peer: peer, role: .peripheral))) }
        for peer in peers { XCTAssertEqual(backlog.next(), .disconnected(.init(peer: peer, role: .peripheral))) }
        XCTAssertEqual(backlog.next(), .connected(.init(peer: refused, role: .peripheral)))
        XCTAssertNil(backlog.next())
        XCTAssertTrue(links.acceptsRequests(refused))
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.removeService(), [refused])
        XCTAssertEqual(links.count, 0)
    }

    func testDroppedObservationDoesNotStartOrExtendThrottle() {
        let peer = PeerHandle()
        var registry = ObservationRegistry(capacity: 2)
        XCTAssertNil(registry.observe(peer, now: 10, backlogCount: 256))
        XCTAssertEqual(registry.observe(peer, now: 10.1, backlogCount: 255)?.shouldEmit, true)
        XCTAssertNil(registry.observe(peer, now: 12.1, backlogCount: 256))
        XCTAssertEqual(registry.observe(peer, now: 12.2, backlogCount: 255)?.shouldEmit, true)
    }

    func testCentralLinksAndCancellationsShareBoundedCapacity() {
        XCTAssertTrue(RadioAdmission.canTrackCentral(links: 255, cancellations: 0))
        XCTAssertTrue(RadioAdmission.canTrackCentral(links: 0, cancellations: 255))
        XCTAssertFalse(RadioAdmission.canTrackCentral(links: 256, cancellations: 0))
        XCTAssertFalse(RadioAdmission.canTrackCentral(links: 128, cancellations: 128))
    }

    func testStalledConsumerFloodAddsOnlyTwoRequestsAndOneEndingPerAdmittedLink() {
        let peers = (0..<16).map { _ in PeerHandle() }
        var links = PeripheralLinks(), reads = PeripheralRequests(), writes = PeripheralRequests()
        var backlog = EventBacklog()
        var expected: [BluetoothEvent] = []
        for peer in peers {
            XCTAssertTrue(links.subscribe(peer, backlogCount: backlog.count))
            let event = BluetoothEvent.connected(.init(peer: peer, role: .peripheral))
            backlog.append(event)
            expected.append(event)
        }
        while backlog.count < 256 {
            let event = BluetoothEvent.peerObserved(PeerHandle())
            backlog.append(event)
            expected.append(event)
        }
        for attempt in 0..<100 {
            for peer in peers {
                let id = BluetoothRequestID(UInt64(attempt))
                if reads.begin(peer, request: id) {
                    let event = BluetoothEvent.incomingRead(peer, id)
                    backlog.append(event)
                    expected.append(event)
                }
                if writes.begin(peer, request: id) {
                    let event = BluetoothEvent.incomingWrite(peer, id, Data([1]))
                    backlog.append(event)
                    expected.append(event)
                }
            }
        }
        for peer in peers {
            XCTAssertTrue(links.unsubscribe(peer))
            reads.drop(peer)
            writes.drop(peer)
            let event = BluetoothEvent.disconnected(.init(peer: peer, role: .peripheral))
            backlog.append(event)
            expected.append(event)
            XCTAssertFalse(links.subscribe(peer, backlogCount: backlog.count))
            XCTAssertFalse(links.unsubscribe(peer))
        }
        XCTAssertEqual(backlog.count, 256 + 3 * 16)
        for event in expected { XCTAssertEqual(backlog.next(), event) }
        XCTAssertTrue(links.subscribe(peers[0], backlogCount: backlog.count))
    }

    func testPendingRequestsCannotBeSupersededOrGrowPastSixteenPeers() {
        var requests = PeripheralRequests()
        let peers = (0..<16).map { _ in PeerHandle() }, refused = PeerHandle()
        for peer in peers { XCTAssertTrue(requests.begin(peer, request: .init(1))) }
        XCTAssertEqual(requests.count, 16)
        XCTAssertFalse(requests.begin(peers[0], request: .init(2)))
        XCTAssertFalse(requests.begin(refused, request: .init(1)))
        XCTAssertFalse(requests.finish(peers[0], request: .init(2)))
        XCTAssertTrue(requests.finish(peers[0], request: .init(1)))
        XCTAssertTrue(requests.begin(refused, request: .init(2)))
        requests.drop(refused)
        XCTAssertFalse(requests.contains(refused))
    }

    func testSnapshotsAndPendingReadsShareSixteenSlots() {
        var snapshots = ReadSnapshots()
        let peers = (0..<16).map { _ in PeerHandle() }, refused = PeerHandle()
        let now = Date(timeIntervalSince1970: 10)
        for peer in peers {
            XCTAssertTrue(snapshots.begin(peer, request: .init(1)))
            XCTAssertEqual(snapshots.answer(peer, request: .init(1), snapshot:
                .init(frame: Data([1]), validUntil: now.addingTimeInterval(1)), now: now), Data([1]))
        }
        XCTAssertFalse(snapshots.begin(refused, request: .init(1)))
        XCTAssertTrue(snapshots.begin(peers[0], request: .init(2)))
        XCTAssertFalse(snapshots.begin(peers[0], request: .init(3)))
        snapshots.drop(peers[0])
        XCTAssertTrue(snapshots.begin(refused, request: .init(1)))
    }
}

@MainActor
final class EventDeliveryTests: XCTestCase {
    func testStreamDrainsExactlyOneEventPerPullAndKeepsPreconsumerEvents() async {
        let queue = DispatchQueue(label: "EventDeliveryTests")
        let delivery = EventDelivery(queue: queue)
        let stream = AsyncStream(unfolding: { await delivery.next() }, onCancel: { delivery.finish(cancelled: true) })
        let events = (0..<256).map { _ in BluetoothEvent.peerObserved(PeerHandle()) }
        queue.sync { for event in events { delivery.append(event) } }
        XCTAssertEqual(queue.sync { delivery.count }, 256)
        var iterator = stream.makeAsyncIterator()
        for (index, event) in events.enumerated() {
            let next = await iterator.next()
            XCTAssertEqual(next, event)
            XCTAssertEqual(queue.sync { delivery.count }, 255 - index)
        }
        delivery.finish()
        let next = await iterator.next()
        XCTAssertNil(next)
    }

    func testCancellationFinishesPendingConsumerPull() async {
        let delivery = EventDelivery(queue: DispatchQueue(label: "EventDeliveryCancellationTests"))
        let consumer = Task { await delivery.next() }
        consumer.cancel()
        let event = await consumer.value
        XCTAssertNil(event)
        let next = await delivery.next()
        XCTAssertNil(next)
    }

    func testNormalFinishDrainsAdmittedEventsBeforeEnding() async {
        let queue = DispatchQueue(label: "EventDeliveryFinishTests")
        let delivery = EventDelivery(queue: queue)
        let peer = PeerHandle()
        let events: [BluetoothEvent] = [.connected(.init(peer: peer, role: .peripheral)),
                                        .disconnected(.init(peer: peer, role: .peripheral))]
        queue.sync { for event in events { delivery.append(event) } }
        delivery.finish()
        for event in events {
            let next = await delivery.next()
            XCTAssertEqual(next, event)
        }
        let next = await delivery.next()
        XCTAssertNil(next)
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
        for offset in [-1, 0, 4, Int.max] {
            XCTAssertNil(snapshots.continuation(peer, offset: offset, now: now))
        }
        XCTAssertEqual(snapshots.continuation(peer, offset: 2, now: now), Data([3]))
        XCTAssertEqual(snapshots.continuation(peer, offset: 3, now: now), Data())
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

    func testPeripheralLogicalCloseRejectsRequestsUntilNewSubscriptionIsAdmitted() {
        let peer = PeerHandle()
        var links = PeripheralLinks()
        XCTAssertTrue(links.subscribe(peer))
        XCTAssertTrue(links.close(peer))
        XCTAssertFalse(links.acceptsRequests(peer))
        XCTAssertFalse(links.close(peer))
        XCTAssertEqual(links.count, 0)
        XCTAssertFalse(links.subscribe(peer, backlogCount: 256))
        XCTAssertFalse(links.acceptsRequests(peer))
        XCTAssertTrue(links.subscribe(peer, backlogCount: 255))
        XCTAssertTrue(links.acceptsRequests(peer))
        XCTAssertFalse(links.subscribe(peer))
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
        _ = links.subscribe(peer)
        XCTAssertNil(snapshots.continuation(peer, offset: 1, now: now))
    }

    func testCentralEveryDisconnectCommandIsAcknowledgedForNeverPendingAndGoneLinks() {
        let peer = PeerHandle()
        let expected = BluetoothEvent.disconnected(.init(peer: peer, role: .central))
        var links = CentralLinks()
        XCTAssertEqual(links.disconnect(peer), expected) // Never established.
        links.begin(peer)
        XCTAssertEqual(links.state(peer), .pending)
        XCTAssertEqual(links.disconnect(peer), expected)
        XCTAssertEqual(links.state(peer), .closing)
        XCTAssertNil(links.ready(peer)) // Late notification callback cannot connect.
        XCTAssertNil(links.end(peer)) // Late terminal callback emits nothing.
        XCTAssertNil(links.state(peer))
        XCTAssertEqual(links.disconnect(peer), expected) // Already gone.
        XCTAssertEqual(links.disconnect(peer), expected) // Each command gets one event.
    }

    func testCentralUncommandedPendingLossEmitsOnlyConnectFailedOnce() {
        let peer = PeerHandle()
        var links = CentralLinks()
        // Connecting, service discovery, characteristic discovery and subscription
        // all remain pending until ready, and all use the same terminal transition.
        for _ in 0..<4 {
            links.begin(peer)
            XCTAssertEqual(links.end(peer), .connectFailed(peer))
            XCTAssertNil(links.end(peer))
            XCTAssertNil(links.ready(peer))
        }
        XCTAssertEqual(links.disconnect(peer), .disconnected(.init(peer: peer, role: .central)))
    }

    func testCentralReadyLossAndCommandedCloseEachDisconnectExactlyOnce() {
        let peer = PeerHandle()
        let disconnected = BluetoothEvent.disconnected(.init(peer: peer, role: .central))
        var links = CentralLinks()
        links.begin(peer)
        XCTAssertEqual(links.ready(peer), .connected(.init(peer: peer, role: .central)))
        XCTAssertEqual(links.state(peer), .ready)
        XCTAssertNil(links.ready(peer))
        XCTAssertEqual(links.end(peer), disconnected)
        XCTAssertNil(links.end(peer))
        links.begin(peer)
        _ = links.ready(peer)
        XCTAssertEqual(links.disconnect(peer), disconnected)
        XCTAssertNil(links.end(peer))
        XCTAssertNil(links.end(peer))
    }

    func testCentralRadioLossDistinguishesPendingReadyAndClosingLinks() {
        let pending = PeerHandle(), ready = PeerHandle(), closing = PeerHandle()
        var links = CentralLinks()
        links.begin(pending)
        links.begin(ready)
        _ = links.ready(ready)
        links.begin(closing)
        _ = links.disconnect(closing)
        XCTAssertEqual(links.end(pending), .connectFailed(pending))
        XCTAssertEqual(links.end(ready), .disconnected(.init(peer: ready, role: .central)))
        XCTAssertNil(links.end(closing))
        for peer in [pending, ready, closing] { XCTAssertNil(links.end(peer)) }
    }

    func testRestoredReadyLinkCanBeClosedAndSamePeerCanConnectAgain() {
        let peer = PeerHandle()
        var links = CentralLinks()
        links.begin(peer, ready: true)
        XCTAssertEqual(links.state(peer), .ready)
        XCTAssertEqual(links.disconnect(peer), .disconnected(.init(peer: peer, role: .central)))
        XCTAssertNil(links.end(peer))
        links.begin(peer)
        XCTAssertEqual(links.ready(peer), .connected(.init(peer: peer, role: .central)))
        XCTAssertEqual(links.end(peer), .disconnected(.init(peer: peer, role: .central)))
    }

    func testServiceRemovalEndsOpenPeripheralLinksAndAllowsFreshSubscriptions() {
        let peer = PeerHandle(), closed = PeerHandle()
        var links = PeripheralLinks()
        _ = links.subscribe(peer)
        _ = links.subscribe(closed)
        _ = links.close(closed)
        XCTAssertEqual(links.removeService(), [peer])
        XCTAssertFalse(links.acceptsRequests(peer))
        XCTAssertFalse(links.unsubscribe(peer)) // Late callback after removal.
        XCTAssertTrue(links.removeService().isEmpty)
        XCTAssertTrue(links.subscribe(peer))
        XCTAssertTrue(links.subscribe(closed))
        XCTAssertTrue(links.acceptsRequests(peer))
        XCTAssertEqual(Set(links.removeService()), Set([peer, closed]))
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
        XCTAssertNil(central.end(peer))
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

final class PublicationTests: XCTestCase {
    private func publish(_ publication: inout Publication) {
        XCTAssertEqual(publication.request(true), [])
        XCTAssertEqual(publication.update(.poweredOn), [.remove, .add])
        XCTAssertTrue(publication.pending)
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: true), [.startAdvertising])
        XCTAssertTrue(publication.published)
        XCTAssertEqual(publication.didStartAdvertising(success: true), [])
        XCTAssertTrue(publication.advertising)
    }

    func testPublicationIsIdempotentAcrossRepeatedCommandsAndRadioToggles() {
        var publication = Publication()
        publish(&publication)
        XCTAssertEqual(publication.request(true), [])
        XCTAssertEqual(publication.update(.poweredOn, isAdvertising: true), [])
        for _ in 0..<3 {
            XCTAssertEqual(publication.update(.poweredOff), [])
            XCTAssertTrue(publication.published)
            XCTAssertFalse(publication.advertising)
            XCTAssertEqual(publication.update(.poweredOn), [.startAdvertising])
            XCTAssertEqual(publication.didStartAdvertising(success: true), [])
        }
    }

    func testStopWhilePoweredOffRemovesServiceAtNextPoweredOnUpdate() {
        var publication = Publication()
        publish(&publication)
        XCTAssertEqual(publication.update(.poweredOff), [])
        XCTAssertEqual(publication.request(false), [])
        XCTAssertTrue(publication.removalPending)
        XCTAssertTrue(publication.published)
        XCTAssertEqual(publication.update(.poweredOn), [.stopAdvertising, .remove])
        XCTAssertFalse(publication.published)
        XCTAssertFalse(publication.removalPending)
        XCTAssertEqual(publication.update(.poweredOn), [])
        XCTAssertEqual(publication.request(true), [.remove, .add])
    }

    func testRestartBeforePoweredOnStillRemovesOldPublicationBeforeAdding() {
        var publication = Publication()
        publish(&publication)
        _ = publication.update(.poweredOff)
        _ = publication.request(false)
        _ = publication.request(true)
        XCTAssertTrue(publication.removalPending)
        XCTAssertEqual(publication.update(.poweredOn), [.stopAdvertising, .remove, .add])
        XCTAssertTrue(publication.pending)
        XCTAssertFalse(publication.published)
    }

    func testStopDuringAddRemovesImmediatelyAndAgainOnUUIDMatchedCallback() {
        var publication = Publication()
        _ = publication.update(.poweredOn)
        XCTAssertEqual(publication.request(true), [.remove, .add])
        XCTAssertEqual(publication.request(false), [.stopAdvertising, .remove])
        XCTAssertTrue(publication.pending)
        XCTAssertTrue(publication.removalPending)
        XCTAssertEqual(publication.didAdd(matchesUUID: false, success: true), [])
        XCTAssertTrue(publication.pending)
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: true), [.stopAdvertising, .remove])
        XCTAssertFalse(publication.pending)
        XCTAssertFalse(publication.published)
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: true), []) // Duplicate.
    }

    func testInFlightAddSurvivesPoweredOffAndDeferredStop() {
        var publication = Publication()
        _ = publication.update(.poweredOn)
        _ = publication.request(true)
        XCTAssertEqual(publication.update(.poweredOff), [])
        XCTAssertTrue(publication.pending)
        _ = publication.request(false)
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: true), [])
        XCTAssertTrue(publication.published)
        XCTAssertEqual(publication.update(.poweredOn), [.stopAdvertising, .remove])
    }

    func testPoweredOnClearsStoppedPendingAddWithoutWaitingForItsCallback() {
        var publication = Publication()
        _ = publication.update(.poweredOn)
        _ = publication.request(true)
        _ = publication.update(.poweredOff)
        _ = publication.request(false)
        XCTAssertEqual(publication.update(.poweredOn), [.stopAdvertising, .remove])
        XCTAssertFalse(publication.pending)
        XCTAssertFalse(publication.removalPending)
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: true), [])
        XCTAssertFalse(publication.pending)
        XCTAssertFalse(publication.published)
    }

    func testPowerCycleRetriesPendingAddWhoseCallbackNeverArrives() {
        var publication = Publication()
        _ = publication.update(.poweredOn)
        XCTAssertEqual(publication.request(true), [.remove, .add])
        XCTAssertEqual(publication.update(.poweredOff), [])
        XCTAssertTrue(publication.pending)
        XCTAssertEqual(publication.update(.poweredOn), [.remove, .add])
        XCTAssertTrue(publication.pending) // A fresh add replaced the interrupted one.
        XCTAssertEqual(publication.update(.poweredOn), [])
        XCTAssertEqual(publication.request(true), [])
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: true), [.startAdvertising])
        XCTAssertEqual(publication.didStartAdvertising(success: true), [])
        XCTAssertTrue(publication.published)
        XCTAssertTrue(publication.advertising)
    }

    func testRestartDuringAddCannotAddTwiceBeforeItsCallback() {
        var publication = Publication()
        _ = publication.update(.poweredOn)
        _ = publication.request(true)
        _ = publication.request(false)
        XCTAssertEqual(publication.request(true), [.stopAdvertising, .remove])
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: true), [.stopAdvertising, .remove, .add])
        XCTAssertTrue(publication.pending)
        XCTAssertFalse(publication.published)
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: true), [.startAdvertising])
    }

    func testDatabaseClearingStatesDiscardPublicationAndPendingAdd() {
        var publication = Publication()
        publish(&publication)
        XCTAssertEqual(publication.update(.databaseCleared), [])
        XCTAssertFalse(publication.published)
        XCTAssertEqual(publication.update(.poweredOn), [.remove, .add])
        _ = publication.update(.databaseCleared)
        XCTAssertFalse(publication.pending)
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: true), [])
        XCTAssertEqual(publication.update(.poweredOn), [.remove, .add])
    }

    func testAddFailureRetriesOnceThenReportsUnavailableUntilRecovery() {
        var publication = Publication()
        _ = publication.update(.poweredOn)
        _ = publication.request(true)
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: false), [.remove, .add])
        XCTAssertTrue(publication.addRetried)
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: false),
                       [.unavailable, .scheduleRearm(after: 30)])
        XCTAssertTrue(publication.unavailable)
        XCTAssertFalse(publication.pending)
        XCTAssertFalse(publication.published)
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: false), [])
        XCTAssertEqual(publication.request(true), [.cancelRearm, .remove, .add])
        XCTAssertFalse(publication.unavailable)
        XCTAssertFalse(publication.addRetried)
        _ = publication.didAdd(matchesUUID: true, success: false)
        _ = publication.didAdd(matchesUUID: true, success: false)
        XCTAssertEqual(publication.update(.poweredOn), [.cancelRearm, .remove, .add])
        XCTAssertFalse(publication.unavailable)
    }

    func testAdvertisingFailureRetriesOnceWithoutAddingServiceAgain() {
        var publication = Publication()
        _ = publication.update(.poweredOn)
        _ = publication.request(true)
        _ = publication.didAdd(matchesUUID: true, success: true)
        XCTAssertEqual(publication.didStartAdvertising(success: false), [.startAdvertising])
        XCTAssertTrue(publication.advertisingRetried)
        XCTAssertEqual(publication.didStartAdvertising(success: false),
                       [.unavailable, .scheduleRearm(after: 30)])
        XCTAssertTrue(publication.unavailable)
        XCTAssertTrue(publication.published)
        XCTAssertEqual(publication.didStartAdvertising(success: false), [])
        XCTAssertEqual(publication.update(.poweredOn), [.cancelRearm, .startAdvertising])
        XCTAssertFalse(publication.unavailable)
        _ = publication.didStartAdvertising(success: false)
        _ = publication.didStartAdvertising(success: false)
        XCTAssertEqual(publication.request(true), [.cancelRearm, .startAdvertising])
        XCTAssertFalse(publication.advertisingRetried)
    }

    func testDelayedRearmBoundsPersistentAddFailuresAndHealsTransientFailure() {
        var publication = Publication()
        var radio = CombinedRadio(central: .poweredOn, peripheral: .poweredOn)
        XCTAssertEqual(radio.update(), .available)
        _ = publication.update(.poweredOn)
        _ = publication.request(true)
        for _ in 0..<3 {
            XCTAssertEqual(publication.didAdd(matchesUUID: true, success: false), [.remove, .add])
            XCTAssertEqual(publication.didAdd(matchesUUID: true, success: false),
                           [.unavailable, .scheduleRearm(after: 30)])
            radio.peripheral = publication.unavailable ? .unavailable : .poweredOn
            XCTAssertEqual(radio.update(), .unavailable)
            XCTAssertEqual(publication.didAdd(matchesUUID: true, success: false), [])
            XCTAssertEqual(publication.rearm(), [.remove, .add])
            XCTAssertFalse(publication.unavailable)
            XCTAssertFalse(publication.addRetried)
            radio.peripheral = publication.unavailable ? .unavailable : .poweredOn
            XCTAssertEqual(radio.update(), .available)
            XCTAssertEqual(publication.rearm(), []) // Only one re-arm per failure pair.
        }
        XCTAssertEqual(publication.didAdd(matchesUUID: true, success: true), [.startAdvertising])
        XCTAssertEqual(publication.didStartAdvertising(success: true), [])
        XCTAssertTrue(publication.advertising)
    }

    func testDelayedRearmRetriesAdvertisingWithoutRepublishingService() {
        var publication = Publication()
        _ = publication.update(.poweredOn)
        _ = publication.request(true)
        _ = publication.didAdd(matchesUUID: true, success: true)
        for _ in 0..<3 {
            XCTAssertEqual(publication.didStartAdvertising(success: false), [.startAdvertising])
            XCTAssertEqual(publication.didStartAdvertising(success: false),
                           [.unavailable, .scheduleRearm(after: 30)])
            XCTAssertEqual(publication.didStartAdvertising(success: false), [])
            XCTAssertEqual(publication.rearm(), [.startAdvertising])
            XCTAssertFalse(publication.unavailable)
            XCTAssertFalse(publication.advertisingRetried)
            XCTAssertTrue(publication.published)
            XCTAssertEqual(publication.rearm(), [])
        }
        XCTAssertEqual(publication.didStartAdvertising(success: true), [])
        XCTAssertTrue(publication.advertising)
    }

    func testStoppingDiscoveryCancelsRearmAndLateRearmCannotRepublish() {
        for advertisingFailure in [false, true] {
            var publication = Publication()
            _ = publication.update(.poweredOn)
            _ = publication.request(true)
            if advertisingFailure {
                _ = publication.didAdd(matchesUUID: true, success: true)
                _ = publication.didStartAdvertising(success: false)
                _ = publication.didStartAdvertising(success: false)
            } else {
                _ = publication.didAdd(matchesUUID: true, success: false)
                _ = publication.didAdd(matchesUUID: true, success: false)
            }
            XCTAssertEqual(publication.request(false), [.cancelRearm, .stopAdvertising, .remove])
            XCTAssertEqual(publication.rearm(), [])
            XCTAssertFalse(publication.pending)
            XCTAssertFalse(publication.advertisingPending)
            XCTAssertFalse(publication.published)
            XCTAssertEqual(publication.request(true), [.remove, .add])
        }
    }

    func testRadioLossCancelsRearmUntilPoweredOn() {
        var publication = Publication()
        _ = publication.update(.poweredOn)
        _ = publication.request(true)
        _ = publication.didAdd(matchesUUID: true, success: false)
        _ = publication.didAdd(matchesUUID: true, success: false)
        XCTAssertEqual(publication.update(.poweredOff), [.cancelRearm])
        XCTAssertEqual(publication.rearm(), [])
        XCTAssertEqual(publication.update(.poweredOn), [.remove, .add])
        XCTAssertEqual(publication.rearm(), [])
    }

    func testLateAdvertisingCallbackAfterStopCannotRestartDiscovery() {
        var publication = Publication()
        _ = publication.update(.poweredOn)
        _ = publication.request(true)
        _ = publication.didAdd(matchesUUID: true, success: true)
        XCTAssertEqual(publication.request(false), [.stopAdvertising, .remove])
        XCTAssertEqual(publication.didStartAdvertising(success: true), [.stopAdvertising])
        XCTAssertFalse(publication.published)
        XCTAssertFalse(publication.advertising)
    }

    func testRestoredPublicationIsKeptUntilAnExplicitDiscoveryDecision() {
        var publication = Publication()
        publication.restorePublished()
        XCTAssertNil(publication.requested)
        XCTAssertEqual(publication.update(.poweredOn, isAdvertising: true), [])
        XCTAssertTrue(publication.published)
        XCTAssertEqual(publication.request(true), [])
        XCTAssertEqual(publication.request(false), [.stopAdvertising, .remove])
        XCTAssertFalse(publication.published)
    }
}
