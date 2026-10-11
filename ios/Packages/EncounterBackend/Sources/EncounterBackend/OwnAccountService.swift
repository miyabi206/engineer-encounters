import Foundation

/// The purposes accepted by the own-account contract.
public enum ProfilePurpose: String, Codable, Sendable, CaseIterable {
    case discovery, collaboration
}

/// The server's field visibility levels.
public enum VisibilityLevel: String, Codable, Sendable, CaseIterable {
    case everyoneEligible = "everyone_eligible"
    case compatibleOnly = "compatible_only"
    case `private`
}

/// Profile fields whose visibility can be changed.
public enum ProfileField: String, Codable, Sendable, CaseIterable {
    case displayName = "display_name"
    case introduction, interests, purposes
    case contactDetail = "contact_detail"
}

/// Operator-controlled account moderation state.
public enum ModerationState: String, Codable, Sendable, CaseIterable {
    case active, hidden, suspended
}

/// The five visibility keys returned by get_own_profile.
public struct ProfileVisibility: Decodable, Sendable, Equatable {
    public let displayName: VisibilityLevel
    public let introduction: VisibilityLevel
    public let interests: VisibilityLevel
    public let purposes: VisibilityLevel
    public let contactDetail: VisibilityLevel

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name", introduction, interests, purposes, contactDetail = "contact_detail"
    }

    public subscript(field: ProfileField) -> VisibilityLevel {
        switch field {
        case .displayName: displayName
        case .introduction: introduction
        case .interests: interests
        case .purposes: purposes
        case .contactDetail: contactDetail
        }
    }
}

/// Current discovery prerequisites as evaluated by the server.
public struct ProfilePrerequisites: Decodable, Sendable, Equatable {
    public let displayName: Bool
    public let introduction: Bool
    public let interest: Bool
    public let link: Bool

    private enum CodingKeys: String, CodingKey { case displayName = "display_name", introduction, interest, link }
}

/// The caller's complete profile, including empty values before declarations.
public struct OwnProfile: Decodable, Sendable, Equatable {
    public let displayName: String
    public let introduction: String
    public let contactDetail: String
    public let interests: [String]
    public let purposes: [ProfilePurpose]
    public let minimumSharedInterests: Int
    public let fieldVisibility: ProfileVisibility
    public let discoveryOn: Bool
    public let linkCount: Int
    public let prerequisites: ProfilePrerequisites
    public let declarationsRecorded: Bool
    public let timeZone: String?
    public let moderationState: ModerationState?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name", introduction, contactDetail = "contact_detail", interests, purposes
        case minimumSharedInterests = "minimum_shared_interests", fieldVisibility = "field_visibility"
        case discoveryOn = "discovery_on", linkCount = "link_count", prerequisites
        case declarationsRecorded = "declarations_recorded", timeZone = "time_zone", moderationState = "moderation_state"
    }
}

/// One ordered curated interest returned by list_interests.
public struct CuratedInterest: Decodable, Sendable, Equatable, Identifiable {
    public let interestID: String
    public let labelJA: String
    public let labelEN: String
    public let displayOrder: Int
    public var id: String { interestID }

    private enum CodingKeys: String, CodingKey {
        case interestID = "interest_id", labelJA = "label_ja", labelEN = "label_en", displayOrder = "display_order"
    }
}

/// Typed calls for the caller's profile; validation remains authoritative on the server.
public struct OwnAccountService: Sendable {
    private let client: RemoteProcedureClient

    public init(client: RemoteProcedureClient) { self.client = client }

    public func acceptDeclarations(age18: Bool, termsVersion: String, privacyVersion: String) async throws {
        struct Parameters: Encodable, Sendable {
            let age_18: Bool
            let terms_version: String
            let privacy_version: String
        }
        try await client.call("accept_declarations", parameters: Parameters(
            age_18: age18, terms_version: termsVersion, privacy_version: privacyVersion
        ))
    }

    public func registerTimeZone(_ timeZone: String) async throws {
        struct Parameters: Encodable, Sendable { let time_zone: String }
        try await client.call("register_time_zone", parameters: Parameters(time_zone: timeZone))
    }

    public func getOwnProfile() async throws -> OwnProfile {
        try await client.call("get_own_profile", parameters: EmptyParameters())
    }

    public func updateOwnProfile(displayName: String, introduction: String, contactDetail: String) async throws {
        struct Parameters: Encodable, Sendable {
            let display_name: String
            let introduction: String
            let contact_detail: String
        }
        try await client.call("update_own_profile", parameters: Parameters(
            display_name: displayName, introduction: introduction, contact_detail: contactDetail
        ))
    }

    public func setOwnInterests(_ interestIDs: [String]) async throws {
        struct Parameters: Encodable, Sendable { let interest_ids: [String] }
        try await client.call("set_own_interests", parameters: Parameters(interest_ids: interestIDs))
    }

    public func setOwnPurposes(_ purposes: [ProfilePurpose]) async throws {
        struct Parameters: Encodable, Sendable { let purposes: [ProfilePurpose] }
        try await client.call("set_own_purposes", parameters: Parameters(purposes: purposes))
    }

    public func setMinimumSharedInterests(_ value: Int) async throws {
        struct Parameters: Encodable, Sendable { let value: Int }
        try await client.call("set_minimum_shared_interests", parameters: Parameters(value: value))
    }

    public func setFieldVisibility(field: ProfileField, level: VisibilityLevel) async throws {
        struct Parameters: Encodable, Sendable { let field: ProfileField; let level: VisibilityLevel }
        try await client.call("set_field_visibility", parameters: Parameters(field: field, level: level))
    }

    public func setDiscovery(enabled: Bool) async throws {
        struct Parameters: Encodable, Sendable { let enabled: Bool }
        try await client.call("set_discovery", parameters: Parameters(enabled: enabled))
    }

    public func listInterests() async throws -> [CuratedInterest] {
        try await client.call("list_interests", parameters: EmptyParameters())
    }
}

private struct EmptyParameters: Encodable, Sendable {}
