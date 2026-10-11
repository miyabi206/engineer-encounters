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
              offset > 0, offset <= snapshot.frame.count else { return nil }
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

    mutating func removeService() -> [PeerHandle] {
        let peers = openPeers
        subscriptions.removeAll()
        return peers
    }
}

struct CentralLinks {
    enum State: Equatable { case pending, ready, closing }
    private var states: [PeerHandle: State] = [:]

    func state(_ peer: PeerHandle) -> State? { states[peer] }

    mutating func begin(_ peer: PeerHandle, ready: Bool = false) {
        states[peer] = ready ? .ready : .pending
    }

    mutating func ready(_ peer: PeerHandle) -> BluetoothEvent? {
        guard states[peer] == .pending else { return nil }
        states[peer] = .ready
        return .connected(.init(peer: peer, role: .central))
    }

    // Terminal delegate callbacks and radio loss share exactly one ending rule.
    mutating func end(_ peer: PeerHandle) -> BluetoothEvent? {
        switch states.removeValue(forKey: peer) {
        case .pending: return .connectFailed(peer)
        case .ready: return .disconnected(.init(peer: peer, role: .central))
        case .closing, nil: return nil
        }
    }

    // Each command is acknowledged immediately; its later callback is silent.
    mutating func disconnect(_ peer: PeerHandle) -> BluetoothEvent {
        if states[peer] != nil { states[peer] = .closing }
        return .disconnected(.init(peer: peer, role: .central))
    }
}

/// Plain publication decisions; Core Bluetooth objects live only in the adapter.
struct Publication {
    enum Radio { case poweredOn, poweredOff, databaseCleared }
    enum Action: Equatable {
        case remove, add, startAdvertising, stopAdvertising, unavailable
        case scheduleRearm(after: TimeInterval), cancelRearm
    }

    private(set) var requested: Bool?
    private(set) var pending = false
    private(set) var published = false
    private(set) var removalPending = false
    private(set) var advertisingPending = false
    private(set) var advertising = false
    private(set) var unavailable = false
    private(set) var addRetried = false
    private(set) var advertisingRetried = false
    private var rearmPending = false
    private var radio: Radio = .databaseCleared

    mutating func request(_ requested: Bool) -> [Action] {
        self.requested = requested
        let actions: [Action]
        if requested {
            actions = recover()
        } else {
            actions = cancelRearm()
            removalPending = true
        }
        return actions + reconcile()
    }

    mutating func update(_ radio: Radio, isAdvertising: Bool = false) -> [Action] {
        // An add interrupted by power-off may never deliver its callback.
        // Forget it on power-on; reconcile still removes before the next add.
        if self.radio == .poweredOff, radio == .poweredOn { pending = false }
        self.radio = radio
        let actions = recover()
        if radio == .poweredOn {
            advertising = isAdvertising
        } else {
            advertisingPending = false
            advertising = false
        }
        // Powered off preserves the local GATT database until power-on.
        if radio == .databaseCleared {
            pending = false
            published = false
            removalPending = false
        }
        return actions + reconcile()
    }

    mutating func restorePublished() { published = true }

    mutating func didAdd(matchesUUID: Bool, success: Bool) -> [Action] {
        guard matchesUUID, pending else { return [] }
        pending = false
        if success {
            published = true
        } else if requested == true, !removalPending {
            if addRetried {
                return failPublication()
            }
            addRetried = true
        }
        return reconcile()
    }

    mutating func didStartAdvertising(success: Bool) -> [Action] {
        guard advertisingPending else {
            return requested == false && radio == .poweredOn ? [.stopAdvertising] : []
        }
        advertisingPending = false
        advertising = success
        if !success, requested == true, !removalPending {
            if advertisingRetried {
                return failPublication()
            }
            advertisingRetried = true
        }
        return reconcile()
    }

    // Called only when the adapter's scheduled re-arm fires on its private queue.
    mutating func rearm() -> [Action] {
        guard rearmPending, requested == true, radio == .poweredOn else { return [] }
        rearmPending = false
        return recover() + reconcile()
    }

    private mutating func failPublication() -> [Action] {
        unavailable = true
        guard !rearmPending else { return [.unavailable] }
        rearmPending = true
        return [.unavailable, .scheduleRearm(after: 30)]
    }

    private mutating func cancelRearm() -> [Action] {
        guard rearmPending else { return [] }
        rearmPending = false
        return [.cancelRearm]
    }

    private mutating func recover() -> [Action] {
        unavailable = false
        addRetried = false
        advertisingRetried = false
        return cancelRearm()
    }

    private mutating func reconcile() -> [Action] {
        guard radio == .poweredOn else { return [] }
        var actions: [Action] = []
        if removalPending {
            advertising = false
            advertisingPending = false
            actions.append(.stopAdvertising)
            published = false
            actions.append(.remove)
            // Remove immediately, but wait for didAdd before starting another add.
            // Its callback removes again if the old add completed after removal.
            guard !pending else { return actions }
            removalPending = false
        }
        guard requested == true, !unavailable else { return actions }
        if !published, !pending {
            pending = true
            // Always clear the database before adding, even after an add failure.
            if actions.last != .remove { actions.append(.remove) }
            actions.append(.add)
        } else if published, !advertisingPending, !advertising {
            advertisingPending = true
            actions.append(.startAdvertising)
        }
        return actions
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
