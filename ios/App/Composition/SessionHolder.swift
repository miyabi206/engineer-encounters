import EncounterBackend
import EncounterDomain
import EncounterUI
import Foundation

/// Runtime-readable policy. Only salted owner markers, never credentials or account IDs,
/// are retained here. Unacknowledged stops survive the process in bound non-secret storage.
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
        let sentAt: EncounterTime
    }
    struct Stop: Equatable, Sendable {
        let owner: BackendStorageOwner
        let id: UUID
    }
    private let clock: any EncounterClock
    private let stops: PendingSessionStopStore
    private var suppressed: PendingSessionStopStore.Marker?
    private var markerNeedsSaving = false
    private var suppressionDeadline: TimeInterval = 0
    private var acknowledgedWall = Date.distantPast
    private var lastMonotonic: TimeInterval = 0
    private var stoppedRequest: Request?
    private var owner: BackendStorageOwner?
    private var loadingStop = false
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
    private var stopExpiry: Task<Void, Never>?
    private var observer: (@MainActor @Sendable (Snapshot) -> Void)?

    init(clock: any EncounterClock, stops: PendingSessionStopStore) {
        self.clock = clock; self.stops = stops
    }

    func observe(_ observer: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        self.observer = observer
    }

    func bind(_ owner: BackendStorageOwner?) async {
        guard self.owner != owner || loadingStop else { return }
        self.owner = owner
        stopExpiry?.cancel(); stopExpiry = nil
        loadingStop = owner != nil
        suppressed = nil; markerNeedsSaving = false; stoppedRequest = nil
        request = nil; pending = nil; discoveryOffPending = false; discoveryOff = false
        clear()
        state = .none
        changed()
        guard let owner else { return }
        let marker: PendingSessionStopStore.Marker?
        do { marker = try await stops.load(owner: owner) }
        catch { return } // Unknown durable state cannot authorize a fresh active claim.
        let time = await clock.now()
        guard self.owner == owner else { return }
        lastMonotonic = time.monotonic
        loadingStop = false
        if let marker {
            if marker.expiresAt <= time.wall { await stops.remove(marker, owner: owner) }
            else {
                suppressed = marker
                suppressionDeadline = time.monotonic + marker.expiresAt.timeIntervalSince(time.wall)
                pending = Stop(owner: owner, id: UUID())
                state = .stopping
                scheduleStopExpiry(owner: owner)
                changed()
            }
        }
    }

    func begin(owner: BackendStorageOwner, starting: Bool) async throws -> Request {
        let time = await clock.now()
        await expire(at: time.monotonic)
        lastMonotonic = time.monotonic
        guard self.owner == owner else { throw BackendError.notAuthenticated }
        guard !loadingStop, pending == nil else { throw BackendError.transportFailure }
        guard !discoveryOff else { throw BackendError.prerequisiteMissing(fields: ["discovery"]) }
        let request = Request(owner: owner, id: UUID(), sentAt: time)
        self.request = request
        if starting, acknowledgement == nil { state = .starting; changed() }
        return request
    }

    @discardableResult
    func receive(_ value: SessionTransfer?, for request: Request) async throws -> Bool {
        let time = await clock.now()
        let sentAt = (self.request?.id == request.id ? self.request : stoppedRequest)?.sentAt ?? request.sentAt
        lastMonotonic = time.monotonic
        // A locally stopped in-flight start can first reveal its ID here. Persist it
        // without ever accepting the obsolete answer as an active acknowledgement.
        if owner == request.owner, stoppedRequest?.id == request.id, pending != nil, let value {
            stoppedRequest = nil
            try await suppress(value, sentAt: sentAt, owner: request.owner)
            return false
        }
        await expire(at: time.monotonic)
        guard owner == request.owner, self.request?.id == request.id,
              pending == nil, !discoveryOff else { return false }
        self.request = nil
        clear()
        state = .none
        if let value, value.sessionID != suppressed?.sessionID,
           value.startsAt.date <= value.serverTime.date,
           sentAt.monotonic + value.expiresAt.date.timeIntervalSince(value.serverTime.date) > time.monotonic {
            acknowledgement = SessionAcknowledgement(sessionID: value.sessionID.uuidString.lowercased(),
                startsAt: value.startsAt.date, expiresAt: value.expiresAt.date, serverTime: value.serverTime.date)
            acknowledgedAt = sentAt.monotonic
            acknowledgedWall = sentAt.wall
            deadline = sentAt.monotonic + value.expiresAt.date.timeIntervalSince(value.serverTime.date)
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

    func markSent(_ request: Request) async -> Bool {
        let time = await clock.now()
        guard isCurrent(request) else { return false }
        self.request = Request(owner: request.owner, id: request.id, sentAt: time)
        return true
    }

    func discardRequest() {
        request = nil
        if state == .starting { state = .none; changed() }
    }

    @discardableResult
    func stop(owner: BackendStorageOwner, discoveryOff: Bool = false, force: Bool = true) async throws -> Stop? {
        let time = await clock.now()
        lastMonotonic = time.monotonic
        await expire(at: time.monotonic)
        guard self.owner == owner else { return nil }
        let needed = force || acknowledgement != nil || request != nil || pending != nil
        stoppedRequest = request ?? stoppedRequest
        request = nil
        let acknowledgement = acknowledgement
        let marker = acknowledgement.flatMap { value in
            UUID(uuidString: value.sessionID).map {
                PendingSessionStopStore.Marker(sessionID: $0,
                    expiresAt: acknowledgedWall.addingTimeInterval(value.expiresAt.timeIntervalSince(value.serverTime)))
            }
        }
        clear()
        if discoveryOff { self.discoveryOff = true; discoveryOffPending = true }
        if needed || discoveryOff { pending = Stop(owner: owner, id: UUID()) }
        state = pending == nil ? .none : .stopping
        changed()
        if let marker {
            suppressed = marker
            suppressionDeadline = deadline
            scheduleStopExpiry(owner: owner)
            markerNeedsSaving = true
            try await persistMarker(owner: owner)
        }
        return pending
    }

    func pendingStop(owner: BackendStorageOwner) async throws -> Stop? {
        let time = await clock.now()
        await expire(at: time.monotonic)
        guard self.owner == owner else { return nil }
        try await persistMarker(owner: owner)
        return pending
    }

    func discardPendingStops() async {
        stopExpiry?.cancel(); stopExpiry = nil
        request = nil; stoppedRequest = nil; suppressed = nil; markerNeedsSaving = false; pending = nil
        discoveryOffPending = false
        clear(); state = .none; changed()
        await stops.clear()
    }
    func needsDiscoveryOff(_ stop: Stop) -> Bool { pending == stop && discoveryOffPending }

    func finish(_ stop: Stop) async {
        guard pending == stop, owner == stop.owner else { return }
        pending = nil; stoppedRequest = nil; markerNeedsSaving = false; discoveryOffPending = false; state = .none
        changed()
        if let suppressed { await stops.remove(suppressed, owner: stop.owner) }
    }

    func discoveryAcknowledged(enabled: Bool, stop: Stop?) async {
        if enabled {
            // Do not release an unsent discovery-off request by accepting an overlapping enable.
            if !discoveryOffPending { discoveryOff = false }
        } else if let stop { await finish(stop) }
    }

    func snapshot() async -> Snapshot {
        let time = await clock.now()
        await expire(at: time.monotonic)
        return snapshot(at: time.monotonic)
    }

    func isActive() async -> Bool {
        let time = await clock.now()
        await expire(at: time.monotonic)
        return acknowledgement != nil && pending == nil
    }

    func isActive(owner: BackendStorageOwner) async -> Bool {
        let time = await clock.now()
        await expire(at: time.monotonic)
        return self.owner == owner && acknowledgement != nil && pending == nil
    }

    private func expire(request: Request) async {
        guard owner == request.owner else { return }
        let time = await clock.now()
        await expire(at: time.monotonic)
    }

    private func expire(at time: TimeInterval) async {
        lastMonotonic = time
        if let suppressed, time >= suppressionDeadline, let owner {
            self.suppressed = nil; markerNeedsSaving = false
            stopExpiry?.cancel(); stopExpiry = nil
            if !discoveryOffPending, pending != nil { pending = nil; stoppedRequest = nil; state = .none }
            changed()
            await stops.remove(suppressed, owner: owner)
        }
        guard acknowledgement != nil, time >= deadline else { return }
        clear(); state = .none; changed()
    }

    private func suppress(_ value: SessionTransfer, sentAt: EncounterTime, owner: BackendStorageOwner) async throws {
        let deadline = sentAt.monotonic + value.expiresAt.date.timeIntervalSince(value.serverTime.date)
        guard deadline > lastMonotonic else { return }
        let marker = PendingSessionStopStore.Marker(sessionID: value.sessionID,
            expiresAt: sentAt.wall.addingTimeInterval(value.expiresAt.date.timeIntervalSince(value.serverTime.date)))
        suppressed = marker; suppressionDeadline = deadline
        scheduleStopExpiry(owner: owner)
        markerNeedsSaving = true
        try await persistMarker(owner: owner)
    }

    private func persistMarker(owner: BackendStorageOwner) async throws {
        guard markerNeedsSaving, self.owner == owner, let marker = suppressed else { return }
        try await stops.save(marker, owner: owner)
        if self.owner == owner, suppressed == marker { markerNeedsSaving = false }
    }

    private func scheduleStopExpiry(owner: BackendStorageOwner) {
        stopExpiry?.cancel()
        let clock = clock
        let deadline = suppressionDeadline
        stopExpiry = Task { [weak self] in
            do {
                try await clock.wait(until: deadline)
                guard !Task.isCancelled else { return }
                await self?.expireStop(owner: owner)
            } catch { /* Discarding or replacing the marker cancels this timer. */ }
        }
    }

    private func expireStop(owner: BackendStorageOwner) async {
        guard self.owner == owner else { return }
        let time = await clock.now()
        await expire(at: time.monotonic)
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
        let snapshot = snapshot(at: lastMonotonic)
        if let observer { Task { @MainActor in observer(snapshot) } }
    }
}
