import XCTest
@testable import EncounterUI

final class WelcomeStringsTests: XCTestCase {
    func testJapaneseWelcomeStrings() {
        XCTAssertEqual(WelcomeStrings.localized("welcome.title", language: "ja"), "すれちがいエンジニア")
        XCTAssertEqual(WelcomeStrings.localized("welcome.introduction", language: "ja"),
                       "すれちがったエンジニアの作品を見つけよう")
    }

    func testEnglishWelcomeStrings() {
        XCTAssertEqual(WelcomeStrings.localized("welcome.title", language: "en"), "Engineer Encounters")
        XCTAssertEqual(WelcomeStrings.localized("welcome.introduction", language: "en"),
                       "Discover the work of engineers you encounter.")
    }
}
