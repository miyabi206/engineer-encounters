import Foundation

/// Stateless encounter procedures; all visibility and retention decisions belong to the server.
public struct EncounterService: Sendable {
    private let client: RemoteProcedureClient
    public init(client: RemoteProcedureClient) { self.client = client }

    public func getEncounterCard(encounterID: UUID) async throws -> EncounterCardTransfer {
        try await client.call("get_encounter_card", parameters: EncounterIDParameters(encounterID))
    }
    public func getEncounterFeed() async throws -> EncounterFeedTransfer {
        try await client.call("get_encounter_feed", parameters: EmptyLinkParameters())
    }
    public func listEncounterFavorites() async throws -> EncounterFeedTransfer {
        try await client.call("list_encounter_favorites", parameters: EmptyLinkParameters())
    }
    public func setEncounterFavorite(encounterID: UUID, favorite: Bool) async throws -> EncounterFavoriteTransfer {
        struct Parameters: Encodable, Sendable { let encounter_id: String; let favorite: Bool }
        return try await client.call("set_encounter_favorite", parameters: Parameters(
            encounter_id: encounterID.uuidString.lowercased(), favorite: favorite))
    }
    public func saveLink(encounterID: UUID, linkID: UUID) async throws -> SavedLinkStateTransfer {
        let result: SavedLinkStateTransfer = try await client.call("save_link", parameters: SavedLinkParameters(encounterID, linkID))
        guard result.saved else { throw BackendError.invalidResponse }
        return result
    }
    public func unsaveLink(encounterID: UUID, linkID: UUID) async throws -> SavedLinkStateTransfer {
        let result: SavedLinkStateTransfer = try await client.call("unsave_link", parameters: SavedLinkParameters(encounterID, linkID))
        guard !result.saved else { throw BackendError.invalidResponse }
        return result
    }
    public func listSavedLinks() async throws -> SavedLinksTransfer {
        try await client.call("list_saved_links", parameters: EmptyLinkParameters())
    }
    public func deleteEncounter(encounterID: UUID) async throws -> DeletedTransfer {
        try await client.call("delete_encounter", parameters: EncounterIDParameters(encounterID))
    }
}

struct EncounterIDParameters: Encodable, Sendable {
    let encounter_id: String
    init(_ id: UUID) { encounter_id = id.uuidString.lowercased() }
}

private struct SavedLinkParameters: Encodable, Sendable {
    let encounter_id: String
    let link_id: String
    init(_ encounterID: UUID, _ linkID: UUID) {
        encounter_id = encounterID.uuidString.lowercased()
        link_id = linkID.uuidString.lowercased()
    }
}
