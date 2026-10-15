import Foundation

/// Only GitHub own links and verified repository previews are returned in Unit 5.
public enum LinkSource: String, Codable, Sendable { case github }
public enum LinkVerification: String, Codable, Sendable { case verified }

private func decodeUUID(_ value: String) throws -> UUID {
    guard value == value.lowercased(), let id = UUID(uuidString: value),
          id.uuidString.lowercased() == value else { throw WireValueError.invalidResponse }
    return id
}

private func decodeRepositoryID(_ value: String) throws -> String {
    guard let id = Int64(value), id > 0, String(id) == value else { throw WireValueError.invalidResponse }
    return value
}

/// Exact Link JSON at the server boundary.
public struct LinkTransfer: Codable, Sendable, Equatable {
    public let linkID: UUID
    public let source: LinkSource
    public let sourceItemID: String
    public let url: String
    public let title: String
    public let description: String
    public let mainLanguage: String?
    public let tags: [String]
    public let openingText: String
    public let visibility: VisibilityLevel
    public let verificationState: LinkVerification
    public let displayOrder: Int

    private enum CodingKeys: String, CodingKey {
        case linkID = "link_id"
        case source
        case sourceItemID = "source_item_id"
        case url
        case title
        case description
        case mainLanguage = "main_language"
        case tags
        case openingText = "opening_text"
        case visibility
        case verificationState = "verification_state"
        case displayOrder = "display_order"
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        linkID = try decodeUUID(fields.decode(String.self, forKey: .linkID))
        source = try fields.decode(LinkSource.self, forKey: .source)
        sourceItemID = try decodeRepositoryID(fields.decode(String.self, forKey: .sourceItemID))
        url = try fields.decode(String.self, forKey: .url)
        title = try fields.decode(String.self, forKey: .title)
        description = try fields.decode(String.self, forKey: .description)
        mainLanguage = try fields.decode(String?.self, forKey: .mainLanguage)
        tags = try fields.decode([String].self, forKey: .tags)
        openingText = try fields.decode(String.self, forKey: .openingText)
        visibility = try fields.decode(VisibilityLevel.self, forKey: .visibility)
        verificationState = try fields.decode(LinkVerification.self, forKey: .verificationState)
        displayOrder = try fields.decode(Int.self, forKey: .displayOrder)
        guard displayOrder >= 0 else { throw WireValueError.invalidResponse }
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(linkID.uuidString.lowercased(), forKey: .linkID)
        try fields.encode(source, forKey: .source)
        try fields.encode(sourceItemID, forKey: .sourceItemID)
        try fields.encode(url, forKey: .url)
        try fields.encode(title, forKey: .title)
        try fields.encode(description, forKey: .description)
        try fields.encode(mainLanguage, forKey: .mainLanguage)
        try fields.encode(tags, forKey: .tags)
        try fields.encode(openingText, forKey: .openingText)
        try fields.encode(visibility, forKey: .visibility)
        try fields.encode(verificationState, forKey: .verificationState)
        try fields.encode(displayOrder, forKey: .displayOrder)
    }
}

/// Exact GitHubConnection JSON at the server boundary.
public struct GitHubConnectionTransfer: Codable, Sendable, Equatable {
    public let connected: Bool
    public let handle: String?

    private enum CodingKeys: String, CodingKey {
        case connected
        case handle
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        connected = try fields.decode(Bool.self, forKey: .connected)
        handle = try fields.decode(String?.self, forKey: .handle)
        guard connected || handle == nil else { throw WireValueError.invalidResponse }
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(connected, forKey: .connected)
        try fields.encode(handle, forKey: .handle)
    }
}

/// Exact Repository JSON at the server boundary.
public struct RepositoryTransfer: Codable, Sendable, Equatable {
    public let repositoryID: String
    public let repositoryName: String
    public let title: String
    public let description: String
    public let mainLanguage: String?
    public let tags: [String]
    public let url: String

    private enum CodingKeys: String, CodingKey {
        case repositoryID = "repository_id"
        case repositoryName = "repository_name"
        case title
        case description
        case mainLanguage = "main_language"
        case tags
        case url
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        repositoryID = try decodeRepositoryID(fields.decode(String.self, forKey: .repositoryID))
        repositoryName = try fields.decode(String.self, forKey: .repositoryName)
        title = try fields.decode(String.self, forKey: .title)
        description = try fields.decode(String.self, forKey: .description)
        mainLanguage = try fields.decode(String?.self, forKey: .mainLanguage)
        tags = try fields.decode([String].self, forKey: .tags)
        url = try fields.decode(String.self, forKey: .url)
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(repositoryID, forKey: .repositoryID)
        try fields.encode(repositoryName, forKey: .repositoryName)
        try fields.encode(title, forKey: .title)
        try fields.encode(description, forKey: .description)
        try fields.encode(mainLanguage, forKey: .mainLanguage)
        try fields.encode(tags, forKey: .tags)
        try fields.encode(url, forKey: .url)
    }
}

/// Exact RepositoryPreview JSON at the server boundary.
public struct RepositoryPreviewTransfer: Codable, Sendable, Equatable {
    public let repositoryID: String
    public let repositoryName: String
    public let title: String
    public let description: String
    public let mainLanguage: String?
    public let tags: [String]
    public let url: String
    public let openingText: String
    public let verificationState: LinkVerification

    private enum CodingKeys: String, CodingKey {
        case repositoryID = "repository_id"
        case repositoryName = "repository_name"
        case title
        case description
        case mainLanguage = "main_language"
        case tags
        case url
        case openingText = "opening_text"
        case verificationState = "verification_state"
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        repositoryID = try decodeRepositoryID(fields.decode(String.self, forKey: .repositoryID))
        repositoryName = try fields.decode(String.self, forKey: .repositoryName)
        title = try fields.decode(String.self, forKey: .title)
        description = try fields.decode(String.self, forKey: .description)
        mainLanguage = try fields.decode(String?.self, forKey: .mainLanguage)
        tags = try fields.decode([String].self, forKey: .tags)
        url = try fields.decode(String.self, forKey: .url)
        openingText = try fields.decode(String.self, forKey: .openingText)
        verificationState = try fields.decode(LinkVerification.self, forKey: .verificationState)
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(repositoryID, forKey: .repositoryID)
        try fields.encode(repositoryName, forKey: .repositoryName)
        try fields.encode(title, forKey: .title)
        try fields.encode(description, forKey: .description)
        try fields.encode(mainLanguage, forKey: .mainLanguage)
        try fields.encode(tags, forKey: .tags)
        try fields.encode(url, forKey: .url)
        try fields.encode(openingText, forKey: .openingText)
        try fields.encode(verificationState, forKey: .verificationState)
    }
}

/// One repository selection page. An empty filtered page can still have a next page.
public struct RepositoryPageTransfer: Codable, Sendable, Equatable {
    public let repositories: [RepositoryTransfer]
    public let nextPage: Int?
    private enum CodingKeys: String, CodingKey { case repositories, nextPage = "next_page" }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try fields.decode([RepositoryTransfer].self, forKey: .repositories)
        nextPage = try fields.decode(Int?.self, forKey: .nextPage)
        guard nextPage.map({ (1...1000).contains($0) }) ?? true else { throw WireValueError.invalidResponse }
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(repositories, forKey: .repositories)
        try fields.encode(nextPage, forKey: .nextPage)
    }
}

public struct RefreshRepositoryPreviewTransfer: Codable, Sendable, Equatable {
    public let linkID: UUID
    public let preview: RepositoryPreviewTransfer
    private enum CodingKeys: String, CodingKey { case linkID = "link_id", preview }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        linkID = try decodeUUID(fields.decode(String.self, forKey: .linkID))
        preview = try fields.decode(RepositoryPreviewTransfer.self, forKey: .preview)
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(linkID.uuidString.lowercased(), forKey: .linkID)
        try fields.encode(preview, forKey: .preview)
    }
}
