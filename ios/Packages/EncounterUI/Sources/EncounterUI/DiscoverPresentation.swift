import Foundation

public enum DiscoverFeedContent: Equatable, Sendable {
    case discoveryOff, loading, failure, empty, cards

    public static func select(discoveryOn: Bool, isAuthorized: Bool,
                              state: DiscoverLoadState, hasCards: Bool) -> Self {
        guard discoveryOn else { return .discoveryOff }
        guard isAuthorized else { return .failure }
        switch state {
        case .idle, .loading: return .loading
        case .failed, .missing: return .failure
        case .loaded: return hasCards ? .cards : .empty
        }
    }
}

public enum DiscoverFeedShortcut: CaseIterable, Sendable {
    case favorites

    var label: DiscoverString { .favorites }

    @MainActor
    public func open(using navigation: DiscoverNavigationActions) { navigation.openFavorites() }
}

public enum DiscoverBluetoothContent: Equatable, Sendable {
    case hidden, checking, unavailable(DiscoverBluetoothStatus)

    public static func select(_ status: DiscoverBluetoothStatus) -> Self {
        switch status {
        case .available: return .hidden
        case .checking: return .checking
        default: return .unavailable(status)
        }
    }
}

public enum DiscoverPrerequisiteContent: Equatable, Sendable {
    case loading, failure, guidance(editProfile: Bool, editLinks: Bool)

    public static func select(state: DiscoverLoadState, prerequisites: ProfilePrerequisites) -> Self {
        switch state {
        case .idle, .loading: return .loading
        case .failed, .missing: return .failure
        case .loaded:
            return .guidance(editProfile: !prerequisites.displayName || !prerequisites.introduction || !prerequisites.interest,
                             editLinks: !prerequisites.link)
        }
    }
}

public enum DiscoverSessionDestination: Equatable, Sendable {
    case session, bluetoothRecovery

    public static func select(sessionActive: Bool, bluetooth: DiscoverBluetoothStatus) -> Self {
        sessionActive || bluetooth == .available ? .session : .bluetoothRecovery
    }

    @MainActor
    public func open(using navigation: DiscoverNavigationActions) {
        switch self {
        case .session: navigation.openSession()
        case .bluetoothRecovery: navigation.openBluetoothRecovery()
        }
    }
}

/// S07 actions are based exclusively on the amended single-card response.
public struct EncounterDetailControls: Equatable, Sendable {
    public let favorite: Bool
    public let savedLinkIDs: Set<String>

    public init(detail: EncounterDetail) {
        favorite = detail.favorite; savedLinkIDs = detail.savedLinkIDs
    }

    var favoriteLabel: DiscoverString { favorite ? .removeFavorite : .addFavorite }
    func savedLabel(linkID: String) -> DiscoverString {
        savedLinkIDs.contains(linkID) ? .unsaveLink : .saveLink
    }

    @MainActor
    public static func report(card: EncounterCard, linkID: String, navigation: DiscoverNavigationActions) {
        guard card.links.contains(where: { $0.id == linkID }) else { return }
        navigation.reportImpersonation(card, linkID)
    }
}
