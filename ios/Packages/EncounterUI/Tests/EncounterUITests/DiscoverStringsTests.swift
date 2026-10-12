import XCTest
@testable import EncounterUI

final class DiscoverStringsTests: XCTestCase {
    func testBothLanguagesDefineEveryKeyWithoutUntrackedKeys() throws {
        let expected = Set(DiscoverString.allCases.map(\.rawValue))
        for language in ["ja", "en"] {
            let table = try DiscoverStrings.table(language: language)
            XCTAssertEqual(Set(table.keys), expected, language)
            for key in expected {
                XCTAssertFalse(try XCTUnwrap(table[key], "\(language): \(key)").isEmpty)
                XCTAssertEqual(DiscoverStrings.localized(key, language: language), table[key])
            }
        }
    }

    func testTruncatedExplanationAndImpersonationWordingInBothLanguages() {
        XCTAssertEqual(DiscoverStrings.localized("truncated", language: "en"),
                       "Only the first 200 currently authorized entries are displayed.")
        XCTAssertEqual(DiscoverStrings.localized("truncated", language: "ja"),
                       "現在表示が許可されている項目のうち、最初の200件だけを表示しています。")
        XCTAssertEqual(DiscoverStrings.localized("reportImpersonation", language: "en"), "Report impersonation")
        XCTAssertEqual(DiscoverStrings.localized("reportImpersonation", language: "ja"), "なりすましを通報")
        XCTAssertFalse(DiscoverString.allCases.contains { $0.rawValue == "all" })
    }

    func testScreenWordingAndCountTokensAreVerbatim() {
        XCTAssertEqual(DiscoverStrings.localized("feedSubtitle", language: "ja"), "すれちがった人の作品を見てみよう")
        XCTAssertEqual(DiscoverStrings.localized("authorizedOnly", language: "en"), "Only information shared with you")
        XCTAssertEqual(DiscoverStrings.localized("sharedCount", language: "ja"), "共通の興味：{count}件")
        XCTAssertEqual(DiscoverStrings.localized("sharedCount", language: "en"), "{count} shared interests")
        XCTAssertEqual(DiscoverStrings.localized("deleteExplanation", language: "en"),
                       "This removes the encounter for both people, including favorites and saved links.")
        XCTAssertEqual(DiscoverStrings.localized("bluetoothDenied", language: "ja"), "Bluetoothの使用が許可されていません")
        XCTAssertEqual(DiscoverStrings.localized("emptyFeed", language: "en"), "No encounters to show yet")
        XCTAssertEqual(DiscoverStrings.localized("fictional", language: "ja"), "架空のプロフィールです")
    }
}
