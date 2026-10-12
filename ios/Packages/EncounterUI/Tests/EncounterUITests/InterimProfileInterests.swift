import Foundation
@testable import EncounterUI

/// Curated labels used only by tests; callers supply the production catalogue.
enum InterimProfileInterests {
    enum Label: String, CaseIterable {
        case interestIOS, interestAndroid, interestWeb, interestBackend, interestDesign, interestOSS
    }

    static var options: [InterestOption] {
        zip(["ios", "android", "web", "backend", "design", "oss"], Label.allCases).map { id, key in
            InterestOption(id: id, labelJapanese: localized(key, language: "ja"),
                           labelEnglish: localized(key, language: "en"))
        }
    }

    private static func localized(_ key: Label, language: String) -> String {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key.rawValue }
        return bundle.localizedString(forKey: key.rawValue, value: nil, table: "Interests")
    }
}
