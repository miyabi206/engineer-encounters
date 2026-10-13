import Combine
import EncounterBackend
import EncounterUI
import Foundation

@MainActor
final class LinkAdapter: ObservableObject {
    @Published private(set) var connection: GitHubConnectionState = .notConnected
    @Published private(set) var connectionError: LinkActionError?
    @Published private(set) var disconnectError: LinkActionError?
    @Published private(set) var needsGitHubSync = false
    @Published private(set) var links: [OwnLinkState]?
    private let account: AccountModel
    private let runner: any GitHubWebAuthenticationRunning
    private var own: OwnLinkService?
    private var github: GitHubLinksService?
    var protectedContentDidChange: @MainActor () -> Void = {}
    private var pending: UUID?

    init(account: AccountModel, runner: any GitHubWebAuthenticationRunning) {
        self.account = account
        self.runner = runner
    }

    func configure(own: OwnLinkService?, github: GitHubLinksService?) {
        self.own = own; self.github = github
    }

    func invalidate() async {
        pending = nil
        runner.cancel()
        await account.sessions?.cancelGitHubLink()
        links = nil; connection = .notConnected; connectionError = nil; disconnectError = nil; needsGitHubSync = false
        own = nil; github = nil
    }

    func actions() -> LinkActions {
        let epoch = account.sessionGeneration
        let fence = account.backendCallFence()
        return LinkActions(loadLinks: { try await self.loadLinks(epoch: epoch, fence: fence) },
            loadConnection: {
                let value = try await self.operation(epoch: epoch, fence: fence) { own, _ in Self.present(try await own.getGitHubConnection()) }
                if !self.needsGitHubSync { self.connection = value }
                return value
            },
            connectGitHub: { try await self.connect(epoch: epoch, fence: fence) },
            listRepositories: { page in try await self.operation(epoch: epoch, fence: fence) { _, github in
                let result = try await github.listRepositories(page: page)
                return try GitHubRepositoryPage(repositories: result.repositories.map(Self.present), nextPage: result.nextPage)
            } },
            previewRepository: { repository in try await self.operation(epoch: epoch, fence: fence) { _, github in
                try Self.present(await github.previewRepository(repositoryID: repository.repositoryID, repositoryName: repository.repositoryName))
            } },
            saveRepository: { draft, visibility, replace in
                let saved = try await self.operation(epoch: epoch, fence: fence) { _, github in
                    try Self.present(await github.saveRepository(repositoryID: draft.repositoryID, repositoryName: draft.repositoryName,
                        title: draft.title, description: draft.description, mainLanguage: draft.mainLanguage, tags: draft.tags,
                        openingText: draft.openingText, visibility: Self.wire(visibility), replaceExisting: replace))
                }
                if let links = self.links { self.links = links.filter { $0.id != saved.id } + [saved] }
                self.protectedContentDidChange()
                await self.refreshProfile(epoch: epoch, fence: fence, fallbackCount: self.links?.count ?? (replace ? nil : self.account.profile.map { $0.linkCount + 1 }))
                guard fence.isCurrent() else { throw Self.presentationError(BackendError.notAuthenticated) }
                return saved
            },
            updateLink: { id, draft, visibility in
                let saved = try await self.operation(epoch: epoch, fence: fence) { own, _ in
                    try Self.present(await own.updateOwnLink(linkID: Self.identifier(id), title: draft.title,
                        description: draft.description, mainLanguage: draft.mainLanguage, tags: draft.tags,
                        openingText: draft.openingText, visibility: Self.wire(visibility)))
                }
                if let links = self.links { self.links = links.filter { $0.id != saved.id } + [saved] }
                self.protectedContentDidChange()
                await self.refreshProfile(epoch: epoch, fence: fence, fallbackCount: self.links?.count)
                guard fence.isCurrent() else { throw Self.presentationError(BackendError.notAuthenticated) }
                return saved
            },
            deleteLink: { id in
                try await self.operation(epoch: epoch, fence: fence) { own, _ in try await own.deleteOwnLink(linkID: Self.identifier(id)) }
                let remaining = self.links?.filter { $0.id != id }
                self.links = remaining
                let count = remaining.map { $0.count } ?? self.account.profile.map { max(0, $0.linkCount - 1) }
                self.protectedContentDidChange()
                await self.refreshProfile(epoch: epoch, fence: fence, fallbackCount: count)
                do { return try await self.loadLinks(epoch: epoch, fence: fence) }
                catch {
                    guard fence.isCurrent(), self.account.sessionGeneration == epoch, self.account.state.isSignedIn, let remaining else { throw error }
                    return remaining
                }
            },
            reorderLinks: { ids in
                let links = try await self.operation(epoch: epoch, fence: fence) { own, _ in
                    try await own.reorderOwnLinks(linkIDs: ids.map(Self.identifier)).map(Self.present)
                }
                self.links = links
                self.protectedContentDidChange()
                return links
            },
            refreshPreview: { draft in try await self.operation(epoch: epoch, fence: fence) { _, github in
                guard let id = draft.existingLinkID else { throw BackendError.invalidInput(fields: ["link_id"]) }
                let result = try await github.refreshPreview(linkID: Self.identifier(id))
                guard result.linkID == (try Self.identifier(id)) else { throw BackendError.invalidResponse }
                return try Self.present(result.preview)
            } })
    }

    func disconnectGitHub() async throws {
        let epoch = account.sessionGeneration
        let fence = account.backendCallFence()
        do { try requireSession(epoch: epoch, fence: fence) }
        catch { throw Self.presentationError(error) }
        disconnectError = nil
        do {
            let value = try await operation(epoch: epoch, fence: fence) { own, _ in Self.present(try await own.disconnectGitHub()) }
            connection = value
            protectedContentDidChange()
            needsGitHubSync = false
            // Each follow-up runs independently: a failed read must not skip Auth unlink.
            var followUpError: (any Error)?
            do { _ = try await loadLinks(epoch: epoch, fence: fence) } catch { followUpError = error }
            do {
                let value = try await operation(epoch: epoch, fence: fence) { own, _ in Self.present(try await own.getGitHubConnection()) }
                connection = value
            } catch { if followUpError == nil { followUpError = error } }
            await refreshProfile(epoch: epoch, fence: fence, fallbackCount: 0)
            do {
                try requireSession(epoch: epoch, fence: fence)
                if let sessions = account.sessions {
                    _ = try await fence.call { try await sessions.unlinkGitHubIdentity() }
                }
            } catch {
                await rejectIfDead(error, epoch: epoch, fence: fence)
                if followUpError == nil { followUpError = error }
            }
            if let followUpError { throw followUpError }
        } catch {
            if account.sessionGeneration == epoch, account.hasCurrentSessionContext, case .signedIn = account.state {
                disconnectError = Self.presentationError(error)
            }
            throw Self.presentationError(error)
        }
    }

    private func loadLinks(epoch: UUID, fence: BackendCallFence) async throws -> [OwnLinkState] {
        let result = try await operation(epoch: epoch, fence: fence) { own, _ in try await own.listOwnLinks().map(Self.present) }
        links = result
        return result
    }

    private func requireSession(epoch: UUID, fence: BackendCallFence) throws {
        if account.deletionSuspended { throw CancellationError() }
        guard fence.isCurrent(), account.hasCurrentSessionContext, !account.sessionCleanupPending, !account.sessionChangeInProgress,
              account.sessionGeneration == epoch, case .signedIn = account.state else { throw BackendError.notAuthenticated }
        guard account.canRefreshSession() else { throw BackendError.storageFailure }
    }

    private func operation<Value>(epoch: UUID, fence: BackendCallFence,
        _ action: @MainActor (OwnLinkService, GitHubLinksService) async throws -> Value) async throws -> Value {
        // Local readiness failures are not evidence that Auth rejected this session.
        do { try requireSession(epoch: epoch, fence: fence) }
        catch { throw Self.presentationError(error) }
        guard let own, let github else { throw Self.presentationError(BackendError.notAuthenticated) }
        let value: Value
        do { value = try await account.protectedOperation { try await fence.call { try await action(own, github) } } }
        catch is CancellationError { throw CancellationError() }
        catch {
            await rejectIfDead(error, epoch: epoch, fence: fence)
            throw Self.presentationError(error)
        }
        do { try requireSession(epoch: epoch, fence: fence) }
        catch { throw Self.presentationError(error) }
        return value
    }

    private func rejectIfDead(_ error: any Error, epoch: UUID, fence: BackendCallFence) async {
        guard fence.isCurrent(), error as? BackendError == .notAuthenticated,
              account.hasCurrentSessionContext, account.sessionGeneration == epoch,
              case .signedIn = account.state else { return }
        await account.rejectDeadSession(generation: epoch)
    }

    private func connect(epoch: UUID, fence: BackendCallFence) async throws -> GitHubConnectionState {
        do { try requireSession(epoch: epoch, fence: fence) }
        catch { throw Self.presentationError(error) }
        guard pending == nil else { throw LinkActionError(code: .unavailable, details: ["pending"]) }
        guard let sessions = account.sessions else { throw Self.presentationError(BackendError.notAuthenticated) }
        let id = UUID()
        pending = id; connectionError = nil
        if !needsGitHubSync { connection = .connecting }
        defer { if pending == id { pending = nil } }
        do {
            let synced: GitHubConnectionTransfer
            do {
                synced = try await operation(epoch: epoch, fence: fence) { _, github in try await github.syncIdentity() }
            } catch let failure as LinkActionError where failure.code == .prerequisiteMissing &&
                failure.details.contains("github") && !needsGitHubSync {
                // A live identity with a missing cache can be synced without another authorization.
                try requireSession(epoch: epoch, fence: fence)
                let address = try await fence.call { try await sessions.beginGitHubLink() }
                try requireSession(epoch: epoch, fence: fence)
                let callback = try await fence.call { try await runner.authenticate(at: address, callbackScheme: "engineer-encounters") }
                try requireSession(epoch: epoch, fence: fence)
                _ = try await fence.call { try await sessions.completeGitHubLink(from: callback) }
                try requireSession(epoch: epoch, fence: fence)
                needsGitHubSync = true
                connection = .connected(handle: nil)
                synced = try await operation(epoch: epoch, fence: fence) { _, github in try await github.syncIdentity() }
            }
            needsGitHubSync = false
            protectedContentDidChange()
            connection = Self.present(synced)
            let value = try await operation(epoch: epoch, fence: fence) { own, _ in Self.present(try await own.getGitHubConnection()) }
            connection = value
            return value
        } catch {
            await sessions.cancelGitHubLink()
            let current = fence.isCurrent() && pending == id
            if error is CancellationError, current, !needsGitHubSync {
                connection = .notConnected
                return .notConnected
            }
            await rejectIfDead(error, epoch: epoch, fence: fence)
            let failure = Self.presentationError(current ? error : BackendError.notAuthenticated)
            if current, pending == id {
                if !needsGitHubSync { connection = .failed }
                connectionError = failure
            }
            throw failure
        }
    }

    private func refreshProfile(epoch: UUID, fence: BackendCallFence, fallbackCount: Int?) async {
        guard fence.isCurrent(), account.sessionGeneration == epoch else { return }
        var accepted = account.profile
        if let fallbackCount { accepted?.linkCount = fallbackCount; accepted?.prerequisites.link = fallbackCount > 0 }
        do { _ = try await account.loadOwnProfile() }
        catch {
            if fence.isCurrent(), account.sessionGeneration == epoch, account.state.isSignedIn, let accepted {
                account.publishProfile(accepted, stale: true)
            }
        }
    }

    static func presentationError(_ error: any Error) -> LinkActionError {
        if let error = error as? LinkActionError { return error }
        switch error as? BackendError {
        case .invalidInput(let details):
            let names = ["main_language": LinkField.mainLanguage, "opening_text": .openingText, "source_label": .sourceLabel]
            return .init(code: .invalidInput, fields: details.compactMap { names[$0] ?? LinkField(rawValue: $0) }, details: details)
        case .prerequisiteMissing(let details): return .init(code: .prerequisiteMissing, details: details)
        case .accountNotReady: return .init(code: .unavailable, details: ["account_not_ready"])
        case .declarationRequired: return .init(code: .unavailable, details: ["declaration_required"])
        case .rateLimited: return .init(code: .unavailable, details: ["rate_limited"])
        case .notFound: return .init(code: .unavailable, details: ["not_found"])
        case .notAuthenticated: return .init(code: .unavailable, details: ["not_authenticated"])
        case .storageFailure: return .init(code: .unavailable, details: ["storage_failure"])
        default: return .init(code: .unavailable, details: ["transport_failure"])
        }
    }

    private static func identifier(_ id: String) throws -> UUID {
        guard let id = UUID(uuidString: id) else { throw BackendError.invalidInput(fields: ["link_id"]) }
        return id
    }
    private static func wire(_ level: EncounterUI.VisibilityLevel) -> EncounterBackend.VisibilityLevel {
        EncounterBackend.VisibilityLevel(rawValue: level.rawValue)!
    }
    private static func address(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil else { throw BackendError.invalidResponse }
        return url
    }
    static func present(_ value: GitHubConnectionTransfer) -> GitHubConnectionState {
        value.connected ? .connected(handle: value.handle) : .notConnected
    }
    static func present(_ value: LinkTransfer) throws -> OwnLinkState {
        let url = try address(value.url)
        return OwnLinkState(id: value.linkID.uuidString.lowercased(), source: .github, sourceLabel: "GitHub",
            title: value.title, description: value.description, mainLanguage: value.mainLanguage, tags: value.tags,
            openingText: value.openingText, url: url, visibility: EncounterUI.VisibilityLevel(rawValue: value.visibility.rawValue),
            verified: value.verificationState == .verified, displayOrder: value.displayOrder, sourceItemID: value.sourceItemID,
            repositoryName: url.lastPathComponent)
    }
    static func present(_ value: RepositoryTransfer) throws -> GitHubRepositoryChoice {
        GitHubRepositoryChoice(repositoryID: value.repositoryID, repositoryName: value.repositoryName, title: value.title,
            description: value.description, mainLanguage: value.mainLanguage, tags: value.tags, url: try address(value.url))
    }
    static func present(_ value: RepositoryPreviewTransfer) throws -> LinkPreviewDraft {
        LinkPreviewDraft(repositoryID: value.repositoryID, repositoryName: value.repositoryName, source: .github,
            url: try address(value.url), verified: value.verificationState == .verified, sourceLabel: "GitHub", title: value.title,
            description: value.description, mainLanguage: value.mainLanguage, tags: value.tags, openingText: value.openingText)
    }
}
