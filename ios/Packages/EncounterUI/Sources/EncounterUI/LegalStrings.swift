import Foundation

enum LegalString: String, CaseIterable {
    case title, terms, privacy, support, moderationContact, contact, copy, version, product, openFailed
}

enum LegalStrings {
    static func text(_ key: LegalString) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: "Legal")
    }
    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: "Legal")
    }
    static func table(language: String) throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: "Legal", withExtension: "strings",
                                          subdirectory: nil, localization: language) else { return [:] }
        return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String] ?? [:]
    }
}
