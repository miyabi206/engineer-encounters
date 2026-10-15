import Foundation

/// Opaque block references deliberately carry no subject identity or profile snapshot.
public struct BlockEntryTransfer: Decodable, Sendable, Equatable {
    public let blockID: UUID
    public let placedDay: WireDay
    private enum CodingKeys: String, CodingKey { case blockID = "block_id", placedDay = "placed_day" }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        blockID = try fields.lowercaseUUID(forKey: .blockID)
        placedDay = try fields.decode(WireDay.self, forKey: .placedDay)
    }
}

public struct BlocksTransfer: Decodable, Sendable, Equatable {
    public let blocks: [BlockEntryTransfer]
    public let truncated: Bool
}

public struct UnblockedTransfer: Decodable, Sendable, Equatable {
    public let unblocked: Bool
    private enum CodingKeys: String, CodingKey { case unblocked }
    public init(from decoder: any Decoder) throws {
        unblocked = try decoder.container(keyedBy: CodingKeys.self).trueFlag(forKey: .unblocked)
    }
}

public enum EncounterReportReason: String, Codable, Sendable, CaseIterable {
    case spam, harassment, impersonation, other
}
public enum EncounterReportStatus: String, Codable, Sendable { case open }

public struct EncounterReportTransfer: Decodable, Sendable, Equatable {
    public let reportID: UUID
    public let status: EncounterReportStatus
    private enum CodingKeys: String, CodingKey { case reportID = "report_id", status }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        reportID = try fields.lowercaseUUID(forKey: .reportID)
        status = try fields.decode(EncounterReportStatus.self, forKey: .status)
    }
}

public struct SafetyService: Sendable {
    private let client: RemoteProcedureClient
    public init(client: RemoteProcedureClient) { self.client = client }
    public func blockEncounterPerson(encounterID: UUID) async throws -> BlockEntryTransfer {
        try await client.call("block_encounter_person", parameters: EncounterIDParameters(encounterID))
    }
    public func listBlocks() async throws -> BlocksTransfer {
        try await client.call("list_blocks", parameters: EmptyLinkParameters())
    }
    public func unblock(blockID: UUID) async throws -> UnblockedTransfer {
        struct Parameters: Encodable, Sendable { let block_id: String }
        return try await client.call("unblock", parameters: Parameters(block_id: blockID.uuidString.lowercased()))
    }
    public func reportEncounterPerson(encounterID: UUID, reason: EncounterReportReason,
                                      linkID: UUID? = nil) async throws -> EncounterReportTransfer {
        try await client.call("report_encounter_person", parameters: EncounterReportParameters(
            encounterID: encounterID, reason: reason, linkID: linkID))
    }
}

private struct EncounterReportParameters: Encodable, Sendable {
    let encounterID: UUID
    let reason: EncounterReportReason
    let linkID: UUID?
    private enum CodingKeys: String, CodingKey { case encounterID = "encounter_id", reason, linkID = "link_id" }
    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(encounterID.uuidString.lowercased(), forKey: .encounterID)
        try fields.encode(reason, forKey: .reason)
        try fields.encode(linkID?.uuidString.lowercased(), forKey: .linkID)
    }
}
