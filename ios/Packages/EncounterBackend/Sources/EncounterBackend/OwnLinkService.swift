import Foundation

/// Typed own-link procedures; metadata validation remains authoritative on the server.
public struct OwnLinkService: Sendable {
    private let client: RemoteProcedureClient
    public init(client: RemoteProcedureClient) { self.client = client }

    public func listOwnLinks() async throws -> [LinkTransfer] {
        try await client.call("list_own_links", parameters: EmptyLinkParameters())
    }

    public func updateOwnLink(linkID: UUID, title: String, description: String, mainLanguage: String?,
                              tags: [String], openingText: String, visibility: VisibilityLevel) async throws -> LinkTransfer {
        let parameters = UpdateLinkParameters(link_id: linkID.uuidString.lowercased(), metadata: LinkMetadataParameters(
            title: title, description: description, main_language: mainLanguage, tags: tags,
            opening_text: openingText, visibility: visibility))
        return try await client.call("update_own_link", parameters: parameters)
    }

    public func deleteOwnLink(linkID: UUID) async throws {
        struct Result: Decodable, Sendable { let deleted: Bool }
        let result: Result = try await client.call("delete_own_link", parameters: LinkIDParameters(linkID))
        guard result.deleted else { throw BackendError.invalidResponse }
    }

    public func reorderOwnLinks(linkIDs: [UUID]) async throws -> [LinkTransfer] {
        struct Parameters: Encodable, Sendable { let link_ids: [String] }
        return try await client.call("reorder_own_links", parameters: Parameters(link_ids: linkIDs.map { $0.uuidString.lowercased() }))
    }

    public func getGitHubConnection() async throws -> GitHubConnectionTransfer {
        try await client.call("get_github_connection", parameters: EmptyLinkParameters())
    }

    public func disconnectGitHub() async throws -> GitHubConnectionTransfer {
        let connection: GitHubConnectionTransfer = try await client.call("disconnect_github", parameters: EmptyLinkParameters())
        guard !connection.connected else { throw BackendError.invalidResponse }
        return connection
    }
}

struct EmptyLinkParameters: Encodable, Sendable {}
struct LinkIDParameters: Encodable, Sendable {
    let link_id: String
    init(_ id: UUID) { link_id = id.uuidString.lowercased() }
}

/// Required nullable metadata must encode main_language as null rather than omit it.
struct LinkMetadataParameters: Encodable, Sendable {
    let title: String
    let description: String
    let main_language: String?
    let tags: [String]
    let opening_text: String
    let visibility: VisibilityLevel
    private enum CodingKeys: String, CodingKey { case title, description, main_language, tags, opening_text, visibility }
    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(title, forKey: .title)
        try fields.encode(description, forKey: .description)
        try fields.encode(main_language, forKey: .main_language)
        try fields.encode(tags, forKey: .tags)
        try fields.encode(opening_text, forKey: .opening_text)
        try fields.encode(visibility, forKey: .visibility)
    }
}

private struct UpdateLinkParameters: Encodable, Sendable {
    let link_id: String
    let metadata: LinkMetadataParameters
    private enum CodingKeys: String, CodingKey { case link_id }
    func encode(to encoder: any Encoder) throws {
        try metadata.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(link_id, forKey: .link_id)
    }
}
