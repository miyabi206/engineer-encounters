import Combine
import EncounterBackend
import Foundation
import EncounterUI

enum AccountState: Equatable {
    case unavailable, restoring, signedOut, signedInPending(UUID?), signedIn(UUID)

    var isSignedIn: Bool {
        switch self {
        case .signedIn, .signedInPending: true
        default: false
        }
    }
}

@MainActor
final class AccountModel: ObservableObject {
    @Published private(set) var state: AccountState {
        didSet { if state != oldValue { profile = nil; profileIsStale = false } }
    }
    private(set) var sessions: SessionManager?
    private(set) var service: OwnAccountService?
    private let sessionStore: (any SessionStore)?
    private let sessionFactory: (@MainActor (any SessionStore) -> SessionManager)?
    private let serviceFactory: (@MainActor (SessionManager) -> OwnAccountService)?
    private let cleanup: SessionCleanupMarker
    private let sessionIsCurrent: @MainActor () -> Bool
    var hasCurrentSessionContext: Bool { sessionIsCurrent() }
    @Published private(set) var sessionCleanupFailed: Bool
    var sessionCleanupPending: Bool { cleanup.isPending }
    private var generation = UUID()
    private var refreshTask: (id: UUID, task: Task<Void, Never>)?
    private struct Declarations {
        let age18: Bool
        let terms: String
        let privacy: String
    }
    private var pendingDeclarations: Declarations?
    private var setupTask: (id: UUID, task: Task<Void, any Error>)?
    @Published var profile: OwnProfileState?
    @Published private(set) var profileIsStale = false
    let onboardingCompletion: OnboardingCompletionStore
    var sessionGeneration: UUID { generation }
    private let timeZone: @MainActor () -> String
    private var registeredTimeZone: String?
    private var operationTask: Task<Void, any Error>?
    var prepareForSessionChange: @MainActor () async throws -> Void = {}
    var sessionDidChange: @MainActor (_ recreate: Bool) async -> Void = { _ in }

    init(sessions: SessionManager?, service: OwnAccountService?,
         sessionStore: (any SessionStore)? = nil,
         sessionFactory: (@MainActor (any SessionStore) -> SessionManager)? = nil,
         serviceFactory: (@MainActor (SessionManager) -> OwnAccountService)? = nil,
         cleanup: SessionCleanupMarker? = nil,
         sessionIsCurrent: @escaping @MainActor () -> Bool = { true },
         defaults: UserDefaults = .standard,
         timeZone: @escaping @MainActor () -> String = { TimeZone.current.identifier }) {
        self.sessions = sessions
        self.service = service
        self.sessionStore = sessionStore
        self.sessionFactory = sessionFactory
        self.serviceFactory = serviceFactory
        self.cleanup = cleanup ?? SessionCleanupMarker(defaults: defaults)
        self.sessionIsCurrent = sessionIsCurrent
        sessionCleanupFailed = self.cleanup.isPending
        self.timeZone = timeZone
        onboardingCompletion = OnboardingCompletionStore(defaults: defaults)
        state = sessions == nil ? .unavailable : .restoring
    }

    func restore() async {
        guard hasCurrentSessionContext else { return }
        guard let sessions else {
            await sessionDidChange(false)
            return
        }
        let epoch = generation
        if cleanup.isPending {
            await discardDeadSession(epoch: epoch, recreate: false)
            return
        }
        var canRefresh = true
        do {
            // Reading credentials chooses storage without refreshing over the network.
            let stored: BackendSession?
            if let sessionStore { stored = try await sessionStore.load() }
            else { stored = try await sessions.session() }
            guard epoch == generation, hasCurrentSessionContext else { return }
            guard let stored else { throw BackendError.notAuthenticated }
            state = .signedInPending(stored.userID)
        } catch BackendError.notAuthenticated {
            await discardDeadSession(epoch: epoch, recreate: false)
            return
        } catch {
            guard epoch == generation, hasCurrentSessionContext else { return }
            if cleanup.isPending {
                await discardDeadSession(epoch: epoch, recreate: false)
                return
            }
            // A locked/unavailable Keychain is not evidence that the user signed out.
            state = .signedInPending(nil)
            canRefresh = false
        }
        guard epoch == generation else { return }
        await sessionDidChange(false)
        guard epoch == generation, canRefresh else { return }
        await refresh()
    }

    /// Authenticate only when signed out, using isolated storage until session cleanup completes.
    func signIn(using request: AuthRequest, isAdult: Bool, acceptsTermsAndPrivacy: Bool,
                termsVersion: String, privacyVersion: String) async throws {
        guard isAdult && acceptsTermsAndPrivacy else { throw BackendError.declarationRequired }
        guard state == .signedOut else { throw BackendError.invalidRequest }
        guard hasCurrentSessionContext else { throw BackendError.notAuthenticated }
        guard !cleanup.isPending else { throw BackendError.storageFailure }
        guard let oldSessions = sessions, let sessionStore, let sessionFactory, let serviceFactory else {
            throw BackendError.invalidRequest
        }
        let authGeneration = generation
        let stagedStore = StagedSessionStore()
        let newSessions = sessionFactory(stagedStore)
        let session: BackendSession
        do { session = try await newSessions.establish(using: request) }
        catch { throw Self.safeError(error) }
        var establishedGeneration: UUID?
        var storageFailed = false
        try await serialize {
            guard authGeneration == self.generation else { throw BackendError.notAuthenticated }
            guard self.hasCurrentSessionContext else { throw BackendError.notAuthenticated }
            guard self.state == .signedOut else { throw BackendError.invalidRequest }
            guard !self.cleanup.isPending else { throw BackendError.storageFailure }
            try self.cleanup.begin()
            self.invalidateRefresh()
            do { try await self.prepareForSessionChange() }
            catch {
                do {
                    try await oldSessions.clear()
                    if self.hasCurrentSessionContext { self.cleanup.complete() }
                }
                catch { self.sessionCleanupFailed = true }
                await self.sessionDidChange(true)
                throw error
            }
            guard self.hasCurrentSessionContext else { throw BackendError.notAuthenticated }
            do {
                try await oldSessions.clear()
                guard self.hasCurrentSessionContext else { throw BackendError.notAuthenticated }
                self.cleanup.complete()
            }
            catch {
                self.sessionCleanupFailed = true
                await self.sessionDidChange(true)
                throw BackendError.storageFailure
            }
            self.sessionCleanupFailed = false
            do { try await stagedStore.activate(sessionStore) } catch { storageFailed = true }
            self.sessions = newSessions
            self.service = serviceFactory(newSessions)
            self.registeredTimeZone = nil
            self.pendingDeclarations = Declarations(age18: isAdult, terms: termsVersion, privacy: privacyVersion)
            self.state = .signedInPending(session.userID)
            // Recreate/start before either of the account setup requests.
            await self.sessionDidChange(true)
            establishedGeneration = self.generation
        }
        guard let epoch = establishedGeneration else { return }
        do {
            try await finishAccountSetup(epoch: epoch)
            guard epoch == generation else { throw BackendError.notAuthenticated }
            state = .signedIn(session.userID)
            if storageFailed { throw BackendError.storageFailure }
        } catch BackendError.notAuthenticated {
            await discardDeadSession(epoch: epoch, recreate: true)
            throw BackendError.notAuthenticated
        } catch { throw Self.safeError(error) }
    }

    func signOut() async throws {
        try await serialize {
            guard self.hasCurrentSessionContext else { throw BackendError.notAuthenticated }
            guard let sessions = self.sessions else { return }
            do { try self.cleanup.begin() }
            catch { self.sessionCleanupFailed = true; throw BackendError.storageFailure }
            var storageFailed = false
            self.invalidateRefresh()
            do { try await self.prepareForSessionChange() } catch { storageFailed = true }
            guard self.hasCurrentSessionContext else { throw BackendError.notAuthenticated }
            // SessionManager clears its in-memory account even when persistence fails.
            do {
                try await sessions.clear()
                if self.hasCurrentSessionContext { self.cleanup.complete() }
            } catch { storageFailed = true }
            guard self.hasCurrentSessionContext else { throw BackendError.notAuthenticated }
            self.sessionCleanupFailed = self.cleanup.isPending
            self.registeredTimeZone = nil
            self.pendingDeclarations = nil
            self.onboardingCompletion.clear()
            self.state = .signedOut
            await self.sessionDidChange(true)
            if storageFailed { throw BackendError.storageFailure }
        }
    }

    func refresh() async {
        guard hasCurrentSessionContext else { return }
        if cleanup.isPending {
            await discardDeadSession(epoch: generation, recreate: true)
            return
        }
        guard state.isSignedIn, let sessions else { return }
        if let refreshTask { await refreshTask.task.value; return }
        let epoch = generation
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await sessions.session()
                guard epoch == self.generation, self.hasCurrentSessionContext else { return }
                switch self.state {
                case .signedIn(let user) where user != session.userID,
                     .signedInPending(.some(let user)) where user != session.userID:
                    await self.discardDeadSession(epoch: epoch, recreate: true)
                    return
                default: break
                }
                if self.state == .signedInPending(nil) {
                    self.state = .signedInPending(session.userID)
                    await self.sessionDidChange(true)
                    guard epoch == self.generation else { return }
                }
                try await self.finishAccountSetup(epoch: epoch)
                guard epoch == self.generation else { return }
                self.state = .signedIn(session.userID)
            } catch BackendError.notAuthenticated {
                await self.discardDeadSession(epoch: epoch, recreate: true)
            } catch {
                guard epoch == self.generation, self.hasCurrentSessionContext else { return }
                if self.cleanup.isPending {
                    await self.discardDeadSession(epoch: epoch, recreate: true)
                    return
                }
                if case .signedIn(let id) = self.state { self.state = .signedInPending(id) }
            }
        }
        refreshTask = (id, task)
        await task.value
        if refreshTask?.id == id { refreshTask = nil }
    }

    private func finishAccountSetup(epoch: UUID) async throws {
        guard epoch == generation else { throw BackendError.notAuthenticated }
        if let setupTask { return try await setupTask.task.value }
        let id = UUID()
        let task = Task {
            guard epoch == self.generation else { throw BackendError.notAuthenticated }
            if let declarations = self.pendingDeclarations, let service = self.service {
                try await service.acceptDeclarations(age18: declarations.age18, termsVersion: declarations.terms,
                                                     privacyVersion: declarations.privacy)
                guard epoch == self.generation else { throw BackendError.notAuthenticated }
                self.pendingDeclarations = nil
            }
            let zone = self.timeZone()
            if zone != self.registeredTimeZone, let service = self.service {
                try await service.registerTimeZone(zone)
                guard epoch == self.generation else { throw BackendError.notAuthenticated }
                self.registeredTimeZone = zone
            }
        }
        setupTask = (id, task)
        defer { if setupTask?.id == id { setupTask = nil } }
        try await task.value
    }

    private func invalidateRefresh() {
        generation = UUID()
        refreshTask?.task.cancel()
        refreshTask = nil
        setupTask?.task.cancel()
        setupTask = nil
    }

    private func discardDeadSession(epoch: UUID, recreate: Bool) async {
        try? await serialize {
            guard self.hasCurrentSessionContext, epoch == self.generation, let sessions = self.sessions else { return }
            do { try self.cleanup.begin() }
            catch { self.sessionCleanupFailed = true; self.profile = nil; return }
            self.invalidateRefresh()
            try? await self.prepareForSessionChange()
            guard self.hasCurrentSessionContext else { return }
            do {
                try await sessions.clear()
                if self.hasCurrentSessionContext { self.cleanup.complete() }
            }
            catch { /* The marker keeps failed deletion quarantined across restart. */ }
            guard self.hasCurrentSessionContext else { return }
            self.sessionCleanupFailed = self.cleanup.isPending
            self.registeredTimeZone = nil
            self.pendingDeclarations = nil
            self.onboardingCompletion.clear()
            self.state = .signedOut
            await self.sessionDidChange(recreate)
        }
    }

    func rejectDeadSession(generation: UUID) async {
        await discardDeadSession(epoch: generation, recreate: true)
    }

    func publishProfile(_ value: OwnProfileState, stale: Bool) {
        guard hasCurrentSessionContext, !cleanup.isPending else { return }
        profileIsStale = stale
        profile = value
    }

    /// Serialized session changes contain local cleanup and runtime wiring, never account requests.
    func drainSessionChange() async { _ = await operationTask?.result }

    private func serialize(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = operationTask
        let next = Task {
            _ = await previous?.result
            do { try await operation() } catch { throw Self.safeError(error) }
        }
        operationTask = next
        try await next.value
    }

    private static func safeError(_ error: any Error) -> BackendError {
        // Even injectable I/O errors must never carry credential or response material.
        switch error as? BackendError {
        case .notAuthenticated: return .notAuthenticated
        case .accountNotReady: return .accountNotReady
        case .declarationRequired: return .declarationRequired
        case .invalidInput(let fields): return .invalidInput(fields: fields)
        case .prerequisiteMissing(let fields): return .prerequisiteMissing(fields: fields)
        case .rateLimited: return .rateLimited
        case .notFound: return .notFound
        case .storageFailure: return .storageFailure
        default: return .transportFailure
        }
    }
}
