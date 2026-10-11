import Foundation
import EncounterDomain

/// Identifies an endpoint in the two-phone test link, never a production device.
public enum FakePhoneID: Int, Sendable, CaseIterable { case first, second
    public var other: Self { self == .first ? .second : .first }
    public var peerHandle: PeerHandle {
        PeerHandle(id: UUID(uuidString: self == .first ? "00000000-0000-0000-0000-000000000001" :
                            "00000000-0000-0000-0000-000000000002")!)
    }
}

/// Selects deliveries that may be delayed, dropped, or reordered in tests.
public enum FakeDeliveryKind: Sendable, Hashable {
    case availability, observation, connected, connectFailed, frameRead, readFailed, writeAcknowledgement
    case writeFailed, disconnected, incomingRead, incomingWrite, restoration
    public init(_ event: BluetoothEvent) {
        switch event {
        case .availabilityChanged: self = .availability
        case .peerObserved: self = .observation
        case .connected: self = .connected
        case .connectFailed: self = .connectFailed
        case .frameRead: self = .frameRead
        case .readFailed: self = .readFailed
        case .writeAcknowledged: self = .writeAcknowledgement
        case .writeFailed: self = .writeFailed
        case .disconnected: self = .disconnected
        case .incomingRead: self = .incomingRead
        case .incomingWrite: self = .incomingWrite
        case .restored: self = .restoration
        }
    }
}

/// A held delivery can be released individually to construct an explicit event order.
public struct FakeBluetoothDelivery: Sendable {
    public let id: UInt64
    public let phone: FakePhoneID
    public let event: BluetoothEvent
    fileprivate let validUntil: Date?
    fileprivate let snapshotPhone: FakePhoneID?
}

/// Implements radio primitives; it never creates receipts or implements exchange policy.
public final class FakeBluetoothTransport: BluetoothTransport, Sendable {
    public let events: AsyncStream<BluetoothEvent>
    public let phone: FakePhoneID
    public let link: FakeBluetoothLink
    public init(phone: FakePhoneID, link: FakeBluetoothLink, clock: ManualEncounterClock) async {
        self.phone = phone; self.link = link
        let stream = AsyncStream<BluetoothEvent>.makeStream()
        events = stream.stream
        await link.attach(phone, continuation: stream.continuation, clock: clock)
    }
    public func execute(_ command: BluetoothCommand) async { await link.execute(command, from: phone) }
    /// Injects a complete delegate event through the same ordered stream as simulated radio events.
    public func inject(_ event: BluetoothEvent) async { await link.inject(event, to: phone) }
    /// Returns primitive commands for assertions about ordering and connection limits.
    public func commands() async -> [BluetoothCommand] { await link.commands(for: phone) }
}

/// Joins two radio endpoints and offers explicit control of loss, delay and restoration.
public actor FakeBluetoothLink {
    private struct Endpoint {
        let continuation: AsyncStream<BluetoothEvent>.Continuation
        let clock: ManualEncounterClock
        var count: UInt64 = 0
        var commands: [BluetoothCommand] = []
        var discovery = false
    }
    private var endpoints: [FakePhoneID: Endpoint] = [:]
    private var connections: Set<FakePhoneID> = []
    private var delayedKinds: Set<FakeDeliveryKind> = []
    private var drops: [FakeDeliveryKind: Int] = [:]
    private var withheldAcknowledgements: Set<FakePhoneID> = []
    private var held: [FakeBluetoothDelivery] = []
    private var sequence: UInt64 = 0
    private var autoConnect = true
    public init() {}
    fileprivate func attach(_ phone: FakePhoneID, continuation: AsyncStream<BluetoothEvent>.Continuation,
                            clock: ManualEncounterClock) {
        endpoints[phone] = Endpoint(continuation: continuation, clock: clock)
        send(.availabilityChanged(.available), to: phone)
    }
    /// Disables connection callbacks to simulate pending connects and arbitrary peers.
    public func setAutomaticConnections(_ enabled: Bool) { autoConnect = enabled }
    /// New matching deliveries remain held until explicitly released.
    public func delay(_ kinds: Set<FakeDeliveryKind>) { delayedKinds = kinds }
    /// Drops the next count deliveries of the selected kind.
    public func dropNext(_ kind: FakeDeliveryKind, count: Int = 1) { drops[kind, default: 0] += count }
    /// Simulates a durable peripheral receipt with a lost response on one central.
    public func withholdWriteAcknowledgements(to phone: FakePhoneID, enabled: Bool = true) {
        if enabled { withheldAcknowledgements.insert(phone) } else { withheldAcknowledgements.remove(phone) }
    }
    /// Held deliveries preserve their original ordering until the test chooses a different order.
    public func pendingDeliveries() -> [FakeBluetoothDelivery] { held }
    /// Releases one chosen delivery, optionally substituting malformed bytes or a stale nonce.
    public func release(_ id: UInt64, replacing event: BluetoothEvent? = nil) async {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        let delivery = held.remove(at: index)
        if let until = delivery.validUntil, let source = delivery.snapshotPhone, let clock = endpoints[source]?.clock,
           await clock.now().wall >= until,
           case .frameRead(let peer, let request, _) = delivery.event {
            emit(.readFailed(peer, request), to: delivery.phone)
        } else { emit(event ?? delivery.event, to: delivery.phone) }
    }
    /// Releases all held deliveries in forward or reverse order without changing future delay rules.
    public func releaseAll(reversed: Bool = false) async {
        let ids = held.map(\.id)
        for id in reversed ? ids.reversed().map({ $0 }) : ids { await release(id) }
    }
    /// Breaks one outgoing link (or both reciprocal links), delivering disconnects to each endpoint.
    public func breakLink(central: FakePhoneID? = nil) {
        for phone in FakePhoneID.allCases where central == nil || phone == central { disconnect(central: phone) }
    }
    /// Reports connected peers after a simulated manager restoration or process relaunch.
    public func restore(on phone: FakePhoneID, connections: [BluetoothConnection]) { send(.restored(connections), to: phone) }
    /// Injects an event without interpreting protocol frames.
    public func inject(_ event: BluetoothEvent, to phone: FakePhoneID) { send(event, to: phone) }
    /// Counts emitted events so a rig can fence delivery without real sleeping.
    public func emittedCount(for phone: FakePhoneID) -> UInt64 { endpoints[phone]?.count ?? 0 }
    public func commands(for phone: FakePhoneID) -> [BluetoothCommand] { endpoints[phone]?.commands ?? [] }
    /// Includes the two separate reciprocal radio connections.
    public var activeLinkCount: Int { connections.count }

    fileprivate func execute(_ command: BluetoothCommand, from phone: FakePhoneID) {
        endpoints[phone]?.commands.append(command)
        let peer = phone.other.peerHandle
        switch command {
        case .startDiscovery:
            endpoints[phone]?.discovery = true
            if endpoints[phone.other]?.discovery == true {
                send(.peerObserved(peer), to: phone)
                send(.peerObserved(phone.peerHandle), to: phone.other)
            }
        case .stopDiscovery: endpoints[phone]?.discovery = false
        case .connect(let target):
            guard autoConnect else { return }
            guard target == peer, endpoints[phone.other]?.discovery == true, !connections.contains(phone) else {
                send(.connectFailed(target), to: phone); return
            }
            connections.insert(phone)
            // Queue both callbacks atomically before either engine can dispatch a read.
            send(.connected(.init(peer: peer, role: .central)), to: phone)
            send(.connected(.init(peer: phone.peerHandle, role: .peripheral)), to: phone.other)
        case .read(let target, let request):
            guard target == peer, connections.contains(phone) else { send(.readFailed(target, request), to: phone); return }
            send(.incomingRead(phone.peerHandle, request), to: phone.other)
        case .write(let target, let request, let frame):
            guard target == peer, connections.contains(phone) else { send(.writeFailed(target, request), to: phone); return }
            send(.incomingWrite(phone.peerHandle, request, frame), to: phone.other)
        case .disconnect(let connection):
            guard connection.peer == peer else { send(.disconnected(connection), to: phone); return }
            let central = connection.role == .central ? phone : phone.other
            if connections.contains(central) { disconnect(central: central) }
            else { send(.disconnected(connection), to: phone) }
        case .answerRead(_, let request, let snapshot):
            guard connections.contains(phone.other) else { return }
            if let snapshot {
                send(.frameRead(phone.peerHandle, request, snapshot.frame), to: phone.other,
                     validUntil: snapshot.validUntil, snapshotPhone: phone)
            } else { send(.readFailed(phone.peerHandle, request), to: phone.other) }
        case .answerWrite(_, let request, let success):
            guard connections.contains(phone.other) else { return }
            send(success ? .writeAcknowledged(phone.peerHandle, request) : .writeFailed(phone.peerHandle, request), to: phone.other)
        }
    }
    private func disconnect(central: FakePhoneID) {
        guard connections.remove(central) != nil else { return }
        send(.disconnected(.init(peer: central.other.peerHandle, role: .central)), to: central)
        send(.disconnected(.init(peer: central.peerHandle, role: .peripheral)), to: central.other)
    }
    private func send(_ event: BluetoothEvent, to phone: FakePhoneID, validUntil: Date? = nil,
                      snapshotPhone: FakePhoneID? = nil) {
        let kind = FakeDeliveryKind(event)
        if kind == .writeAcknowledgement && withheldAcknowledgements.contains(phone) { return }
        if drops[kind, default: 0] > 0 { drops[kind, default: 0] -= 1; return }
        if delayedKinds.contains(kind) {
            sequence &+= 1
            held.append(.init(id: sequence, phone: phone, event: event, validUntil: validUntil, snapshotPhone: snapshotPhone))
        } else { emit(event, to: phone) }
    }
    private func emit(_ event: BluetoothEvent, to phone: FakePhoneID) {
        guard var endpoint = endpoints[phone] else { return }
        endpoint.count &+= 1; endpoints[phone] = endpoint
        endpoint.continuation.yield(event)
    }
}
