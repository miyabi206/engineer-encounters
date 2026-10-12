import EncounterBackend
import EncounterDomain
import EncounterUI
import Foundation

/// Runtime-readable policy. Only salted owner markers, never credentials or account IDs,
/// are retained here. Stops are intentionally in memory; abandoned server rows expire.
actor SessionHolder {
    struct Snapshot: Sendable {
        let version: UInt64
        let state: SessionState
        let remainingSeconds: Int
        let stopPending: Bool
        let discoveryOffPending: Bool
    }
    struct Request: Sendable {
        let owner: BackendStorageOwner
        let id: UUID
    }
    struct Stop: Equatable, Sendable {
        let owner: BackendStorageOwner
        let id: UUID
    }
    private let clock: any EncounterClock
    private var owner: BackendStorageOwner?
    private var request: Request?
    private var acknowledgement: SessionAcknowledgement?
    private var acknowledgedAt: TimeInterval = 0
    private var deadline: TimeInterval = 0
    private var state: SessionState = .none
    private var pending: Stop?
    private var discoveryOffPending = false
    private var discoveryOff = false
    private var version: UInt64 = 0
    private var expiry: Task<Void, Never>?
    private var observer: (@MainActor @Sendable (Snapshot) -> Void)?

    init(clock: any EncounterClock) { self.clock = clock }

    func observe(_ observer: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        self.observer = observer
    }

    func bind(_ owner: BackendStorageOwner?) {
        guard self.owner != owner else { return }
        self.owner = owner
        request = nil; pending = nil; discoveryOffPending = false; discoveryOff = false
        clear()
        state = .none
        changed()
    }

    func begin(owner: BackendStorageOwner, starting: Bool) throws -> Request {
        guard self.owner == owner else { throw BackendError.notAuthenticated }
        guard pending == nil else { throw BackendError.transportFailure }
        guard !discoveryOff else { throw BackendError.prerequisiteMissing(fields: ["discovery"]) }
        let request = Request(owner: owner, id: UUID())
        self.request = request
        if starting, acknowledgement == nil { state = .starting; changed() }
        return request
    }

    @discardableResult
    func receive(_ value: SessionTransfer?, for request: Request) async -> Bool {
        let time = await clock.now()
        guard owner == request.owner, self.request?.id == request.id,
              pending == nil, !discoveryOff else { return false }
        self.request = nil
        clear()
        state = .none
        if let value, value.startsAt.date <= value.serverTime.date,
           value.expiresAt.date > value.serverTime.date {
            acknowledgement = SessionAcknowledgement(sessionID: value.sessionID.uuidString.lowercased(),
                startsAt: value.startsAt.date, expiresAt: value.expiresAt.date, serverTime: value.serverTime.date)
            acknowledgedAt = time.monotonic
            deadline = time.monotonic + value.expiresAt.date.timeIntervalSince(value.serverTime.date)
            state = .active(acknowledgement!)
            let clock = clock
            let deadline = deadline
            expiry = Task { [weak self] in
                do {
                    try await clock.wait(until: deadline)
                    guard !Task.isCancelled else { return }
                    await self?.expire(request: request)
                } catch { /* Rebinding or stopping cancels the local timer. */ }
            }
        }
        changed()
        return true
    }

    func fail(_ request: Request, offline: Bool) {
        guard owner == request.owner, self.request?.id == request.id, pending == nil else { return }
        self.request = nil
        if acknowledgement == nil { state = offline ? .startRefusedOffline : .failed; changed() }
    }

    func refuseOfflineStart(owner: BackendStorageOwner) {
        guard self.owner == owner, pending == nil, acknowledgement == nil else { return }
        state = .startRefusedOffline
        changed()
    }

    func isCurrent(_ request: Request) -> Bool {
        owner == request.owner && self.request?.id == request.id && pending == nil && !discoveryOff
    }

    func discardRequest() {
        request = nil
        if state == .starting { state = .none; changed() }
    }

    @discardableResult
    func stop(owner: BackendStorageOwner, discoveryOff: Bool = false, force: Bool = true) -> Stop? {
        guard self.owner == owner else { return nil }
        let needed = force || acknowledgement != nil || request != nil || pending != nil
        request = nil
        clear()
        if discoveryOff { self.discoveryOff = true; discoveryOffPending = true }
        if needed || discoveryOff { pending = Stop(owner: owner, id: UUID()) }
        state = pending == nil ? .none : .stopping
        changed()
        return pending
    }

    func pendingStop(owner: BackendStorageOwner) -> Stop? { pending?.owner == owner ? pending : nil }
    func stopForAuthorizationLoss() -> Stop? {
        guard let owner else { return nil }
        return stop(owner: owner, force: false)
    }
    func needsDiscoveryOff(_ stop: Stop) -> Bool { pending == stop && discoveryOffPending }

    func finish(_ stop: Stop) {
        guard pending == stop, owner == stop.owner else { return }
        pending = nil; discoveryOffPending = false; state = .none
        changed()
    }

    func discoveryAcknowledged(enabled: Bool, stop: Stop?) {
        if enabled {
            // Do not release an unsent discovery-off request by accepting an overlapping enable.
            if !discoveryOffPending { discoveryOff = false }
        } else if let stop { finish(stop) }
    }

    func snapshot() async -> Snapshot {
        let time = await clock.now()
        expire(at: time.monotonic)
        return snapshot(at: time.monotonic)
    }

    func isActive() async -> Bool {
        let time = await clock.now()
        expire(at: time.monotonic)
        return acknowledgement != nil && pending == nil
    }

    func isActive(owner: BackendStorageOwner) async -> Bool {
        let time = await clock.now()
        expire(at: time.monotonic)
        return self.owner == owner && acknowledgement != nil && pending == nil
    }

    private func expire(request: Request) async {
        guard owner == request.owner else { return }
        let time = await clock.now()
        expire(at: time.monotonic)
    }

    private func expire(at time: TimeInterval) {
        guard acknowledgement != nil, time >= deadline else { return }
        clear(); state = .none; changed()
    }

    private func clear() {
        acknowledgement = nil
        expiry?.cancel(); expiry = nil
    }

    private func snapshot(at time: TimeInterval) -> Snapshot {
        var state = state
        var remaining = 0
        if let acknowledgement {
            let serverTime = acknowledgement.serverTime.addingTimeInterval(max(0, time - acknowledgedAt))
            state = .active(SessionAcknowledgement(sessionID: acknowledgement.sessionID,
                startsAt: acknowledgement.startsAt, expiresAt: acknowledgement.expiresAt, serverTime: serverTime))
            remaining = SessionCountdown.seconds(until: acknowledgement.expiresAt, now: serverTime)
        }
        return Snapshot(version: version, state: state, remainingSeconds: remaining,
                        stopPending: pending != nil, discoveryOffPending: discoveryOffPending)
    }

    private func changed() {
        version += 1
        let snapshot = snapshot(at: acknowledgedAt)
        if let observer { Task { @MainActor in observer(snapshot) } }
    }
}
