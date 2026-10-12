import Foundation

/// A calendar date on the wire, without a time or a time zone.
public struct WireDay: Codable, Sendable, Equatable, RawRepresentable {
    public let rawValue: String
    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }),
              let year = Int(rawValue.prefix(4)), year > 0,
              let month = Int(rawValue.dropFirst(5).prefix(2)), (1...12).contains(month),
              let day = Int(rawValue.suffix(2)) else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        self.rawValue = rawValue
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let day = Self(rawValue: value) else { throw WireValueError.invalidResponse }
        self = day
    }
    public func encode(to encoder: any Encoder) throws {
        var field = encoder.singleValueContainer()
        try field.encode(rawValue)
    }
}

extension KeyedDecodingContainer {
    func lowercaseUUID(forKey key: Key) throws -> UUID {
        let value = try decode(String.self, forKey: key)
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else {
            throw WireValueError.invalidResponse
        }
        return id
    }

    /// Protected fields may be absent, but null is not an authorized value.
    func protectedValue<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        contains(key) ? try decode(type, forKey: key) : nil
    }

    func trueFlag(forKey key: Key) throws -> Bool {
        guard try decode(Bool.self, forKey: key) else { throw WireValueError.invalidResponse }
        return true
    }
}

public enum EncounterKind: String, Codable, Sendable { case ambient, session, qr }
public enum VisibleLinkVerification: String, Codable, Sendable { case verified, unverified }

/// Other-person link metadata authorized by the server, without owner metadata.
public struct VisibleLinkTransfer: Decodable, Sendable, Equatable {
    public let linkID: UUID
    public let source: String
    public let url: String
    public let title: String
    public let description: String
    public let mainLanguage: String?
    public let tags: [String]
    public let openingText: String
    public let verificationState: VisibleLinkVerification
    private enum CodingKeys: String, CodingKey {
        case linkID = "link_id", source, url, title, description, mainLanguage = "main_language"
        case tags, openingText = "opening_text", verificationState = "verification_state"
    }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        linkID = try fields.lowercaseUUID(forKey: .linkID)
        source = try fields.decode(String.self, forKey: .source)
        url = try fields.decode(String.self, forKey: .url)
        title = try fields.decode(String.self, forKey: .title)
        description = try fields.decode(String.self, forKey: .description)
        mainLanguage = try fields.decode(String?.self, forKey: .mainLanguage)
        tags = try fields.decode([String].self, forKey: .tags)
        openingText = try fields.decode(String.self, forKey: .openingText)
        verificationState = try fields.decode(VisibleLinkVerification.self, forKey: .verificationState)
    }
}

/// The common Card fields. Forbidden fields remain absent, including on shell cards.
public struct CardTransfer: Decodable, Sendable, Equatable {
    public let encounterID: UUID
    public let kind: EncounterKind
    public let day: WireDay
    public let displayName: String?
    public let introduction: String?
    public let contactDetail: String?
    public let interests: [String]?
    public let purposes: [ProfilePurpose]?
    public let links: [VisibleLinkTransfer]?
    public let shell: Bool?
    private enum CodingKeys: String, CodingKey {
        case encounterID = "encounter_id", kind, day, displayName = "display_name", introduction
        case contactDetail = "contact_detail", interests, purposes, links, shell
    }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        encounterID = try fields.lowercaseUUID(forKey: .encounterID)
        kind = try fields.decode(EncounterKind.self, forKey: .kind)
        day = try fields.decode(WireDay.self, forKey: .day)
        displayName = try fields.protectedValue(String.self, forKey: .displayName)
        introduction = try fields.protectedValue(String.self, forKey: .introduction)
        contactDetail = try fields.protectedValue(String.self, forKey: .contactDetail)
        interests = try fields.protectedValue([String].self, forKey: .interests)
        purposes = try fields.protectedValue([ProfilePurpose].self, forKey: .purposes)
        links = try fields.protectedValue([VisibleLinkTransfer].self, forKey: .links)
        shell = try fields.protectedValue(Bool.self, forKey: .shell)
        let hasFields = displayName != nil || introduction != nil || contactDetail != nil
            || interests != nil || purposes != nil || links != nil
        guard links.map({ !$0.isEmpty }) ?? true,
              hasFields ? shell == nil : shell == true else { throw WireValueError.invalidResponse }
    }
}

/// Flattened Card plus the caller's own encounter state (the binding detail amendment).
public struct EncounterCardTransfer: Decodable, Sendable, Equatable {
    public let card: CardTransfer
    public let favorite: Bool
    public let savedLinkIDs: [UUID]
    private enum CodingKeys: String, CodingKey { case favorite, savedLinkIDs = "saved_link_ids" }
    public init(from decoder: any Decoder) throws {
        card = try CardTransfer(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        favorite = try fields.decode(Bool.self, forKey: .favorite)
        let ids = try fields.decode([String].self, forKey: .savedLinkIDs)
        savedLinkIDs = try ids.map { value in
            guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else {
                throw WireValueError.invalidResponse
            }
            return id
        }
        guard Set(savedLinkIDs).isSubset(of: Set(card.links?.map(\.linkID) ?? [])) else {
            throw WireValueError.invalidResponse
        }
    }
}

/// Flattened Card plus favorite and the authorized shared-interest intersection.
public struct FeedCardTransfer: Decodable, Sendable, Equatable {
    public let card: CardTransfer
    public let favorite: Bool
    public let sharedInterestIDs: [String]?
    private enum CodingKeys: String, CodingKey { case favorite, sharedInterestIDs = "shared_interest_ids" }
    public init(from decoder: any Decoder) throws {
        card = try CardTransfer(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        favorite = try fields.decode(Bool.self, forKey: .favorite)
        sharedInterestIDs = try fields.protectedValue([String].self, forKey: .sharedInterestIDs)
        guard sharedInterestIDs == nil || card.interests != nil else { throw WireValueError.invalidResponse }
    }
}

public struct EncounterFeedTransfer: Decodable, Sendable, Equatable {
    public let cards: [FeedCardTransfer]
    public let truncated: Bool
}

public struct EncounterFavoriteTransfer: Decodable, Sendable, Equatable {
    public let encounterID: UUID
    public let favorite: Bool
    private enum CodingKeys: String, CodingKey { case encounterID = "encounter_id", favorite }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        encounterID = try fields.lowercaseUUID(forKey: .encounterID)
        favorite = try fields.decode(Bool.self, forKey: .favorite)
    }
}

public struct SavedLinkStateTransfer: Decodable, Sendable, Equatable {
    public let encounterID: UUID
    public let linkID: UUID
    public let saved: Bool
    private enum CodingKeys: String, CodingKey { case encounterID = "encounter_id", linkID = "link_id", saved }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        encounterID = try fields.lowercaseUUID(forKey: .encounterID)
        linkID = try fields.lowercaseUUID(forKey: .linkID)
        saved = try fields.decode(Bool.self, forKey: .saved)
    }
}

public struct SavedLinkReferenceTransfer: Decodable, Sendable, Equatable {
    public let encounterID: UUID
    public let day: WireDay
    public let kind: EncounterKind
    public let link: VisibleLinkTransfer
    private enum CodingKeys: String, CodingKey { case encounterID = "encounter_id", day, kind, link }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        encounterID = try fields.lowercaseUUID(forKey: .encounterID)
        day = try fields.decode(WireDay.self, forKey: .day)
        kind = try fields.decode(EncounterKind.self, forKey: .kind)
        link = try fields.decode(VisibleLinkTransfer.self, forKey: .link)
    }
}

public struct SavedLinksTransfer: Decodable, Sendable, Equatable {
    public let links: [SavedLinkReferenceTransfer]
    public let truncated: Bool
}

public struct DeletedTransfer: Decodable, Sendable, Equatable {
    public let deleted: Bool
    private enum CodingKeys: String, CodingKey { case deleted }
    public init(from decoder: any Decoder) throws {
        deleted = try decoder.container(keyedBy: CodingKeys.self).trueFlag(forKey: .deleted)
    }
}
