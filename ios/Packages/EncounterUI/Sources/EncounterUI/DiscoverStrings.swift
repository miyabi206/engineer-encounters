import Foundation

enum DiscoverString: String, CaseIterable {
    case discover, feedSubtitle, discoveryEnabled, background, startSession, viewSession, qrExchange
    case yourInterests, all, favorites, sharedCount, shell, ambient, session
    case qrKind, viewWork, pace, encounter, authorizedOnly, purposes, common
    case openOriginal, saveLink, unsaveLink, addFavorite, removeFavorite, noLinks, contact
    case safety, deleteEncounter, deleteExplanation, sampleEncounter, encounters, savedLinks, noFavorites
    case noSavedLinks, favoritesGuidance, viewEncounter, bluetoothUnavailable, bluetoothOff, bluetoothDenied, systemSettings
    case tryAgain, discoverySettings, discoveryOff, notParticipating, enableDiscovery, editProfile, ownLinks
    case canEdit, viewSample, dismissSample, emptyFeed, dailyReport, fictional, back
    case cancel, retry, loading, loadError, verified, unverified, interests
    case discoveryPurpose, collaborationPurpose, writeError, unverifiedExplanation, sampleName, sampleIntroduction, sampleSource
    case sampleWork, sampleDescription
}

enum DiscoverStrings {
    static func text(_ key: DiscoverString) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: "Discover")
    }

    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: "Discover")
    }

    static func table(language: String) throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: "Discover", withExtension: "strings",
                                          subdirectory: nil, localization: language) else { return [:] }
        let data = try Data(contentsOf: url)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
    }

    static func sharedCount(_ count: Int, locale: Locale) -> String {
        text(.sharedCount).replacingOccurrences(of: "{count}", with: count.formatted(.number.locale(locale)))
    }
}
