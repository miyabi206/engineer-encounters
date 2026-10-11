import Foundation
import EncounterDomain

/// Admission is decided before recording any state for an untrusted peer.
enum RadioAdmission {
    static let eventLimit = 256
    static let peripheralLimit = 16
    static let centralLimit = 256
    static let fragmentLimit = 8

    enum EventKind { case observation, subscription, admittedWork }

    static func permits(_ kind: EventKind, backlogCount: Int, openLinkCount: Int = 0) -> Bool {
        switch kind {
        case .observation: backlogCount < eventLimit
        case .subscription: backlogCount < eventLimit && openLinkCount < peripheralLimit
        case .admittedWork: true
        }
    }

    static func canTrackCentral(links: Int, cancellations: Int) -> Bool {
        links + cancellations < centralLimit
    }
}

/// The stream pulls directly from this FIFO; AsyncStream has no second buffer.
/// At the limit, peer-driven growth is only the admitted links' outstanding
/// operations and terminal events: two requests and one ending per peripheral,
/// and readiness, two operation results and one ending per central. Radio and
/// restoration events, and outcomes of engine commands, remain unconditional.
struct EventBacklog {
    private var events: [BluetoothEvent] = []
    var count: Int { events.count }

    @discardableResult
    mutating func append(_ event: BluetoothEvent) -> Bool {
        let kind: RadioAdmission.EventKind
        if case .peerObserved = event { kind = .observation } else { kind = .admittedWork }
        guard RadioAdmission.permits(kind, backlogCount: count) else { return false }
        events.append(event)
        return true
    }

    mutating func next() -> BluetoothEvent? {
        events.isEmpty ? nil : events.removeFirst()
    }
}

/// One unanswered request of each kind per admitted peripheral link (16 total).
struct PeripheralRequests {
    private var requests: [PeerHandle: BluetoothRequestID] = [:]
    var count: Int { requests.count }
    func contains(_ peer: PeerHandle) -> Bool { requests[peer] != nil }

    mutating func begin(_ peer: PeerHandle, request: BluetoothRequestID) -> Bool {
        guard !contains(peer), count < RadioAdmission.peripheralLimit else { return false }
        requests[peer] = request
        return true
    }

    mutating func finish(_ peer: PeerHandle, request: BluetoothRequestID) -> Bool {
        guard requests[peer] == request else { return false }
        requests.removeValue(forKey: peer)
        return true
    }

    mutating func drop(_ peer: PeerHandle) { requests.removeValue(forKey: peer) }
}

struct WriteFragment: Sendable {
    let characteristic: String
    let offset: Int
    let value: Data?
}

enum WriteAssemblyError: Error, Equatable {
    case wrongCharacteristic, missingValue, emptyValue, tooManyFragments, gap, overlap, overflow
}

enum WriteAssembler {
    // Check count first, then at most eight values, before mapping or sorting.
    static func validateBatch<Element>(_ requests: [Element], value: (Element) -> Data?) throws {
        guard requests.count <= RadioAdmission.fragmentLimit else { throw WriteAssemblyError.tooManyFragments }
        for request in requests {
            guard let bytes = value(request) else { throw WriteAssemblyError.missingValue }
            guard !bytes.isEmpty else { throw WriteAssemblyError.emptyValue }
        }
    }

    // One callback is one atomic write; no bytes survive into another callback.
    static func assemble(_ fragments: [WriteFragment]) throws -> Data {
        try validateBatch(fragments, value: { $0.value })
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
    private var pending = PeripheralRequests()
    // Pending requests and cached snapshots together contain at most 16 peers.
    private var snapshots: [PeerHandle: BluetoothReadSnapshot] = [:]

    @discardableResult
    mutating func begin(_ peer: PeerHandle, request: BluetoothRequestID) -> Bool {
        guard snapshots[peer] != nil || snapshots.count + pending.count < RadioAdmission.peripheralLimit,
              pending.begin(peer, request: request) else { return false }
        snapshots.removeValue(forKey: peer)
        return true
    }

    mutating func answer(_ peer: PeerHandle, request: BluetoothRequestID,
                         snapshot: BluetoothReadSnapshot?, now: Date) -> Data? {
        guard pending.finish(peer, request: request) else { return nil }
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
        pending.drop(peer)
        snapshots.removeValue(forKey: peer)
    }
}

struct PeripheralLinks {
    private enum State { case open, closed }
    // Closed subscriptions retain their slot until unsubscribe/service removal.
    // Bounding open and closed together avoids an unbounded tombstone table.
    private var subscriptions: [PeerHandle: State] = [:]

    var openPeers: [PeerHandle] { subscriptions.compactMap { $0.value == .open ? $0.key : nil } }
    var count: Int { subscriptions.count }
    func acceptsRequests(_ peer: PeerHandle) -> Bool { subscriptions[peer] == .open }

    // Repeated subscription callbacks cannot reopen a logically closed link.
    mutating func subscribe(_ peer: PeerHandle, backlogCount: Int = 0) -> Bool {
        guard subscriptions[peer] == nil, count < RadioAdmission.peripheralLimit,
              RadioAdmission.permits(.subscription, backlogCount: backlogCount, openLinkCount: openPeers.count)
        else { return false }
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

    mutating func observe(_ peer: PeerHandle, now: TimeInterval, backlogCount: Int = 0) -> Observation? {
        // A refused observation neither occupies a registry slot nor starts its throttle.
        guard RadioAdmission.permits(.observation, backlogCount: backlogCount) else { return nil }
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
