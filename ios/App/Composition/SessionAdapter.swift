import Combine
import EncounterBackend
import EncounterDomain
import EncounterUI
import Foundation
import Network

@MainActor
final class SessionNetworkAvailability {
    private let monitor: NWPathMonitor?
    private(set) var isOnline = true // Unknown reachability is not an offline refusal.
    var onOnline: (@MainActor () -> Void)?
    init(monitorsSystemPath: Bool = true) {
        monitor = monitorsSystemPath ? NWPathMonitor() : nil
        guard let monitor else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status != .unsatisfied
            Task { @MainActor in
                guard let self else { return }
                self.receive(isOnline: online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "EngineerEncounters.SessionNetwork"))
    }
    func receive(isOnline online: Bool) {
        let recovered = online && !isOnline
        isOnline = online
        if recovered { onOnline?() }
    }
    deinit { monitor?.cancel() }
}

/// A race that does not join an uncooperative network task after the deadline.
@MainActor
private final class SessionStopCompletion {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func finish() { continuation?.resume(); continuation = nil }
}

/// Retains precise adapter failures without expanding the package's S08 error API.
enum SessionAdapterFailure: Equatable {
    case prerequisiteMissing([String]), accountNotReady, rateLimited, offline, transport, unavailable
    var actionError: SessionActionError {
        switch self {
        case .prerequisiteMissing(let details): .prerequisiteMissing(details: details)
        case .offline: .offline
        default: .unavailable
        }
    }
}

@MainActor
final class SessionAdapter: ObservableObject {
    let holder: SessionHolder
    @Published private(set) var state: SessionState = .none
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var stopPending = false
    @Published private(set) var failure: SessionAdapterFailure?
    private let account: AccountModel
    private let isOnline: @MainActor () -> Bool
    private let clock: any EncounterClock
    private var backend: SessionBackendServices?
    private var configuredEpoch: UUID?
    private var version: UInt64 = 0
    private var read: (id: UUID, task: Task<SessionTransfer?, any Error>)?
    private var upload: (id: UUID, task: Task<Void, any Error>)?
    private var discoveryStop: SessionHolder.Stop?
    private var retry: (id: UUID, task: Task<Void, Never>)?

    init(account: AccountModel, holder: SessionHolder, clock: any EncounterClock,
         isOnline: @escaping @MainActor () -> Bool) {
        self.account = account; self.holder = holder; self.clock = clock; self.isOnline = isOnline
    }

    func configure(_ backend: SessionBackendServices?) async {
        if self.backend !== backend {
            retry?.task.cancel(); retry = nil
            read?.task.cancel(); read = nil
            upload?.task.cancel(); upload = nil
            await holder.discardRequest()
        }
        self.backend = backend
        await holder.observe { [weak self] in self?.publish($0, allowSameVersion: false) }
        if let backend {
            configuredEpoch = backend.epoch
            await holder.bind(backend.owner)
        } else if !account.state.isSignedIn || !account.hasCurrentSessionContext || configuredEpoch != account.sessionGeneration {
            configuredEpoch = nil
            await holder.bind(nil)
        }
        // Temporary storage/Keychain unavailability does not discard a same-account stop.
        // There is no service route until preparation recovers, but its non-secret marker stays.
        await update()
    }

    func invalidate() async {
        retry?.task.cancel(); retry = nil
        read?.task.cancel(); read = nil
        upload?.task.cancel(); upload = nil
        backend = nil; configuredEpoch = nil; discoveryStop = nil; failure = nil
        await holder.bind(nil)
        await update()
    }

    func actions() -> SessionActions {
        let epoch = account.sessionGeneration
        let fence = account.backendCallFence()
        return SessionActions(startSession: {
            guard fence.isCurrent() else { throw SessionActionError.unavailable }
            return try await self.start(epoch: epoch)
        }, stopSession: {
            guard fence.isCurrent() else { throw SessionActionError.unavailable }
            try await self.stop(epoch: epoch)
        }, refreshSession: {
            guard fence.isCurrent() else { throw SessionActionError.unavailable }
            return try await self.refresh(epoch: epoch)
        })
    }

    func foreground() async {
        // Foreground retries pending writes without claiming a restored session or changing
        // account restoration's existing request order. S08 explicitly loads get_own_session.
        guard let backend, backend.isCurrent, !account.sessionChangeInProgress, retry == nil else { return }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.retry?.id == id { self.retry = nil } }
            do { try await self.flushStop(backend) }
            catch { await self.handle(error, backend: backend, starting: false) }
            await self.update()
        }
        retry = (id, task)
    }

    func discoveryWillChange(enabled: Bool) async throws {
        guard let backend, backend.isCurrent else { return }
        if enabled {
            do { try await flushStop(backend) }
            catch {
                await handle(error, backend: backend, starting: false)
                if error is CancellationError { throw CancellationError() }
                throw AccountModel.presentationError(error)
            }
            return
        }
        discoveryStop = try await holder.stop(owner: backend.owner, discoveryOff: true)
        await update()
    }

    func discoveryDidChange(enabled: Bool) async {
        guard let backend, backend.isCurrent else { return }
        await holder.discoveryAcknowledged(enabled: enabled, stop: discoveryStop)
        discoveryStop = nil
        await update()
    }

    /// Seed a newly opened S08 with a current server-time estimate, rather than the
    /// last Published acknowledgement's clock anchor.
    func presentationState() async -> SessionState {
        let snapshot = await holder.snapshot()
        publish(snapshot)
        return snapshot.state
    }

    /// Runs before the credential tombstone and runtime/storage cleanup. It does not retain
    /// outgoing credentials or wait for an outstanding start/get to drain.
    func prepareToDiscardSession() async {
        guard account.hasCurrentSessionContext else { await invalidate(); return }
        guard let backend, backend.isCurrent else {
            await holder.discardPendingStops()
            await invalidate()
            return
        }
        retry?.task.cancel(); retry = nil
        upload?.task.cancel(); upload = nil
        let stop = try? await holder.stop(owner: backend.owner, force: false)
        await update()
        if stop != nil {
            let deadline = await clock.now().monotonic + 2
            var stopping: Task<Void, Never>?
            var timeout: Task<Void, Never>?
            await withCheckedContinuation { continuation in
                let completion = SessionStopCompletion(continuation)
                stopping = Task {
                    _ = try? await backend.call(outgoing: true) { try await $0.session.stopSession() }
                    completion.finish()
                }
                timeout = Task {
                    try? await self.clock.wait(until: deadline)
                    completion.finish()
                }
            }
            stopping?.cancel(); timeout?.cancel()
        }
        if backend.isCurrent { await holder.discardPendingStops() }
        await invalidate()
    }

    /// Invalid refreshes may clear credentials inside the package, including calls made
    /// by the runtime. Preserve the adapter context until its caller handles the error.
    func authorizationWillBeDiscarded() async {
        guard account.hasCurrentSessionContext,
              configuredEpoch == nil || account.sessionGeneration == configuredEpoch else { return }
        retry?.task.cancel(); retry = nil
        read?.task.cancel(); read = nil
        upload?.task.cancel(); upload = nil
        await holder.discardPendingStops()
        await update()
    }

    private func context(epoch: UUID) throws -> SessionBackendServices {
        guard epoch == account.sessionGeneration, !account.sessionChangeInProgress,
              let backend, backend.isCurrent else { throw SessionActionError.unavailable }
        return backend
    }

    private func start(epoch: UUID) async throws -> SessionAcknowledgement {
        let backend = try context(epoch: epoch)
        do {
            try await flushStop(backend)
            guard isOnline() else {
                await holder.refuseOfflineStart(owner: backend.owner)
                await update()
                throw SessionActionError.offline
            }
            let value = try await fetch(backend, starting: true)
            guard case .active(let session) = value else { throw SessionActionError.unavailable }
            return session
        } catch {
            await handle(error, backend: backend, starting: true)
            if error is CancellationError { throw CancellationError() }
            throw Self.presentationFailure(error, offline: !isOnline()).actionError
        }
    }

    private func refresh(epoch: UUID) async throws -> SessionState {
        let backend = try context(epoch: epoch)
        do {
            if await holder.needsStopCheck(owner: backend.owner) {
                _ = try await fetch(backend, starting: false)
                try await flushStop(backend)
                let state = await presentationState()
                guard backend.isCurrent else { throw SessionActionError.unavailable }
                return state
            }
            try await flushStop(backend)
            return try await fetch(backend, starting: false)
        } catch {
            await handle(error, backend: backend, starting: false)
            if error is CancellationError { throw CancellationError() }
            throw Self.presentationFailure(error, offline: false).actionError
        }
    }

    private func stop(epoch: UUID) async throws {
        let backend = try context(epoch: epoch)
        do {
            try await holder.stop(owner: backend.owner)
            await update()
            try await flushStop(backend)
        }
        catch {
            await handle(error, backend: backend, starting: false)
            if error is CancellationError { throw CancellationError() }
            throw Self.presentationFailure(error, offline: false).actionError
        }
        await update()
    }

    private func fetch(_ backend: SessionBackendServices, starting: Bool) async throws -> SessionState {
        guard read == nil else { throw SessionActionError.unavailable }
        let request = try await holder.begin(owner: backend.owner, starting: starting)
        let id = UUID()
        let task = Task {
            guard await self.holder.isCurrent(request) else { throw SessionActionError.unavailable }
            return try await backend.call { services -> SessionTransfer? in
                guard await self.holder.markSent(request) else { throw SessionActionError.unavailable }
                if starting { return try await services.session.startSession() }
                return try await services.session.getOwnSession()
            }
        }
        read = (id, task)
        defer { if read?.id == id { read = nil } }
        await update()
        do {
            let response = try await task.value
            guard backend.isCurrent else { throw SessionActionError.unavailable }
            guard try await holder.receive(response, for: request) else { throw SessionActionError.unavailable }
            failure = nil
            let snapshot = await holder.snapshot()
            publish(snapshot)
            return snapshot.state
        } catch {
            await holder.fail(request, offline: starting && !isOnline())
            await update()
            throw error
        }
    }

    private func flushStop(_ backend: SessionBackendServices) async throws {
        if await holder.needsStopCheck(owner: backend.owner) {
            _ = try await fetch(backend, starting: false)
        }
        guard let stop = try await holder.pendingStop(owner: backend.owner) else { return }
        if let upload {
            try await upload.task.value
            if self.upload?.id == upload.id { self.upload = nil }
            try await flushStop(backend)
            return
        }
        let read = read?.task
        let id = UUID()
        let task = Task {
            // A stop after an in-flight start must reach the server after that start finishes.
            _ = await read?.result
            try Task.checkCancellation()
            guard backend.isCurrent, try await self.holder.pendingStop(owner: backend.owner) == stop else { return }
            if await self.holder.needsDiscoveryOff(stop) {
                try await backend.call { try await $0.ownAccount.setDiscovery(enabled: false) }
                if var profile = self.account.profile {
                    profile.discoveryOn = false
                    self.account.publishProfile(profile, stale: true)
                }
            } else {
                _ = try await backend.call { try await $0.session.stopSession() }
            }
            try Task.checkCancellation()
            await self.holder.finish(stop)
        }
        upload = (id, task)
        defer { if upload?.id == id { upload = nil } }
        try await task.value
        await update()
        guard backend.isCurrent else { throw SessionActionError.unavailable }
        // A second stop/discovery-off request may have arrived during the upload.
        if try await holder.pendingStop(owner: backend.owner) != nil {
            if upload?.id == id { upload = nil }
            try await flushStop(backend)
        } else if self.backend === backend { failure = nil }
    }

    private func handle(_ error: any Error, backend: SessionBackendServices, starting: Bool) async {
        guard self.backend === backend, account.hasCurrentSessionContext,
              account.sessionGeneration == backend.epoch, !account.sessionChangeInProgress else { return }
        if error as? BackendError == .notAuthenticated {
            await account.rejectDeadSession(generation: backend.epoch)
            return
        }
        guard backend.isCurrent else { return }
        failure = Self.presentationFailure(error, offline: starting && !isOnline())
    }

    static func presentationFailure(_ error: any Error, offline: Bool) -> SessionAdapterFailure {
        if offline || (error as? SessionActionError) == .offline { return .offline }
        if case .prerequisiteMissing(let details) = error as? SessionActionError { return .prerequisiteMissing(details) }
        switch error as? BackendError {
        case .prerequisiteMissing(let details): return .prerequisiteMissing(details)
        case .accountNotReady: return .accountNotReady
        case .rateLimited: return .rateLimited
        case .transportFailure, .httpFailure: return .transport
        default: return .unavailable
        }
    }

    private func update() async { publish(await holder.snapshot()) }
    private func publish(_ snapshot: SessionHolder.Snapshot, allowSameVersion: Bool = true) {
        guard snapshot.version > version || (allowSameVersion && snapshot.version == version) else { return }
        version = snapshot.version
        state = snapshot.state; remainingSeconds = snapshot.remainingSeconds; stopPending = snapshot.stopPending
    }
}
