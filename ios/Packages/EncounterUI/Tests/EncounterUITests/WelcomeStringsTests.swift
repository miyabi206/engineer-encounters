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
    func testSignInInitializerOmitsEachAbsentLegalLinkWithoutOmittingDeclarations() {
        let declarations = Binding.constant(SignInDeclarations())
        let noLinks = WelcomeView(declarations: declarations, onRetry: {}) { Text("Sign in") }
        XCTAssertTrue(noLinks.showsSignInControls)
        XCTAssertFalse(noLinks.showsTerms)
        XCTAssertFalse(noLinks.showsPrivacy)
        XCTAssertFalse(declarations.wrappedValue.canSignIn)
        let termsOnly = WelcomeView(declarations: declarations, onTerms: {}, onRetry: {},
            signIn: { Text("Sign in") }, trailing: { Text("Additional content") })
        XCTAssertTrue(termsOnly.showsTerms)
        XCTAssertFalse(termsOnly.showsPrivacy)
        let privacyOnly = WelcomeView(declarations: declarations, onPrivacy: {}, onRetry: {}) { Text("Sign in") }
        XCTAssertFalse(privacyOnly.showsTerms)
        XCTAssertTrue(privacyOnly.showsPrivacy)
        let both = WelcomeView(declarations: declarations, onTerms: {}, onPrivacy: {}, onRetry: {}) { Text("Sign in") }
        XCTAssertTrue(both.showsTerms)
        XCTAssertTrue(both.showsPrivacy)
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
