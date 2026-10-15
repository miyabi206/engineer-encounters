import Combine
import Foundation

public enum LinkRoute: Sendable { case list, add, edit }
public enum LinkOperation: Equatable, Sendable {
    case loadLinks, loadConnection, connect, repositories(Int), preview(GitHubRepositoryChoice)
    case save, delete, reorder([String]), refresh
}

@MainActor
public final class LinksModel: ObservableObject {
    @Published public private(set) var links: [OwnLinkState]
    @Published public private(set) var hasLoadedLinks: Bool
    @Published public private(set) var route: LinkRoute = .list
    @Published public var selectedSource: LinkSource? {
        didSet { if selectedSource != oldValue { clearRetry() } }
    }
    @Published public private(set) var connection: GitHubConnectionState = .notConnected
    @Published public private(set) var hasLoadedConnection = false
    @Published public private(set) var connectionCancelled = false
    @Published public private(set) var paging = GitHubRepositoryPaging()
    @Published public private(set) var hasLoadedRepositories = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var error: LinkActionError?
    @Published public private(set) var failedOperation: LinkOperation?
    @Published public private(set) var replacement: LinkPreviewDraft?
    @Published public var draft: LinkPreviewDraft? {
        didSet { if draft != oldValue { error = nil; replacement = nil; failedOperation = nil } }
    }
    @Published public var discoveryOn: Bool {
        didSet {
            if discoveryOn != oldValue { clearRetry() }
        }
    }

    private let actions: LinkActions
    private let onLinksChanged: @MainActor ([OwnLinkState]) -> Void
    private var originalDraft: LinkPreviewDraft?

    public init(actions: LinkActions, links: [OwnLinkState]? = nil, discoveryOn: Bool = false,
                onLinksChanged: @escaping @MainActor ([OwnLinkState]) -> Void = { _ in }) {
        self.actions = actions; self.links = Self.ordered(links ?? [])
        hasLoadedLinks = links != nil; self.discoveryOn = discoveryOn
        self.onLinksChanged = onLinksChanged
    }

    public var canAdd: Bool { !isBusy && hasLoadedLinks && LinkValidation.canAdd(count: links.count) }
    public var canSave: Bool {
        guard !isBusy, hasLoadedLinks, let draft else { return false }
        return LinkValidation.canSave(draft, linkCount: links.count)
    }
    public var canDelete: Bool {
        !isBusy && draft?.existingLinkID != nil && error?.isLastLink != true &&
            LinkValidation.canDelete(count: links.count, discoveryOn: discoveryOn)
    }
    public var hasEdits: Bool { draft != originalDraft }
    public var canRetry: Bool {
        guard !isBusy else { return false }
        switch failedOperation {
        case .save: return canSave
        case .delete: return false
        case nil: return false
        default: return true
        }
    }

    public func beginAdd() {
        guard canAdd else { return }
        draft = nil; originalDraft = nil; error = nil; failedOperation = nil
        selectedSource = nil; route = .add
        resetConnection()
    }
    public func beginEdit(_ link: OwnLinkState) {
        guard !isBusy, links.contains(where: { $0.id == link.id }) else { return }
        draft = LinkPreviewDraft(link: link); originalDraft = draft
        error = nil; failedOperation = nil; route = .edit
    }
    /// Views ask for discard confirmation when hasEdits is true before calling this.
    public func cancelEditor() {
        guard !isBusy else { return }
        let isNew = draft?.existingLinkID == nil
        draft = nil; originalDraft = nil; replacement = nil
        error = nil; failedOperation = nil; route = isNew ? .add : .list
    }
    public func cancelAdd() {
        guard !isBusy else { return }
        error = nil; failedOperation = nil; route = .list
    }

    public func loadLinks() async {
        guard !isBusy else { return }
        links = []; hasLoadedLinks = false
        await perform(.loadLinks) {
            let loaded = try await self.actions.loadLinks()
            try Task.checkCancellation()
            self.receive(loaded)
        }
    }
    public func loadConnection() async {
        guard !isBusy else { return }
        hasLoadedConnection = false; connection = .notConnected
        paging = GitHubRepositoryPaging(); hasLoadedRepositories = false
        await perform(.loadConnection) {
            let loaded = try await self.actions.loadConnection()
            try Task.checkCancellation()
            guard loaded != .connecting else { throw LinkActionError(code: .unavailable) }
            self.connection = loaded; self.hasLoadedConnection = true
            if loaded == .failed { throw LinkActionError(code: .unavailable) }
        }
        if error == nil && connection.isConnected { await loadRepositories(page: 1) }
    }
    public func connectGitHub() async {
        guard !isBusy else { return }
        connection = .connecting; connectionCancelled = false
        paging = GitHubRepositoryPaging(); hasLoadedRepositories = false
        await perform(.connect) {
            let connected = try await self.actions.connectGitHub()
            guard connected != .connecting && connected != .failed else {
                throw LinkActionError(code: .unavailable)
            }
            self.connection = connected; self.hasLoadedConnection = true
            self.connectionCancelled = connected == .notConnected
        }
        if error != nil { connection = .failed }
        else if connection == .connecting { connection = .notConnected; connectionCancelled = true }
        if connection.isConnected { await loadRepositories(page: 1) }
    }
    public func loadRepositories(page: Int) async {
        guard !isBusy, (1...1000).contains(page), connection.isConnected else { return }
        paging = GitHubRepositoryPaging(); hasLoadedRepositories = false
        await perform(.repositories(page)) {
            let result = try await self.actions.listRepositories(page)
            try Task.checkCancellation()
            self.paging.receive(result, page: page)
            self.hasLoadedRepositories = true
        }
    }
    public func preview(_ repository: GitHubRepositoryChoice) async {
        guard canAdd, connection.isConnected,
              paging.repositories.contains(repository) else { return }
        await perform(.preview(repository)) {
            var preview = try await self.actions.previewRepository(repository)
            try Task.checkCancellation()
            guard preview.existingLinkID == nil, preview.source == .github,
                  preview.repositoryID == repository.repositoryID else { throw LinkActionError(code: .invalidInput) }
            preview.visibility = nil
            self.draft = preview; self.originalDraft = preview; self.route = .edit
        }
    }
    public func save() async -> Bool {
        guard canSave, let draft, let visibility = draft.visibility else { return false }
        return await perform(.save) {
            let saved: OwnLinkState
            if let id = draft.existingLinkID, !draft.replaceExisting {
                saved = try await self.actions.updateLink(id, draft, visibility)
            } else {
                saved = try await self.actions.saveRepository(draft, visibility, draft.replaceExisting)
            }
            // Confirmed writes remain acknowledged even if the task was cancelled meanwhile.
            self.receive(self.links.filter { $0.id != saved.id } + [saved])
            self.draft = nil; self.originalDraft = nil; self.route = .list
        }
    }
    /// Call only after the view's destructive confirmation; the last-link rule is checked again.
    public func deleteConfirmed() async -> Bool {
        guard canDelete, let id = draft?.existingLinkID else { return false }
        return await perform(.delete) {
            let remaining = try await self.actions.deleteLink(id)
            self.receive(remaining); self.draft = nil; self.originalDraft = nil; self.route = .list
        }
    }
    public func reorder(ids: [String]) async {
        guard !isBusy, hasLoadedLinks, ids.count == links.count,
              Set(ids).count == ids.count, Set(ids) == Set(links.map(\.id)) else { return }
        await perform(.reorder(ids)) { self.receive(try await self.actions.reorderLinks(ids)) }
    }
    public func move(_ id: String, offset: Int) async {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard links.indices.contains(destination) else { return }
        var ids = links.map(\.id); ids.swapAt(index, destination)
        await reorder(ids: ids)
    }
    public func refresh() async {
        guard !isBusy, let draft else { return }
        replacement = nil
        await perform(.refresh) {
            let fresh = try await self.actions.refreshPreview(draft)
            try Task.checkCancellation()
            guard fresh.source == draft.source, fresh.repositoryID == draft.sourceItemID else {
                throw LinkActionError(code: .invalidInput)
            }
            self.replacement = fresh
        }
    }
    public func acceptReplacement() {
        guard !isBusy, let fresh = replacement, let draft else { return }
        self.draft = draft.replacingMetadata(with: fresh)
        replacement = nil
    }
    public func cancelReplacement() { replacement = nil; clearRetry() }

    public func removeTag(at index: Int) {
        guard !isBusy, let tags = draft?.tags, tags.indices.contains(index) else { return }
        draft?.tags.remove(at: index)
    }

    public func returnToEditor() {
        guard !isBusy, draft != nil, connection.isConnected else { return }
        clearRetry(); route = .edit
    }

    private func clearRetry() { error = nil; failedOperation = nil; replacement = nil }
    private func resetConnection() {
        connection = .notConnected; hasLoadedConnection = false; connectionCancelled = false
        paging = GitHubRepositoryPaging(); hasLoadedRepositories = false
    }

    public func retry() async {
        guard let operation = failedOperation else { return }
        await retry(operation)
    }

    /// Bind the button to its rendered failure; an obsolete button cannot run another action.
    public func retry(_ operation: LinkOperation) async {
        guard canRetry, failedOperation == operation else { return }
        switch operation {
        case .loadLinks: await loadLinks()
        case .loadConnection: await loadConnection()
        case .connect: await connectGitHub()
        case .repositories(let page): await loadRepositories(page: page)
        case .preview(let repository): await preview(repository)
        case .save: _ = await save()
        case .delete: break
        case .reorder(let ids): await reorder(ids: ids)
        case .refresh: await refresh()
        }
    }

    private func receive(_ confirmed: [OwnLinkState]) {
        links = Self.ordered(confirmed); hasLoadedLinks = true; onLinksChanged(links)
    }
    private static func ordered(_ links: [OwnLinkState]) -> [OwnLinkState] {
        links.sorted { $0.displayOrder == $1.displayOrder ? $0.id < $1.id : $0.displayOrder < $1.displayOrder }
    }
    @discardableResult
    private func perform(_ operation: LinkOperation, action: @MainActor () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true; error = nil; replacement = nil; failedOperation = operation
        defer { isBusy = false }
        do {
            try await action(); failedOperation = nil; return true
        } catch is CancellationError {
            return false
        } catch {
            let failure = error as? LinkActionError ?? LinkActionError(code: .unavailable)
            if failure.isLastLink { discoveryOn = true; failedOperation = nil }
            self.error = failure
            if self.error?.requires("refresh_confirmation") == true {
                replacement = draft; failedOperation = nil
            } else if self.error?.requires("github") == true {
                resetConnection(); selectedSource = .github; route = .add
                self.error = error as? LinkActionError
                failedOperation = nil
            }
            return false
        }
    }
}
