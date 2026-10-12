import Foundation

/// A caller-local calendar date, deliberately without an encounter timestamp or location.
public struct EncounterDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    public func formatted(locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        return formatter.string(from: date)
    }
}

public enum EncounterKind: String, CaseIterable, Sendable { case ambient, session, qr }

public struct EncounterLinkCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let title: String
    public let description: String?
    public let tags: [String]
    public let mainLanguage: String?
    public let openingText: String?
    public let url: URL
    public let verified: Bool

    public init(id: String, source: String, title: String, description: String? = nil,
                tags: [String] = [], mainLanguage: String? = nil, openingText: String? = nil,
                url: URL, verified: Bool = false) {
        self.id = id; self.source = source; self.title = title
        self.description = EncounterCard.nonempty(description)
        self.tags = tags.filter { EncounterCard.nonempty($0) != nil }
        self.mainLanguage = EncounterCard.nonempty(mainLanguage)
        self.openingText = EncounterCard.nonempty(openingText)
        self.url = url; self.verified = verified
    }
}

/// Only currently authorized fields belong here. Visibility decisions stay with the caller.
/// An eligible all-private shell cannot carry an inferred identity or link preview.
public struct EncounterCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: EncounterKind
    public let day: EncounterDay
    public let displayName: String?
    public let introduction: String?
    public let interests: [InterestOption]
    public let purposes: Set<ProfilePurpose>
    public let contactDetail: String?
    public let links: [EncounterLinkCard]
    public let isShell: Bool

    public init(id: String, kind: EncounterKind, day: EncounterDay, displayName: String? = nil,
                introduction: String? = nil, interests: [InterestOption] = [],
                purposes: Set<ProfilePurpose> = [],
                contactDetail: String? = nil, links: [EncounterLinkCard] = [],
                isShell: Bool = false) {
        self.id = id; self.kind = kind; self.day = day; self.isShell = isShell
        self.displayName = isShell ? nil : Self.nonempty(displayName)
        self.introduction = isShell ? nil : Self.nonempty(introduction)
        self.interests = isShell ? [] : interests
        self.purposes = isShell ? [] : purposes
        self.contactDetail = isShell ? nil : Self.nonempty(contactDetail)
        self.links = isShell ? [] : links
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

/// The single-card contract includes the caller's state, separate from visible card fields.
public struct EncounterDetail: Equatable, Sendable {
    public let card: EncounterCard
    public var favorite: Bool
    public var savedLinkIDs: Set<String>

    public init(card: EncounterCard, favorite: Bool, savedLinkIDs: Set<String>) {
        self.card = card; self.favorite = favorite
        self.savedLinkIDs = savedLinkIDs.intersection(Set(card.links.map(\.id)))
    }
}

public struct EncounterFeedCard: Identifiable, Equatable, Sendable {
    public var id: String { card.id }
    public var day: EncounterDay { card.day }
    public let card: EncounterCard
    public var favorite: Bool
    public let sharedInterestIDs: Set<String>?

    public init(card: EncounterCard, favorite: Bool, sharedInterestIDs: Set<String>? = nil) {
        self.card = card; self.favorite = favorite
        self.sharedInterestIDs = card.isShell ? nil : sharedInterestIDs.map { $0.intersection(Set(card.interests.map(\.id))) }
    }

    public var sharedInterests: [InterestOption] {
        card.interests.filter { sharedInterestIDs?.contains($0.id) == true }
    }
}

public struct EncounterCardList: Equatable, Sendable {
    public let cards: [EncounterFeedCard]
    public let truncated: Bool
    public init(cards: [EncounterFeedCard], truncated: Bool) {
        self.cards = cards; self.truncated = truncated
    }
}

public struct EncounterDayGroup: Identifiable, Equatable, Sendable {
    public var id: EncounterDay { day }
    public let day: EncounterDay
    public let cards: [EncounterFeedCard]

    /// The caller supplies matching order; grouping never sorts cards inside a day.
    public static func grouped(_ cards: [EncounterFeedCard]) -> [Self] {
        let groups = Dictionary(grouping: cards, by: \.day)
        return groups.keys.sorted(by: >).map { Self(day: $0, cards: groups[$0] ?? []) }
    }
}

public struct EncounterSavedLink: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let encounterID: String
        public let linkID: String
        public init(encounterID: String, linkID: String) {
            self.encounterID = encounterID; self.linkID = linkID
        }
    }
    public var id: ID { ID(encounterID: encounterID, linkID: link.id) }
    public let encounterID: String
    public let day: EncounterDay
    public let kind: EncounterKind
    public let link: EncounterLinkCard
    public init(encounterID: String, day: EncounterDay, kind: EncounterKind, link: EncounterLinkCard) {
        self.encounterID = encounterID; self.day = day; self.kind = kind; self.link = link
    }
}

public struct EncounterSavedLinkList: Equatable, Sendable {
    public let links: [EncounterSavedLink]
    public let truncated: Bool
    public init(links: [EncounterSavedLink], truncated: Bool) {
        self.links = links; self.truncated = truncated
    }
}

public struct EncounterFavoriteResult: Equatable, Sendable {
    public let encounterID: String
    public let favorite: Bool
    public init(encounterID: String, favorite: Bool) {
        self.encounterID = encounterID; self.favorite = favorite
    }
}

public struct EncounterSavedResult: Equatable, Sendable {
    public let encounterID: String
    public let linkID: String
    public let saved: Bool
    public init(encounterID: String, linkID: String, saved: Bool) {
        self.encounterID = encounterID; self.linkID = linkID; self.saved = saved
    }
}

public enum DiscoverActionError: Error, Equatable, Sendable {
    case authorizationFailed, notFound, unavailable
}

/// Composition supplies I/O. These results mirror the server contract; no card is persisted.
@MainActor
public struct DiscoverActions {
    public var loadFeed: @MainActor () async throws -> EncounterCardList
    public var loadCard: @MainActor (String) async throws -> EncounterDetail?
    public var setFavorite: @MainActor (String, Bool) async throws -> EncounterFavoriteResult
    public var saveLink: @MainActor (String, String) async throws -> EncounterSavedResult
    public var unsaveLink: @MainActor (String, String) async throws -> EncounterSavedResult
    public var deleteEncounter: @MainActor (String) async throws -> Void
    public var loadFavorites: @MainActor () async throws -> EncounterCardList
    public var loadSavedLinks: @MainActor () async throws -> EncounterSavedLinkList

    public init(loadFeed: @escaping @MainActor () async throws -> EncounterCardList,
                loadCard: @escaping @MainActor (String) async throws -> EncounterDetail?,
                setFavorite: @escaping @MainActor (String, Bool) async throws -> EncounterFavoriteResult,
                saveLink: @escaping @MainActor (String, String) async throws -> EncounterSavedResult,
                unsaveLink: @escaping @MainActor (String, String) async throws -> EncounterSavedResult,
                deleteEncounter: @escaping @MainActor (String) async throws -> Void,
                loadFavorites: @escaping @MainActor () async throws -> EncounterCardList,
                loadSavedLinks: @escaping @MainActor () async throws -> EncounterSavedLinkList) {
        self.loadFeed = loadFeed; self.loadCard = loadCard; self.setFavorite = setFavorite
        self.saveLink = saveLink; self.unsaveLink = unsaveLink; self.deleteEncounter = deleteEncounter
        self.loadFavorites = loadFavorites; self.loadSavedLinks = loadSavedLinks
    }
}

/// Each tab's stack and the session/QR/safety destinations belong to composition.
@MainActor
public struct DiscoverNavigationActions {
    public var openEncounter: @MainActor (String) -> Void
    public var openFavorites: @MainActor () -> Void
    public var openSession: @MainActor () -> Void
    public var openQR: @MainActor () -> Void
    public var openDiscoverySettings: @MainActor () -> Void
    public var openProfileEditing: @MainActor () -> Void
    public var openReportOrBlock: @MainActor (EncounterCard) -> Void
    public var reportImpersonation: @MainActor (EncounterCard, String) -> Void
    public var openSample: @MainActor () -> Void
    public var openOwnLinks: @MainActor () -> Void
    public var openSystemSettings: @MainActor () -> Void
    public var openBluetoothRecovery: @MainActor () -> Void
    public var back: @MainActor () -> Void
    /// Caller routes to the originating S06 or S10, also used for a missing encounter.
    public var encounterRemoved: @MainActor () -> Void

    public init(openEncounter: @escaping @MainActor (String) -> Void,
                openFavorites: @escaping @MainActor () -> Void,
                openSession: @escaping @MainActor () -> Void, openQR: @escaping @MainActor () -> Void,
                openDiscoverySettings: @escaping @MainActor () -> Void,
                openProfileEditing: @escaping @MainActor () -> Void,
                openReportOrBlock: @escaping @MainActor (EncounterCard) -> Void,
                reportImpersonation: @escaping @MainActor (EncounterCard, String) -> Void,
                openSample: @escaping @MainActor () -> Void,
                openOwnLinks: @escaping @MainActor () -> Void,
                openSystemSettings: @escaping @MainActor () -> Void,
                openBluetoothRecovery: @escaping @MainActor () -> Void,
                back: @escaping @MainActor () -> Void, encounterRemoved: @escaping @MainActor () -> Void) {
        self.openEncounter = openEncounter; self.openFavorites = openFavorites
        self.openSession = openSession; self.openQR = openQR
        self.openDiscoverySettings = openDiscoverySettings; self.openProfileEditing = openProfileEditing
        self.openReportOrBlock = openReportOrBlock; self.reportImpersonation = reportImpersonation
        self.openSample = openSample
        self.openOwnLinks = openOwnLinks; self.openSystemSettings = openSystemSettings
        self.openBluetoothRecovery = openBluetoothRecovery
        self.back = back; self.encounterRemoved = encounterRemoved
    }
}
