import XCTest
@testable import EncounterUI

final class OnboardingStringsTests: XCTestCase {
    func testBothLanguagesDefineEveryKeyWithNoUntrackedKeys() throws {
        let expected = Set(OnboardingString.allCases.map(\.rawValue))
        for language in ["ja", "en"] {
            let table = try OnboardingStrings.table(language: language)
            XCTAssertEqual(Set(table.keys), expected, language)
            for key in expected {
                XCTAssertFalse(try XCTUnwrap(table[key], "\(language): \(key)").isEmpty)
                XCTAssertEqual(OnboardingStrings.localized(key, language: language), table[key])
            }
        }
    }

    func testSuppliedWordingAndFormattingInBothLanguages() throws {
        XCTAssertEqual(OnboardingStrings.localized("age", language: "ja"), "18歳以上です")
        XCTAssertEqual(OnboardingStrings.localized("agreement", language: "en"), "I agree to the terms and privacy policy")
        XCTAssertEqual(OnboardingStrings.localized("basicsGuidance", language: "ja"), "表示名と自己紹介を入力してください")
        XCTAssertEqual(OnboardingStrings.localized("selectionGuidance", language: "en"), "Choose at least one interest and purpose")
        XCTAssertEqual(OnboardingStrings.localized("linkRequired", language: "ja"), "発見をオンにするにはリンクが1件以上必要です")
        XCTAssertEqual(OnboardingStrings.localized("background", language: "en"),
                       "Discovery may also work while phones are locked or the app is in the background.")
        for language in ["ja", "en"] {
            let table = try OnboardingStrings.table(language: language)
            XCTAssertEqual(String(format: try XCTUnwrap(table["counter"]), 30, 30), "30/30")
            XCTAssertTrue(String(format: try XCTUnwrap(table["tooLong"]), 200).contains("200"))
            XCTAssertFalse(table.keys.contains { $0.localizedCaseInsensitiveContains("notification") })
        }
    }
}
