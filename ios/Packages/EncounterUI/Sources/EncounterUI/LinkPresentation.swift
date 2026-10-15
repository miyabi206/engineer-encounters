import Foundation

public enum LinkSource: String, CaseIterable, Sendable {
    case github, qiita, zenn, other
}

/// Owner-only presentation data. Verification and reader identity are server supplied.
public struct OwnLinkState: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: LinkSource
    public let sourceItemID: String?
    public var repositoryID: String? { sourceItemID }
    public let repositoryName: String
    public let sourceLabel: String
    public var title: String
    public var description: String
    public var mainLanguage: String?
    public var tags: [String]
    public var openingText: String
    public let url: URL
    public var visibility: VisibilityLevel?
    public let verified: Bool
    public var displayOrder: Int

    public init(id: String, source: LinkSource, sourceLabel: String, title: String,
                description: String = "", mainLanguage: String? = nil, tags: [String] = [],
                openingText: String = "", url: URL, visibility: VisibilityLevel? = nil,
                verified: Bool = false, displayOrder: Int = 0, sourceItemID: String? = nil,
                repositoryName: String? = nil) {
        self.sourceItemID = sourceItemID
        self.repositoryName = repositoryName ?? url.lastPathComponent
        self.id = id; self.source = source; self.sourceLabel = sourceLabel; self.title = title
        self.description = description; self.mainLanguage = mainLanguage; self.tags = tags
        self.openingText = openingText; self.url = url; self.visibility = visibility
        self.verified = verified; self.displayOrder = displayOrder
    }
}

public struct GitHubRepositoryChoice: Identifiable, Equatable, Sendable {
    public let repositoryID: String
    public var id: String { repositoryID }
    public let repositoryName: String
    public let title: String
    public let description: String
    public let mainLanguage: String?
    public let tags: [String]
    public let url: URL

    public init(repositoryID: String, repositoryName: String, title: String,
                description: String = "", mainLanguage: String? = nil, tags: [String] = [], url: URL) {
        self.repositoryID = repositoryID; self.repositoryName = repositoryName; self.title = title
        self.description = description; self.mainLanguage = mainLanguage; self.tags = tags; self.url = url
    }
}

public struct GitHubRepositoryPage: Equatable, Sendable {
    public let repositories: [GitHubRepositoryChoice]
    public let nextPage: Int?
    public init(repositories: [GitHubRepositoryChoice], nextPage: Int? = nil) {
        self.repositories = repositories; self.nextPage = nextPage
    }
}

public enum GitHubConnectionState: Equatable, Sendable {
    case notConnected, connecting, connected(handle: String?), failed
    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
    public var handle: String? {
        if case .connected(let handle) = self { return handle }
        return nil
    }
}

/// Identity and source metadata are server supplied; only approved fields are editable.
public struct LinkPreviewDraft: Equatable, Sendable {
    public let repositoryID: String
    public var sourceItemID: String { repositoryID }
    public let repositoryName: String
    public private(set) var existingLinkID: String?
    public let source: LinkSource
    public let url: URL
    public let verified: Bool
    public let sourceLabel: String
    public private(set) var replaceExisting = false
    public var title: String
    public var description: String
    public var mainLanguage: String?
    public var tags: [String]
    public var openingText: String
    public var visibility: VisibilityLevel?

    public init(repositoryID: String, repositoryName: String, source: LinkSource, url: URL, verified: Bool,
                sourceLabel: String, title: String, description: String = "",
                mainLanguage: String? = nil, tags: [String] = [], openingText: String = "") {
        self.repositoryID = repositoryID; self.repositoryName = repositoryName
        existingLinkID = nil; self.source = source; self.url = url; self.verified = verified
        self.sourceLabel = sourceLabel; self.title = title; self.description = description
        self.mainLanguage = mainLanguage; self.tags = tags; self.openingText = openingText; visibility = nil
    }

    public init(link: OwnLinkState) {
        repositoryID = link.sourceItemID ?? ""; repositoryName = link.repositoryName
        existingLinkID = link.id; source = link.source; url = link.url; verified = link.verified
        sourceLabel = link.sourceLabel; title = link.title; description = link.description
        mainLanguage = link.mainLanguage; tags = link.tags; openingText = link.openingText
        visibility = link.visibility
    }

    /// Acceptance preserves the owned row and visibility while adopting the canonical URL/name.
    public func replacingMetadata(with fresh: Self) -> Self {
        var result = fresh
        result.existingLinkID = existingLinkID
        result.visibility = visibility
        result.replaceExisting = true
        return result
    }
}

public enum LinkField: String, CaseIterable, Sendable {
    case sourceLabel, title, description, mainLanguage, tags, openingText, visibility
}

public enum LinkValidation {
    public static let titleLimit = 100
    public static let descriptionLimit = 200
    public static let openingTextLimit = 200
    public static let tagLimit = 10
    public static let tagLengthLimit = 30
    public static let languageLimit = 30
    public static let linkLimit = 10

    public static func count(_ value: String) -> Int { ProfileValidation.characterCount(value) }
    public static func invalidFields(_ draft: LinkPreviewDraft) -> [LinkField] {
        var result: [LinkField] = []
        if !ProfileValidation.validRequiredText(draft.title, limit: titleLimit) { result.append(.title) }
        if count(draft.description) > descriptionLimit { result.append(.description) }
        if count(draft.openingText) > openingTextLimit { result.append(.openingText) }
        if count(draft.mainLanguage ?? "") > languageLimit { result.append(.mainLanguage) }
        if draft.tags.count > tagLimit || draft.tags.contains(where: {
            !ProfileValidation.validRequiredText($0, limit: tagLengthLimit)
        }) { result.append(.tags) }
        if draft.visibility == nil { result.append(.visibility) }
        return result
    }
    public static func canAdd(count: Int) -> Bool { count >= 0 && count < linkLimit }
    public static func canDelete(count: Int, discoveryOn: Bool) -> Bool {
        count > 0 && (!discoveryOn || count > 1)
    }
    public static func canSave(_ draft: LinkPreviewDraft, linkCount: Int) -> Bool {
        invalidFields(draft).isEmpty && (draft.existingLinkID != nil || canAdd(count: linkCount))
    }
}

public struct GitHubRepositoryPaging: Equatable, Sendable {
    public private(set) var page = 1
    public private(set) var nextPage: Int?
    public private(set) var repositories: [GitHubRepositoryChoice] = []
    public init() {}
    public var previousPage: Int? { page > 1 ? page - 1 : nil }
    public mutating func receive(_ result: GitHubRepositoryPage, page: Int) {
        guard page > 0 else { return }
        self.page = page
        nextPage = result.nextPage.flatMap { $0 > page ? $0 : nil }
        repositories = result.repositories
    }
}

public enum FirstLinkStepGate {
    public static func hasLink(_ profile: OwnProfileState) -> Bool { profile.linkCount > 0 }
    public static func needsFirstLink(_ profile: OwnProfileState, enabled: Bool) -> Bool {
        enabled && !hasLink(profile)
    }
}

public struct LinkActionError: Error, Equatable, Sendable {
    public enum Code: Sendable { case unavailable, invalidInput, lastLink, limitReached, sourceUnavailable, prerequisiteMissing }
    public let code: Code
    public let fields: [LinkField]
    public let details: [String]
    public var isLastLink: Bool { code == .lastLink || (code == .prerequisiteMissing && details.contains("link")) }
    public func requires(_ detail: String) -> Bool { code == .prerequisiteMissing && details.contains(detail) }
    public init(code: Code, fields: [LinkField] = [], details: [String] = []) {
        self.code = code; self.fields = fields; self.details = details
    }
}

/// Composition supplies all I/O. No credentials, networking or persistence enter this package.
@MainActor
public struct LinkActions {
    public var loadLinks: @MainActor () async throws -> [OwnLinkState]
    public var loadConnection: @MainActor () async throws -> GitHubConnectionState
    public var connectGitHub: @MainActor () async throws -> GitHubConnectionState
    public var listRepositories: @MainActor (Int) async throws -> GitHubRepositoryPage
    public var previewRepository: @MainActor (GitHubRepositoryChoice) async throws -> LinkPreviewDraft
    public var saveRepository: @MainActor (LinkPreviewDraft, VisibilityLevel, Bool) async throws -> OwnLinkState
    public var updateLink: @MainActor (String, LinkPreviewDraft, VisibilityLevel) async throws -> OwnLinkState
    public var deleteLink: @MainActor (String) async throws -> [OwnLinkState]
    public var reorderLinks: @MainActor ([String]) async throws -> [OwnLinkState]
    public var refreshPreview: @MainActor (LinkPreviewDraft) async throws -> LinkPreviewDraft

    public init(loadLinks: @escaping @MainActor () async throws -> [OwnLinkState],
                loadConnection: @escaping @MainActor () async throws -> GitHubConnectionState,
                connectGitHub: @escaping @MainActor () async throws -> GitHubConnectionState,
                listRepositories: @escaping @MainActor (Int) async throws -> GitHubRepositoryPage,
                previewRepository: @escaping @MainActor (GitHubRepositoryChoice) async throws -> LinkPreviewDraft,
                saveRepository: @escaping @MainActor (LinkPreviewDraft, VisibilityLevel, Bool) async throws -> OwnLinkState,
                updateLink: @escaping @MainActor (String, LinkPreviewDraft, VisibilityLevel) async throws -> OwnLinkState,
                deleteLink: @escaping @MainActor (String) async throws -> [OwnLinkState],
                reorderLinks: @escaping @MainActor ([String]) async throws -> [OwnLinkState],
                refreshPreview: @escaping @MainActor (LinkPreviewDraft) async throws -> LinkPreviewDraft) {
        self.loadLinks = loadLinks; self.loadConnection = loadConnection; self.connectGitHub = connectGitHub
        self.listRepositories = listRepositories; self.previewRepository = previewRepository
        self.saveRepository = saveRepository; self.updateLink = updateLink; self.deleteLink = deleteLink
        self.reorderLinks = reorderLinks; self.refreshPreview = refreshPreview
    }
}
