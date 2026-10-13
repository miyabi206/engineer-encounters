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
    case prerequisiteMissing([String]), accountNotReady, declarationRequired, rateLimited, offline, transport, unavailable
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
    @Published private(set) var controlStartFailure: SessionAdapterFailure?
    @Published private(set) var controlStartInProgress = false
    private(set) var controlNeedsAccountRefresh = false
    private let activities: SessionActivityCoordinator
    private let account: AccountModel
    private let isOnline: @MainActor () -> Bool
    private let clock: any EncounterClock
    private let cancellationScheduler: any SessionCancellationScheduling
    private var cancellationPoll: (id: UUID, job: any ReceiptUploadCancellation)?
    private var backend: SessionBackendServices?
    private var configuredEpoch: UUID?
    private var configuredOwner: BackendStorageOwner?
    private var configuredFence: BackendCallFence?
    private var version: UInt64 = 0
    private var read: (id: UUID, task: Task<SessionState, any Error>)?
    private var upload: (id: UUID, task: Task<Void, any Error>)?
    private var discoveryStop: SessionHolder.Stop?
    private var retry: (id: UUID, task: Task<Void, Never>)?

    init(account: AccountModel, holder: SessionHolder, clock: any EncounterClock,
         isOnline: @escaping @MainActor () -> Bool, activities: SessionActivityCoordinator? = nil,
         cancellationScheduler: (any SessionCancellationScheduling)? = nil) {
        self.account = account; self.holder = holder; self.clock = clock; self.isOnline = isOnline
        self.activities = activities ?? SessionActivityCoordinator(controller: NoSessionActivityController())
        self.cancellationScheduler = cancellationScheduler ?? ClockSessionCancellationScheduler(clock: clock)
    }

    func configure(_ backend: SessionBackendServices?) async {
        if self.backend !== backend {
            cancellationPoll?.job.cancel(); cancellationPoll = nil
            retry?.task.cancel(); retry = nil
            read?.task.cancel(); read = nil
            upload?.task.cancel(); upload = nil
            await holder.discardRequest()
        }
        self.backend = backend
        await holder.observe { [weak self] in self?.publish($0, allowSameVersion: false) }
        if let backend {
            configuredEpoch = backend.epoch
            configuredOwner = backend.owner
            configuredFence = account.backendCallFence()
            await holder.bind(backend.owner)
        } else if !account.state.isSignedIn || !account.hasCurrentSessionContext || configuredEpoch != account.sessionGeneration {
            configuredEpoch = nil; configuredOwner = nil; configuredFence = nil
            await holder.bind(nil)
        }
        // Temporary storage/Keychain unavailability does not discard a same-account stop.
        // There is no service route until preparation recovers, but its non-secret marker stays.
        await update()
    }

    func invalidate() async {
        cancellationPoll?.job.cancel(); cancellationPoll = nil
        retry?.task.cancel(); retry = nil
        read?.task.cancel(); read = nil
        upload?.task.cancel(); upload = nil
        backend = nil; configuredEpoch = nil; configuredOwner = nil; configuredFence = nil; discoveryStop = nil; failure = nil; controlStartFailure = nil; controlNeedsAccountRefresh = false
        await holder.bind(nil)
        await update()
    }

    func refuseControlStart() { controlStartFailure = .unavailable; controlNeedsAccountRefresh = true }

    func startFromControl() async {
        guard !controlStartInProgress, !account.deletionSuspended else { return }
        controlStartInProgress = true
        controlNeedsAccountRefresh = false
        defer { controlStartInProgress = false }
        let epoch = account.sessionGeneration, fence = account.backendCallFence()
        let state = await presentationState()
        guard fence.isCurrent(), epoch == account.sessionGeneration, !account.deletionSuspended else { return }
        if case .active = state { controlStartFailure = nil; return }
        do {
            let actions = actions()
            if isOnline() {
                let current = try await actions.refreshSession()
                if case .active = current {
                    if fence.isCurrent(), epoch == account.sessionGeneration { controlStartFailure = nil }
                    return
                }
            }
            _ = try await actions.startSession()
            if fence.isCurrent(), epoch == account.sessionGeneration { controlStartFailure = nil }
        } catch {
            if fence.isCurrent(), epoch == account.sessionGeneration, !account.deletionSuspended {
                controlStartFailure = Self.presentationFailure(error, offline: !isOnline())
            }
        }
    }

    func refreshActivity() async {
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
        await update()
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
        cancellationPoll?.job.cancel(); cancellationPoll = nil
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
                    do {
                        if await self.holder.needsStopCheck(owner: backend.owner) {
                            _ = try await self.fetch(backend, starting: false, outgoing: true)
                        }
                        if let pending = try await self.holder.pendingStop(owner: backend.owner) {
                            let quarantined = await self.holder.needsCancellationPoll(owner: backend.owner)
                            let authorized = await self.holder.canUploadStop(pending)
                            if !quarantined || authorized {
                                try Task.checkCancellation()
                                _ = try await backend.call(outgoing: true) { try await $0.session.stopSession() }
                            }
                        }
                    } catch { /* The bounded outgoing attempt never owns a later retry. */ }
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
        cancellationPoll?.job.cancel(); cancellationPoll = nil
        retry?.task.cancel(); retry = nil
        // Keep the read alive until its caller observes the rejected credential
        // refresh. Cancelling the start race here would replace notAuthenticated
        // with CancellationError before that caller can sign out every adapter.
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
        if backend == nil {
            // A temporary service/Keychain outage cannot keep a known local session
            // active. Retain only the bound non-secret stop marker for later recovery.
            guard epoch == account.sessionGeneration, configuredEpoch == epoch,
                  !account.sessionChangeInProgress, !account.deletionSuspended,
                  configuredFence?.isCurrent() == true, let owner = configuredOwner else {
                throw SessionActionError.unavailable
            }
            do { try await holder.stop(owner: owner) }
            catch { await update(); throw SessionActionError.unavailable }
            await update()
            throw SessionActionError.unavailable // Local stop succeeded; upload is queued.
        }
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

    private func fetch(_ backend: SessionBackendServices, starting: Bool, outgoing: Bool = false) async throws -> SessionState {
        guard read == nil else { throw SessionActionError.unavailable }
        let request = try await holder.begin(owner: backend.owner, starting: starting)
        let id = UUID()
        let task = Task {
            do {
                guard await self.holder.isCurrent(request) else { throw SessionActionError.unavailable }
                let operation: @MainActor () async throws -> SessionTransfer? = {
                    try await backend.call(outgoing: outgoing) { services in
                        try Task.checkCancellation()
                        guard await self.holder.markSent(request) else { throw SessionActionError.unavailable }
                        if starting { return try await services.session.startSession() }
                        return try await services.session.getOwnSession()
                    }
                }
                let response: SessionTransfer?
                if starting { response = try await self.startWithTimeout(operation) }
                else { response = try await operation() }
                guard backend.isCurrent else { throw SessionActionError.unavailable }
                guard try await self.holder.receive(response, for: request, acceptingActive: !outgoing) else {
                    throw SessionActionError.unavailable
                }
                return await self.holder.snapshot().state
            } catch {
                await self.holder.fail(request, offline: starting && !self.isOnline(),
                    definiteStartFailure: starting && Self.isDefiniteStartFailure(error))
                throw error
            }
        }
        read = (id, task)
        defer { if read?.id == id { read = nil } }
        await update()
        do {
            let state = try await task.value
            guard backend.isCurrent else { throw SessionActionError.unavailable }
            failure = nil
            await update()
            return state
        } catch {
            await update()
            throw error
        }
    }

    private func startWithTimeout(_ operation: @escaping @MainActor () async throws -> SessionTransfer?) async throws -> SessionTransfer? {
        let deadline = await clock.now().monotonic + SessionCancellationPolicy.startRequestTimeout
        let completion = SessionStartCompletion()
        var network: Task<Void, Never>?
        var timer: Task<Void, Never>?
        defer { network?.cancel(); timer?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                network = Task {
                    do { completion.finish(.success(try await operation())) }
                    catch { completion.finish(.failure(error)) }
                }
                timer = Task {
                    do {
                        try await self.clock.wait(until: deadline)
                        try Task.checkCancellation()
                        completion.finish(.failure(BackendError.transportFailure))
                    } catch { /* A completed or cancelled request stops its timer. */ }
                }
            }
        } onCancel: {
            Task { @MainActor in completion.finish(.failure(CancellationError())) }
        }
    }

    private static func isDefiniteStartFailure(_ error: any Error) -> Bool {
        switch error as? BackendError {
        case .notAuthenticated, .accountNotReady, .declarationRequired, .invalidInput,
             .prerequisiteMissing, .rateLimited, .notFound: true
        default: false
        }
    }

    private func flushStop(_ backend: SessionBackendServices) async throws {
        if read == nil, await holder.needsStopCheck(owner: backend.owner) {
            _ = try await fetch(backend, starting: false)
        }
        guard let stop = try await holder.pendingStop(owner: backend.owner) else { return }
        if read == nil, !(await holder.canUploadStop(stop)) { return }
        if let upload {
            try await upload.task.value
            if self.upload?.id == upload.id { self.upload = nil }
            try await flushStop(backend)
            return
        }
        let priorRead = read
        let id = UUID()
        let task = Task {
            // A stop after an in-flight start must reach the server after that start finishes.
            _ = await priorRead?.task.result
            if self.read?.id == priorRead?.id { self.read = nil }
            try Task.checkCancellation()
            if await self.holder.needsStopCheck(owner: backend.owner) {
                _ = try await self.fetch(backend, starting: false)
            }
            guard backend.isCurrent, try await self.holder.pendingStop(owner: backend.owner) == stop,
                  await self.holder.canUploadStop(stop) else { return }
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
        if try await holder.pendingStop(owner: backend.owner) != nil,
           !(await holder.needsCancellationPoll(owner: backend.owner)) {
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
        case .declarationRequired: return .declarationRequired
        case .rateLimited: return .rateLimited
        case .transportFailure, .httpFailure: return .transport
        default: return .unavailable
        }
    }

    private func update() async {
        publish(await holder.snapshot())
        await activities.flush()
        await scheduleCancellationPoll()
    }

    private func scheduleCancellationPoll() async {
        guard let backend, backend.isCurrent, !account.sessionChangeInProgress, !account.deletionSuspended,
              await holder.needsCancellationPoll(owner: backend.owner) else {
            cancellationPoll?.job.cancel(); cancellationPoll = nil
            return
        }
        guard cancellationPoll == nil else { return }
        let id = UUID()
        let job = cancellationScheduler.schedule(after: SessionCancellationPolicy.pollInterval) { [weak self] in
            guard let self, self.cancellationPoll?.id == id, self.backend === backend, backend.isCurrent else { return }
            self.cancellationPoll = nil
            await self.foreground()
            await self.retry?.task.value
        }
        cancellationPoll = (id, job)
    }

    private func publish(_ snapshot: SessionHolder.Snapshot, allowSameVersion: Bool = true) {
        guard snapshot.version > version || (allowSameVersion && snapshot.version == version) else { return }
        version = snapshot.version
        state = snapshot.state; remainingSeconds = snapshot.remainingSeconds; stopPending = snapshot.stopPending
        if case .active = snapshot.state { controlStartFailure = nil; controlNeedsAccountRefresh = false }
        activities.receive(snapshot, displayName: account.profile?.displayName ?? "",
            isCurrent: account.hasCurrentSessionContext && account.state.isSignedIn &&
                configuredEpoch == account.sessionGeneration && configuredFence?.isCurrent() == true)
    }
}
