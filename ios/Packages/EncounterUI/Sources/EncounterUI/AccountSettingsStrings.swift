import Foundation

enum AccountSettingsString: String, CaseIterable {
    case title, signIn, temporary, github, disconnect, disconnectExplanation, notConnected, signOut, delete, temporaryWarning, connected, confirmSignOut, signOutExplanation, permanent, lastLink, pending, configurationRequired, failedDeletion, deletionConfirmation, checkingAccount, failedAccountCheck
}

enum AccountSettingsStrings {
    static func text(_ key: AccountSettingsString) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: "AccountSettings")
    }
    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: "AccountSettings")
    }
    static func table(language: String) throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: "AccountSettings", withExtension: "strings",
                                          subdirectory: nil, localization: language) else { return [:] }
        return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String] ?? [:]
    }
}
