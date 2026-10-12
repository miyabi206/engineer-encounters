import Foundation

/// Public GitHub reader actions. No caller identity, source URL or provider credential is accepted.
public struct GitHubLinksService: Sendable {
    private let client: EdgeFunctionClient
    public init(client: EdgeFunctionClient) { self.client = client }

    public func syncIdentity() async throws -> GitHubConnectionTransfer {
        struct Parameters: Encodable, Sendable { let action = "sync_identity" }
        return try await client.call("github-links", parameters: Parameters())
    }

    public func listRepositories(page: Int) async throws -> RepositoryPageTransfer {
        struct Parameters: Encodable, Sendable { let action = "list_repositories"; let page: Int }
        return try await client.call("github-links", parameters: Parameters(page: page))
    }

    public func previewRepository(repositoryID: String, repositoryName: String) async throws -> RepositoryPreviewTransfer {
        struct Parameters: Encodable, Sendable {
            let action = "preview_repository"; let repository_id: String; let repository_name: String
        }
        struct Result: Decodable, Sendable { let preview: RepositoryPreviewTransfer }
        let result: Result = try await client.call("github-links", parameters: Parameters(
            repository_id: repositoryID, repository_name: repositoryName))
        return result.preview
    }

    public func saveRepository(repositoryID: String, repositoryName: String, title: String, description: String,
                               mainLanguage: String?, tags: [String], openingText: String,
                               visibility: VisibilityLevel, replaceExisting: Bool) async throws -> LinkTransfer {
        struct Result: Decodable, Sendable { let link: LinkTransfer }
        let result: Result = try await client.call("github-links", parameters: SaveRepositoryParameters(
            repository_id: repositoryID, repository_name: repositoryName,
            replace_existing: replaceExisting, metadata: LinkMetadataParameters(
                title: title, description: description, main_language: mainLanguage, tags: tags,
                opening_text: openingText, visibility: visibility)))
        return result.link
    }

    public func refreshPreview(linkID: UUID) async throws -> RefreshRepositoryPreviewTransfer {
        struct Parameters: Encodable, Sendable { let action = "refresh_preview"; let link_id: String }
        return try await client.call("github-links", parameters: Parameters(link_id: linkID.uuidString.lowercased()))
    }
}

private struct SaveRepositoryParameters: Encodable, Sendable {
    let repository_id: String
    let repository_name: String
    let replace_existing: Bool
    let metadata: LinkMetadataParameters
    private enum CodingKeys: String, CodingKey { case action, repository_id, repository_name, replace_existing }
    func encode(to encoder: any Encoder) throws {
        try metadata.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode("save_repository", forKey: .action)
        try fields.encode(repository_id, forKey: .repository_id)
        try fields.encode(repository_name, forKey: .repository_name)
        try fields.encode(replace_existing, forKey: .replace_existing)
    }
}
