import Foundation
import EncounterDomain

struct WriteFragment: Sendable {
    let characteristic: String
    let offset: Int
    let value: Data?
}

enum WriteAssemblyError: Error, Equatable {
    case wrongCharacteristic, missingValue, gap, overlap, overflow
}

enum WriteAssembler {
    // One callback is one atomic write; no bytes survive into another callback.
    static func assemble(_ fragments: [WriteFragment]) throws -> Data {
        var frame = Data()
        for fragment in fragments.sorted(by: { $0.offset < $1.offset }) {
            guard fragment.characteristic == EncounterProtocol.centralTokenCharacteristicUUID else {
                throw WriteAssemblyError.wrongCharacteristic
            }
            guard let value = fragment.value else { throw WriteAssemblyError.missingValue }
            guard fragment.offset >= frame.count else { throw WriteAssemblyError.overlap }
            guard fragment.offset == frame.count else { throw WriteAssemblyError.gap }
            guard value.count <= EncounterProtocol.maximumFrameByteCount - frame.count else {
                throw WriteAssemblyError.overflow
            }
            frame.append(value)
        }
        return frame
    }
}

struct ReadSnapshots {
    private var pending: [PeerHandle: BluetoothRequestID] = [:]
    private var snapshots: [PeerHandle: BluetoothReadSnapshot] = [:]

    mutating func begin(_ peer: PeerHandle, request: BluetoothRequestID) {
        snapshots.removeValue(forKey: peer)
        pending[peer] = request
    }

    mutating func answer(_ peer: PeerHandle, request: BluetoothRequestID,
                         snapshot: BluetoothReadSnapshot?, now: Date) -> Data? {
        guard pending[peer] == request else { return nil }
        pending.removeValue(forKey: peer)
        guard let snapshot, now < snapshot.validUntil,
              snapshot.frame.count <= EncounterProtocol.maximumFrameByteCount else { return nil }
        snapshots[peer] = snapshot
        return snapshot.frame
    }

    func continuation(_ peer: PeerHandle, offset: Int, now: Date) -> Data? {
        guard let snapshot = snapshots[peer], now < snapshot.validUntil,
              offset > 0, offset < snapshot.frame.count else { return nil }
        return Data(snapshot.frame.dropFirst(offset))
    }

    mutating func drop(_ peer: PeerHandle) {
        pending.removeValue(forKey: peer)
        snapshots.removeValue(forKey: peer)
    }
}

struct PeripheralLinks {
    private enum State { case open, closed }
    private var subscriptions: [PeerHandle: State] = [:]

    var openPeers: [PeerHandle] { subscriptions.compactMap { $0.value == .open ? $0.key : nil } }
    func acceptsRequests(_ peer: PeerHandle) -> Bool { subscriptions[peer] == .open }

    // Repeated subscription callbacks cannot reopen a logically closed link.
    mutating func subscribe(_ peer: PeerHandle) -> Bool {
        guard subscriptions[peer] == nil else { return false }
        subscriptions[peer] = .open
        return true
    }

    mutating func unsubscribe(_ peer: PeerHandle) -> Bool {
        subscriptions.removeValue(forKey: peer) == .open
    }

    mutating func close(_ peer: PeerHandle) -> Bool {
        guard subscriptions[peer] == .open else { return false }
        subscriptions[peer] = .closed
        return true
    }
}

struct CentralLinks {
    private var live: Set<PeerHandle> = []

    mutating func begin(_ peer: PeerHandle) { live.insert(peer) }
    mutating func end(_ peer: PeerHandle) -> Bool { live.remove(peer) != nil }

    // A command is acknowledged even if no live or pending link remains.
    mutating func disconnect(_ peer: PeerHandle) -> BluetoothEvent {
        live.remove(peer)
        return .disconnected(.init(peer: peer, role: .central))
    }
}

struct ObservationRegistry {
    struct Observation {
        let evicted: PeerHandle?
        let shouldEmit: Bool
    }
    private var order: [PeerHandle] = []
    private var lastEmitted: [PeerHandle: TimeInterval] = [:]
    let capacity: Int
    private let interval: TimeInterval = 2

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func observe(_ peer: PeerHandle, now: TimeInterval) -> Observation? {
        var evicted: PeerHandle?
        if !order.contains(peer), order.count == capacity {
            // Keep recent observations so eviction cannot bypass the throttle.
            guard let index = order.firstIndex(where: { now - (lastEmitted[$0] ?? -.infinity) >= interval }) else {
                return nil
            }
            evicted = order.remove(at: index)
            lastEmitted.removeValue(forKey: evicted!)
        }
        order.removeAll { $0 == peer }
        order.append(peer)
        let shouldEmit = now - (lastEmitted[peer] ?? -.infinity) >= interval
        if shouldEmit { lastEmitted[peer] = now }
        return Observation(evicted: evicted, shouldEmit: shouldEmit)
    }
}

enum ManagerRadioState { case unknown, poweredOn, unauthorized, unavailable }

struct CombinedRadio {
    var central: ManagerRadioState = .unknown
    var peripheral: ManagerRadioState = .unknown
    private(set) var availability: RadioAvailability = .unknown

    mutating func update() -> RadioAvailability? {
        let next: RadioAvailability
        if central == .unauthorized || peripheral == .unauthorized { next = .unauthorized }
        else if central == .unavailable || peripheral == .unavailable { next = .unavailable }
        else if central == .poweredOn && peripheral == .poweredOn { next = .available }
        else { next = .unknown }
        guard next != availability else { return nil }
        availability = next
        return next
    }
}
