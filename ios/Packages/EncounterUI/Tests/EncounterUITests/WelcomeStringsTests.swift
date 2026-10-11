import XCTest
import SwiftUI
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
    @MainActor
    func testOnlySignInInitializersShowDeclarationsLegalLinksAndSignInControls() {
        XCTAssertFalse(WelcomeView().showsSignInControls)
        XCTAssertFalse(WelcomeView { Text("Additional content") }.showsSignInControls)
        let declarations = Binding.constant(SignInDeclarations())
        let signIn = WelcomeView(declarations: declarations, onTerms: {}, onPrivacy: {}, onRetry: {}) {
            Text("Sign in")
        }
        XCTAssertTrue(signIn.showsSignInControls)
        let trailing = WelcomeView(declarations: declarations, onTerms: {}, onPrivacy: {}, onRetry: {},
                                   signIn: { Text("Sign in") }, trailing: { Text("Additional content") })
        XCTAssertTrue(trailing.showsSignInControls)
    }

}
