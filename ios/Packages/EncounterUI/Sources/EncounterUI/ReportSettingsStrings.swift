import Foundation

enum ReportSettingsString: String, CaseIterable {
    case title, time, localTime, notifications, names, waiting, noPush, inApp, noReport, saveTime, systemSettings, ambient, permissionNotRequested, permissionAllowed, permissionDenied, permissionUnavailable, invalidTime, saved, discard
}

enum ReportSettingsStrings {
    static func text(_ key: ReportSettingsString) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: "ReportSettings")
    }
    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: "ReportSettings")
    }
    static func table(language: String) throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: "ReportSettings", withExtension: "strings",
                                          subdirectory: nil, localization: language) else { return [:] }
        return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String] ?? [:]
    }
}
