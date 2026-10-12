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
    public var saved: Bool

    public init(id: String, source: String, title: String, description: String? = nil,
                tags: [String] = [], mainLanguage: String? = nil, openingText: String? = nil,
                url: URL, verified: Bool = false, saved: Bool = false) {
        self.id = id; self.source = source; self.title = title
        self.description = EncounterCard.nonempty(description)
        self.tags = tags.filter { EncounterCard.nonempty($0) != nil }
        self.mainLanguage = EncounterCard.nonempty(mainLanguage)
        self.openingText = EncounterCard.nonempty(openingText)
        self.url = url; self.verified = verified; self.saved = saved
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
    public let sharedInterestIDs: Set<String>
    public let purposes: Set<ProfilePurpose>
    public let contactDetail: String?
    public internal(set) var links: [EncounterLinkCard]
    public var favorite: Bool
    public let isShell: Bool

    public init(id: String, kind: EncounterKind, day: EncounterDay, displayName: String? = nil,
                introduction: String? = nil, interests: [InterestOption] = [],
                sharedInterestIDs: Set<String> = [], purposes: Set<ProfilePurpose> = [],
                contactDetail: String? = nil, links: [EncounterLinkCard] = [],
                favorite: Bool = false, isShell: Bool = false) {
        self.id = id; self.kind = kind; self.day = day; self.isShell = isShell
        self.displayName = isShell ? nil : Self.nonempty(displayName)
        self.introduction = isShell ? nil : Self.nonempty(introduction)
        self.interests = isShell ? [] : interests
        self.sharedInterestIDs = isShell ? [] : sharedInterestIDs.intersection(Set(interests.map(\.id)))
        self.purposes = isShell ? [] : purposes
        self.contactDetail = isShell ? nil : Self.nonempty(contactDetail)
        self.links = isShell ? [] : links; self.favorite = favorite
    }

    public var sharedInterests: [InterestOption] { interests.filter { sharedInterestIDs.contains($0.id) } }

    static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

public struct EncounterDayGroup: Identifiable, Equatable, Sendable {
    public var id: EncounterDay { day }
    public let day: EncounterDay
    public let cards: [EncounterCard]

    /// The caller supplies matching order; grouping never sorts cards inside a day.
    public static func grouped(_ cards: [EncounterCard]) -> [Self] {
        let groups = Dictionary(grouping: cards, by: \.day)
        return groups.keys.sorted(by: >).map { Self(day: $0, cards: groups[$0] ?? []) }
    }
}

public struct EncounterSavedLink: Identifiable, Equatable, Sendable {
    public var id: String { link.id }
    public let encounterID: String
    public var link: EncounterLinkCard
    public init(encounterID: String, link: EncounterLinkCard) {
        self.encounterID = encounterID; self.link = link
    }
}

public enum DiscoverActionError: Error, Equatable, Sendable {
    case authorizationFailed, notFound, unavailable
}

/// Composition supplies I/O. Writes return a freshly authorized card, or nil when access ended
/// (including removal of the last retention reference). No card is persisted by this package.
@MainActor
public struct DiscoverActions {
    public var loadFeed: @MainActor () async throws -> [EncounterCard]
    public var loadCard: @MainActor (String) async throws -> EncounterCard?
    public var setFavorite: @MainActor (String, Bool) async throws -> EncounterCard?
    public var saveLink: @MainActor (String, String) async throws -> EncounterCard?
    public var unsaveLink: @MainActor (String, String) async throws -> EncounterCard?
    public var deleteEncounter: @MainActor (String) async throws -> Void
    public var loadFavorites: @MainActor () async throws -> [EncounterCard]
    public var loadSavedLinks: @MainActor () async throws -> [EncounterSavedLink]

    public init(loadFeed: @escaping @MainActor () async throws -> [EncounterCard],
                loadCard: @escaping @MainActor (String) async throws -> EncounterCard?,
                setFavorite: @escaping @MainActor (String, Bool) async throws -> EncounterCard?,
                saveLink: @escaping @MainActor (String, String) async throws -> EncounterCard?,
                unsaveLink: @escaping @MainActor (String, String) async throws -> EncounterCard?,
                deleteEncounter: @escaping @MainActor (String) async throws -> Void,
                loadFavorites: @escaping @MainActor () async throws -> [EncounterCard],
                loadSavedLinks: @escaping @MainActor () async throws -> [EncounterSavedLink]) {
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
                openSample: @escaping @MainActor () -> Void,
                openOwnLinks: @escaping @MainActor () -> Void,
                openSystemSettings: @escaping @MainActor () -> Void,
                openBluetoothRecovery: @escaping @MainActor () -> Void,
                back: @escaping @MainActor () -> Void, encounterRemoved: @escaping @MainActor () -> Void) {
        self.openEncounter = openEncounter; self.openFavorites = openFavorites
        self.openSession = openSession; self.openQR = openQR
        self.openDiscoverySettings = openDiscoverySettings; self.openProfileEditing = openProfileEditing
        self.openReportOrBlock = openReportOrBlock; self.openSample = openSample
        self.openOwnLinks = openOwnLinks; self.openSystemSettings = openSystemSettings
        self.openBluetoothRecovery = openBluetoothRecovery
        self.back = back; self.encounterRemoved = encounterRemoved
    }
}
