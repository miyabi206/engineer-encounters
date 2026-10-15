import Foundation

enum MyCardString: String, CaseIterable {
    case profile, preview, discoveryOff, completeBasics, addLinks, emptyPreview, audience, openFailed
}

enum MyCardStrings {
    static func text(_ key: MyCardString) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: "MyCard")
    }
    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: "MyCard")
    }
    static func table(language: String, name: String = "MyCard") throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "strings",
                                          subdirectory: nil, localization: language) else { return [:] }
        return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String] ?? [:]
    }
}
