import Foundation

enum SafetyString: String, CaseIterable {
    case blockedUsers, empty, unblock, confirmUnblock, notRestored, reportOrBlock, reason, spam, harassment, impersonation, other, submit, hidden, block, blockExplanation, submitted, review, impersonationGuidance, pending, limitedList
    case acceptedHidden, blockAlso, done, blockUnavailable
}

enum SafetyStrings {
    static func text(_ key: SafetyString) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: "Safety")
    }
    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: "Safety")
    }
    static func table(language: String) throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: "Safety", withExtension: "strings",
                                          subdirectory: nil, localization: language) else { return [:] }
        return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String] ?? [:]
    }
}
