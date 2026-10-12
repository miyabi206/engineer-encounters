import Combine
import Foundation

public enum AccountSettingsSignIn: Equatable, Sendable { case apple, temporary }

public struct AccountSettingsData: Equatable, Sendable {
    public var signIn: AccountSettingsSignIn
    public var githubConnected: Bool
    public var githubHandle: String?
    public var discoveryOn: Bool
    public var linkCount: Int
    public var githubRepositoryCount: Int
    public init(signIn: AccountSettingsSignIn = .apple, githubConnected: Bool = false, githubHandle: String? = nil,
                discoveryOn: Bool = false, linkCount: Int = 0, githubRepositoryCount: Int = 0) {
        self.signIn = signIn; self.githubConnected = githubConnected; self.githubHandle = githubHandle
        self.discoveryOn = discoveryOn; self.linkCount = linkCount; self.githubRepositoryCount = githubRepositoryCount
    }
    public var disconnectRemovesLastLink: Bool {
        discoveryOn && githubRepositoryCount > 0 && linkCount <= githubRepositoryCount
    }
}

/// Failure leaves participation suspended and dismissal locked. Auth expiry routes
/// to sign-in without a deletion receipt; only an accepted deletion is success.
public enum AccountSettingsDeletionState: Equatable, Sendable {
    case idle, pending, failed, configurationRequired, deleted, authenticationExpired
    public var preventsSignedInDismissal: Bool { self != .idle }
    public var canRetry: Bool { self == .failed || self == .configurationRequired }
    public mutating func begin() -> Bool {
        guard self == .idle || canRetry else { return false }
        self = .pending; return true
    }
    public mutating func accept(deleted: Bool) {
        guard self == .pending else { return }
        self = deleted ? .deleted : .failed
    }
    public mutating func fail(_ error: ProfileActionError) {
        guard self == .pending else { return }
        if error.code == .notAuthenticated { self = .authenticationExpired }
        else if error.code == .prerequisiteMissing && error.fields.contains("deletion_safety_key") {
            self = .configurationRequired
        } else { self = .failed }
    }
}

@MainActor
public struct AccountSettingsActions {
    public var load: @MainActor () async throws -> AccountSettingsData
    public var disconnectGitHub: @MainActor () async throws -> AccountSettingsData
    public var signOut: @MainActor () async throws -> Void
    public var deleteAccount: @MainActor () async throws -> Bool
    /// Must synchronously suspend radio participation and protected reads before a deletion request.
    public var suspendParticipation: @MainActor () -> Void
    public init(load: @escaping @MainActor () async throws -> AccountSettingsData,
                disconnectGitHub: @escaping @MainActor () async throws -> AccountSettingsData,
                signOut: @escaping @MainActor () async throws -> Void,
                deleteAccount: @escaping @MainActor () async throws -> Bool,
                suspendParticipation: @escaping @MainActor () -> Void) {
        self.load = load; self.disconnectGitHub = disconnectGitHub; self.signOut = signOut
        self.deleteAccount = deleteAccount; self.suspendParticipation = suspendParticipation
    }
}

@MainActor
public struct AccountSettingsNavigationActions {
    public var back: @MainActor () -> Void
    public var signedOut: @MainActor () -> Void
    public var discovery: @MainActor () -> Void
    public var support: (@MainActor () -> Void)?
    public init(back: @escaping @MainActor () -> Void, signedOut: @escaping @MainActor () -> Void,
                discovery: @escaping @MainActor () -> Void, support: (@MainActor () -> Void)? = nil) {
        self.back = back; self.signedOut = signedOut; self.discovery = discovery; self.support = support
    }
}

public enum AccountSettingsOperation: Equatable, Sendable { case load, disconnect, signOut, delete }

@MainActor
public final class AccountSettingsModel: ObservableObject {
    @Published public private(set) var data: AccountSettingsData?
    @Published public private(set) var isBusy = false
    @Published public private(set) var deletion = AccountSettingsDeletionState.idle
    @Published public private(set) var error: ProfileActionError?
    @Published public private(set) var failedOperation: AccountSettingsOperation?
    public let allowsSignOut: Bool
    public let navigation: AccountSettingsNavigationActions
    private let actions: AccountSettingsActions
    public init(data: AccountSettingsData? = nil, allowsSignOut: Bool = true,
                actions: AccountSettingsActions, navigation: AccountSettingsNavigationActions) {
        self.data = data; self.allowsSignOut = allowsSignOut; self.actions = actions; self.navigation = navigation
    }
    public var canDismiss: Bool { !isBusy && !deletion.preventsSignedInDismissal }
    public var lastLinkRefused: Bool {
        failedOperation == .disconnect && error?.code == .prerequisiteMissing && error?.fields.contains("link") == true
    }
    public func back() { if canDismiss { navigation.back() } }
    public func load() async {
        guard canDismiss else { return }
        begin(.load); data = nil
        defer { isBusy = false }
        do { data = try await actions.load(); succeeded() }
        catch { failed(error) }
    }
    /// All destructive methods are called only after the view/caller confirms.
    public func disconnect() async {
        guard canDismiss, let data, data.githubConnected else { return }
        if data.disconnectRemovesLastLink {
            failedOperation = .disconnect; error = .init(code: .prerequisiteMissing, fields: ["link"]); return
        }
        begin(.disconnect)
        defer { isBusy = false }
        do {
            let fresh = try await actions.disconnectGitHub(); self.data = fresh
            guard !fresh.githubConnected else { throw ProfileActionError(code: .unavailable) }
            succeeded()
        } catch { failed(error) }
    }
    public func signOut() async {
        guard canDismiss, allowsSignOut else { return }
        begin(.signOut)
        defer { isBusy = false }
        do { try await actions.signOut(); succeeded(); navigation.signedOut() }
        catch { failed(error) }
    }
    public func deleteAccount() async {
        guard !isBusy, deletion.begin() else { return }
        begin(.delete)
        actions.suspendParticipation()
        defer { isBusy = false }
        do {
            let deleted = try await actions.deleteAccount()
            deletion.accept(deleted: deleted)
            guard deleted else { throw ProfileActionError(code: .unavailable) }
            succeeded(); data = nil; navigation.signedOut()
        } catch {
            failed(error)
            deletion.fail(self.error ?? .init(code: .unavailable))
        }
    }
    public func retry() async {
        switch failedOperation {
        case .load: await load()
        case .disconnect: await disconnect()
        case .signOut: await signOut()
        case .delete: await deleteAccount()
        case nil: break
        }
    }
    private func begin(_ operation: AccountSettingsOperation) {
        isBusy = true; error = nil; failedOperation = operation
    }
    private func succeeded() { error = nil; failedOperation = nil }
    private func failed(_ failure: any Error) {
        if let linkError = failure as? LinkActionError, linkError.isLastLink {
            error = .init(code: .prerequisiteMissing, fields: ["link"])
        } else { error = failure as? ProfileActionError ?? .init(code: .unavailable) }
        if error?.code == .notAuthenticated {
            if failedOperation == .delete { deletion.fail(error!) }
            data = nil; navigation.signedOut()
        }
    }
}

public enum AccountSettingsListEntry: Hashable, Sendable {
    case discovery, visibility, dailyReport, blockedUsers, account, legal, diagnostics
}

public enum AccountSettingsListComposition {
    public static func entries(hasDiagnostics: Bool) -> [AccountSettingsListEntry] {
        [.discovery, .visibility, .dailyReport, .blockedUsers, .account, .legal] +
            (hasDiagnostics ? [.diagnostics] : [])
    }
}

@MainActor
public struct AccountSettingsListNavigationActions {
    public var dailyReport: @MainActor () -> Void
    public var blockedUsers: @MainActor () -> Void
    public var account: @MainActor () -> Void
    public var legal: @MainActor () -> Void
    public var diagnostics: (@MainActor () -> Void)?
    public init(dailyReport: @escaping @MainActor () -> Void = {}, blockedUsers: @escaping @MainActor () -> Void = {},
                account: @escaping @MainActor () -> Void = {}, legal: @escaping @MainActor () -> Void = {},
                diagnostics: (@MainActor () -> Void)? = nil) {
        self.dailyReport = dailyReport; self.blockedUsers = blockedUsers; self.account = account
        self.legal = legal; self.diagnostics = diagnostics
    }
}
