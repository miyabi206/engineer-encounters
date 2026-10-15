import XCTest
@testable import EncounterUI

final class SettingsStringsTests: XCTestCase {
    func testBothLanguagesDefineEveryKeyWithoutUntrackedKeys() throws {
        let expected = Set(SettingsString.allCases.map(\.rawValue))
        for language in ["ja", "en"] {
            let table = try SettingsStrings.table(language: language)
            XCTAssertEqual(Set(table.keys), expected, language)
            for key in expected {
                XCTAssertFalse(try XCTUnwrap(table[key], "\(language): \(key)").isEmpty)
                XCTAssertEqual(SettingsStrings.localized(key, language: language), table[key])
            }
        }
    }

    func testVerbatimScreenWordingAndFormats() throws {
        XCTAssertEqual(SettingsStrings.localized("editProfile", language: "ja"), "プロフィールを編集")
        XCTAssertEqual(SettingsStrings.localized("discoveryRequired", language: "en"), "Required fields cannot be empty while discovery is on")
        XCTAssertEqual(SettingsStrings.localized("discoveryMatching", language: "ja"), "発見・マッチング")
        XCTAssertEqual(SettingsStrings.localized("matchingExplanation", language: "en"),
                       "Matching affects order and visibility. It does not hide encounters.")
        XCTAssertEqual(SettingsStrings.localized("appliesToPast", language: "ja"), "過去のすれちがいや保存した項目にも適用されます")
        XCTAssertEqual(SettingsStrings.localized("everyoneEligible", language: "en"), "Everyone eligible")
        for (key, japanese, english) in [
            ("dailyReportTitle", "毎日のレポート", "Daily report"),
            ("blockedUsers", "ブロックした相手", "Blocked users"),
            ("account", "アカウント", "Account"),
            ("legal", "法務・サポート", "Legal and support")
        ] {
            XCTAssertEqual(SettingsStrings.localized(key, language: "ja"), japanese)
            XCTAssertEqual(SettingsStrings.localized(key, language: "en"), english)
        }
        for language in ["ja", "en"] {
            let table = try SettingsStrings.table(language: language)
            XCTAssertEqual(String(format: try XCTUnwrap(table["counter"]), 30, 30), "30/30")
            XCTAssertTrue(try XCTUnwrap(table["thresholdCount"]).contains("{count}"))
            for key in ["interestCounter", "interestLimit", "tooLong"] {
                XCTAssertTrue(String(format: try XCTUnwrap(table[key]), 10, 10).contains("10"))
            }
        }
    }
}
