import Combine
import EncounterBackend
import Foundation
import EncounterUI

enum AccountState: Equatable {
    case unavailable, signedOut, signedIn(UUID)

    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

@MainActor
final class AccountModel: ObservableObject {
    @Published private(set) var state: AccountState {
        didSet { if state != oldValue { profile = nil } }
    }
    private let sessions: SessionManager?
    let service: OwnAccountService?
    @Published var profile: OwnProfileState?
    private let timeZone: @MainActor () -> String
    private var registeredTimeZone: String?
    private var operationTask: Task<Void, any Error>?
    var prepareForSessionChange: @MainActor () async throws -> Void = {}
    var sessionDidChange: @MainActor (_ recreate: Bool) async -> Void = { _ in }

    init(sessions: SessionManager?, service: OwnAccountService?,
         timeZone: @escaping @MainActor () -> String = { TimeZone.current.identifier }) {
        self.sessions = sessions
        self.service = service
        self.timeZone = timeZone
        state = sessions == nil ? .unavailable : .signedOut
    }

    func restore() async {
        try? await serialize {
            guard let sessions = self.sessions else {
                await self.sessionDidChange(false)
                return
            }
            do {
                let session = try await sessions.session()
                self.state = .signedIn(session.userID)
                // Offline restoration must still select server storage, never local test tokens.
                try? await self.registerTimeZoneIfNeeded()
            } catch { self.state = .signedOut }
            await self.sessionDidChange(false)
        }
    }

    /// Provider-neutral entry point; provider request construction lives outside composition.
    func signIn(using request: AuthRequest, isAdult: Bool, acceptsTermsAndPrivacy: Bool,
                termsVersion: String, privacyVersion: String) async throws {
        guard isAdult && acceptsTermsAndPrivacy else { throw BackendError.declarationRequired }
        try await serialize {
            guard let sessions = self.sessions, let service = self.service else {
                throw BackendError.invalidRequest
            }
            try await self.prepareForSessionChange()
            try await sessions.clear()
            self.state = .signedOut
            self.registeredTimeZone = nil
            do {
                let session = try await sessions.establish(using: request)
                try await service.acceptDeclarations(age18: isAdult, termsVersion: termsVersion,
                                                     privacyVersion: privacyVersion)
                try await self.registerTimeZoneIfNeeded()
                self.state = .signedIn(session.userID)
            } catch {
                try? await sessions.clear()
                await self.sessionDidChange(true)
                throw Self.safeError(error)
            }
            await self.sessionDidChange(true)
        }
    }

    func signOut() async throws {
        try await serialize {
            guard let sessions = self.sessions else { return }
            try await self.prepareForSessionChange()
            do { try await sessions.clear() }
            catch { throw BackendError.storageFailure }
            self.registeredTimeZone = nil
            self.state = .signedOut
            await self.sessionDidChange(true)
        }
    }

    func refresh() async {
        try? await serialize {
            guard self.state.isSignedIn, let sessions = self.sessions else { return }
            do {
                _ = try await sessions.session()
                try await self.registerTimeZoneIfNeeded()
            } catch BackendError.notAuthenticated {
                try await self.prepareForSessionChange()
                try await sessions.clear()
                self.registeredTimeZone = nil
                self.state = .signedOut
                await self.sessionDidChange(true)
            }
        }
    }

    private func registerTimeZoneIfNeeded() async throws {
        let zone = timeZone()
        guard zone != registeredTimeZone, let service else { return }
        try await service.registerTimeZone(zone)
        registeredTimeZone = zone
    }

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
