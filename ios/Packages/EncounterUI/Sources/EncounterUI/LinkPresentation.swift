import Foundation

public enum LinkSource: String, CaseIterable, Sendable {
    case github, qiita, zenn, other
}

/// Owner-only presentation data. Verification and reader identity are server supplied.
public struct OwnLinkState: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: LinkSource
    public var sourceLabel: String
    public var title: String
    public var description: String
    public var mainLanguage: String
    public var tags: [String]
    public var openingText: String
    public let url: URL
    public var visibility: VisibilityLevel?
    public let verified: Bool
    public var displayOrder: Int

    public init(id: String, source: LinkSource, sourceLabel: String, title: String,
                description: String = "", mainLanguage: String = "", tags: [String] = [],
                openingText: String = "", url: URL, visibility: VisibilityLevel? = nil,
                verified: Bool = false, displayOrder: Int = 0) {
        self.id = id; self.source = source; self.sourceLabel = sourceLabel; self.title = title
        self.description = description; self.mainLanguage = mainLanguage; self.tags = tags
        self.openingText = openingText; self.url = url; self.visibility = visibility
        self.verified = verified; self.displayOrder = displayOrder
    }
}

public struct GitHubRepositoryChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let ownerHandle: String
    public let name: String
    public let url: URL
    public let isPublic: Bool

    public init(id: String, ownerHandle: String, name: String, url: URL, isPublic: Bool = true) {
        self.id = id; self.ownerHandle = ownerHandle; self.name = name; self.url = url
        self.isPublic = isPublic
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
    case notConnected, connecting, connected(handle: String), failed
    public var handle: String? {
        if case .connected(let handle) = self { return handle }
        return nil
    }
}

/// Created only from a successful reader response or an existing owned link.
/// The preview token, original URL, source identity and verification cannot be edited.
public struct LinkPreviewDraft: Equatable, Sendable {
    public let previewID: String
    public let existingLinkID: String?
    public let source: LinkSource
    public let url: URL
    public let verified: Bool
    public var sourceLabel: String
    public var title: String
    public var description: String
    public var mainLanguage: String
    public var tags: [String]
    public var openingText: String
    public var visibility: VisibilityLevel?

    public init(previewID: String, source: LinkSource, url: URL, verified: Bool,
                sourceLabel: String, title: String, description: String = "",
                mainLanguage: String = "", tags: [String] = [], openingText: String = "") {
        self.previewID = previewID; existingLinkID = nil; self.source = source
        self.url = url; self.verified = verified; self.sourceLabel = sourceLabel; self.title = title
        self.description = description; self.mainLanguage = mainLanguage; self.tags = tags
        self.openingText = openingText; visibility = nil
    }

    public init(link: OwnLinkState) {
        previewID = link.id; existingLinkID = link.id; source = link.source; url = link.url
        verified = link.verified; sourceLabel = link.sourceLabel; title = link.title
        description = link.description; mainLanguage = link.mainLanguage; tags = link.tags
        openingText = link.openingText; visibility = link.visibility
    }

    /// Accept new reader values only after explicit confirmation. Keep owner-only visibility
    /// and the existing link identity; verification comes from the fresh reader response.
    public func replacingMetadata(with fresh: Self) -> Self {
        var result = self
        result.sourceLabel = fresh.sourceLabel; result.title = fresh.title
        result.description = fresh.description; result.mainLanguage = fresh.mainLanguage
        result.tags = fresh.tags; result.openingText = fresh.openingText
        return Self(identity: result, fresh: fresh)
    }

    private init(identity: Self, fresh: Self) {
        previewID = fresh.previewID; existingLinkID = identity.existingLinkID
        source = identity.source; url = identity.url; verified = fresh.verified
        sourceLabel = identity.sourceLabel; title = identity.title; description = identity.description
        mainLanguage = identity.mainLanguage; tags = identity.tags; openingText = identity.openingText
        visibility = identity.visibility
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
        if count(draft.mainLanguage) > languageLimit { result.append(.mainLanguage) }
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
    public mutating func receive(_ result: GitHubRepositoryPage, page: Int, handle: String) {
        guard page > 0 else { return }
        self.page = page
        nextPage = result.nextPage.flatMap { $0 > page ? $0 : nil }
        var seen: Set<String> = []
        repositories = result.repositories.filter {
            $0.isPublic && $0.ownerHandle.caseInsensitiveCompare(handle) == .orderedSame && seen.insert($0.id).inserted
        }
    }
}

public enum FirstLinkStepGate {
    public static func hasLink(_ profile: OwnProfileState) -> Bool { profile.linkCount > 0 }
    public static func needsFirstLink(_ profile: OwnProfileState, enabled: Bool) -> Bool {
        enabled && !hasLink(profile)
    }
}

public struct LinkActionError: Error, Equatable, Sendable {
    public enum Code: Sendable { case unavailable, invalidInput, lastLink, limitReached, sourceUnavailable }
    public let code: Code
    public let fields: [LinkField]
    public init(code: Code, fields: [LinkField] = []) { self.code = code; self.fields = fields }
}

/// Composition supplies all I/O. No credentials, networking or persistence enter this package.
@MainActor
public struct LinkActions {
    public var loadLinks: @MainActor () async throws -> [OwnLinkState]
    public var loadConnection: @MainActor () async throws -> GitHubConnectionState
    public var connectGitHub: @MainActor () async throws -> GitHubConnectionState
    public var listRepositories: @MainActor (Int) async throws -> GitHubRepositoryPage
    public var previewRepository: @MainActor (GitHubRepositoryChoice) async throws -> LinkPreviewDraft
    public var saveRepository: @MainActor (LinkPreviewDraft, VisibilityLevel) async throws -> OwnLinkState
    public var updateLink: @MainActor (String, LinkPreviewDraft, VisibilityLevel) async throws -> OwnLinkState
    public var deleteLink: @MainActor (String) async throws -> [OwnLinkState]
    public var reorderLinks: @MainActor ([String]) async throws -> [OwnLinkState]
    public var refreshPreview: @MainActor (LinkPreviewDraft) async throws -> LinkPreviewDraft

    public init(loadLinks: @escaping @MainActor () async throws -> [OwnLinkState],
                loadConnection: @escaping @MainActor () async throws -> GitHubConnectionState,
                connectGitHub: @escaping @MainActor () async throws -> GitHubConnectionState,
                listRepositories: @escaping @MainActor (Int) async throws -> GitHubRepositoryPage,
                previewRepository: @escaping @MainActor (GitHubRepositoryChoice) async throws -> LinkPreviewDraft,
                saveRepository: @escaping @MainActor (LinkPreviewDraft, VisibilityLevel) async throws -> OwnLinkState,
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
