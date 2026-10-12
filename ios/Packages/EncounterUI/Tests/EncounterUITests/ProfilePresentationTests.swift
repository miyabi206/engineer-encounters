import XCTest
@testable import EncounterUI

final class ProfilePresentationTests: XCTestCase {
    private let option = InterestOption(id: "caller-option", labelJapanese: "呼び出し元の選択肢",
                                         labelEnglish: "Caller option")

    func testBothDeclarationsAreRequiredIndependently() {
        XCTAssertFalse(SignInDeclarations().canSignIn)
        XCTAssertFalse(SignInDeclarations(isAdult: true).canSignIn)
        XCTAssertFalse(SignInDeclarations(acceptsTermsAndPrivacy: true).canSignIn)
        XCTAssertTrue(SignInDeclarations(isAdult: true, acceptsTermsAndPrivacy: true).canSignIn)
    }

    func testLimitsCountTrimmedUnicodeScalars() {
        XCTAssertEqual(ProfileValidation.characterCount(" \n👨‍👩‍👧‍👦e\u{301}あ\t "), 10)
        XCTAssertTrue(ProfileValidation.invalidBasics(
            displayName: " " + String(repeating: "e\u{301}", count: 15) + "\n",
            introduction: String(repeating: "e\u{301}", count: 100)).isEmpty)
        XCTAssertEqual(ProfileValidation.invalidBasics(
            displayName: String(repeating: "e\u{301}", count: 16),
            introduction: String(repeating: "e\u{301}", count: 101)), [.displayName, .introduction])
        for limit in [30, 200, 100] {
            let atLimit = " \n" + String(repeating: "a", count: limit) + "\t "
            XCTAssertEqual(ProfileValidation.characterCount(atLimit), limit)
            XCTAssertTrue(ProfileValidation.validText(atLimit, limit: limit, required: true))
            XCTAssertFalse(ProfileValidation.validText(String(repeating: "a", count: limit - 1) + "e\u{301}",
                                                      limit: limit, required: false))
        }
    }

    func testBlankAndWhitespaceOnlyFieldsAreInvalid() {
        XCTAssertEqual(ProfileValidation.invalidBasics(displayName: " \n\t", introduction: ""),
                       [.displayName, .introduction])
        XCTAssertTrue(ProfileValidation.invalidBasics(displayName: " 名前 ", introduction: " 紹介 ").isEmpty)
        XCTAssertEqual(ProfileValidation.trimmed(" \n名前\t "), "名前")
    }

    func testInterestLimitAndCallerVocabularyAndPurposeRequirement() {
        let options = (1...11).map { InterestOption(id: "\($0)", labelJapanese: "項目\($0)", labelEnglish: "Item \($0)") }
        let ten = Set((1...10).map(String.init))
        XCTAssertTrue(ProfileValidation.validSelections(interestIDs: ten, purposes: [.discovery], options: options))
        XCTAssertFalse(ProfileValidation.validSelections(interestIDs: Set(options.map(\.id)),
                                                        purposes: [.discovery], options: options))
        XCTAssertFalse(ProfileValidation.validSelections(interestIDs: ["unknown"], purposes: [.discovery], options: options))
        XCTAssertFalse(ProfileValidation.validSelections(interestIDs: ["1"], purposes: [], options: options))
        XCTAssertFalse(ProfileValidation.validSelections(interestIDs: [], purposes: [.collaboration], options: options))
        XCTAssertTrue(ProfileValidation.validSelections(interestIDs: ["1"], purposes: [.discovery, .collaboration], options: options))
        XCTAssertFalse(ProfileValidation.canToggleInterest("11", selected: ten))
        XCTAssertTrue(ProfileValidation.canToggleInterest("1", selected: ten))
    }

    func testChecklistHasExactlyFourPrerequisitesAndPurposeIsNotOne() {
        XCTAssertEqual(ProfilePrerequisites().missing, [.displayName, .introduction, .interest, .link])
        for prerequisite in DiscoveryPrerequisite.allCases {
            var checklist = ProfilePrerequisites(displayName: true, introduction: true, interest: true, link: true)
            switch prerequisite {
            case .displayName: checklist.displayName = false
            case .introduction: checklist.introduction = false
            case .interest: checklist.interest = false
            case .link: checklist.link = false
            }
            XCTAssertEqual(checklist.missing, [prerequisite])
            XCTAssertFalse(checklist.canEnableDiscovery)
        }
        XCTAssertTrue(ProfilePrerequisites(displayName: true, introduction: true, interest: true, link: true).canEnableDiscovery)
    }

    func testResumeSkipsLinkScreenButRequiresBasicsInterestsAndPurposes() {
        var profile = OwnProfileState()
        XCTAssertEqual(OnboardingStep.unfinishedStep(profile: profile), .basics)
        profile.displayName = "名前"
        profile.introduction = "紹介"
        XCTAssertEqual(OnboardingStep.unfinishedStep(profile: profile), .interests)
        profile.interestIDs = [option.id]
        XCTAssertEqual(OnboardingStep.unfinishedStep(profile: profile), .interests)
        profile.purposes = [.collaboration]
        XCTAssertEqual(OnboardingStep.unfinishedStep(profile: profile), .permissions)
        XCTAssertFalse(profile.prerequisites.link)
        profile.interestIDs = Set((1...11).map(String.init))
        XCTAssertEqual(OnboardingStep.unfinishedStep(profile: profile), .interests)
    }

    func testPresentationContractRawValuesAndDefaults() {
        let profile = OwnProfileState()
        XCTAssertFalse(profile.discoveryOn)
        XCTAssertTrue(profile.purposes.isEmpty)
        XCTAssertEqual(profile.minimumSharedInterests, 1)
        XCTAssertEqual(profile.fieldVisibility[.contactDetail], .private)
        for field in [ProfileField.displayName, .introduction, .interests, .purposes] {
            XCTAssertEqual(profile.fieldVisibility[field], .everyoneEligible)
        }
        XCTAssertEqual(ProfileField.displayName.rawValue, "display_name")
        XCTAssertEqual(VisibilityLevel.compatibleOnly.rawValue, "compatible_only")
        XCTAssertEqual(ProfileActionError.Code.prerequisiteMissing.rawValue, "prerequisite_missing")
        let error = ProfileActionError(code: .invalidInput, fields: ["display_name", "interest_ids", "link"])
        XCTAssertEqual(error.fields, ["display_name", "interest_ids", "link"])
        XCTAssertTrue(error.affects(.displayName))
        XCTAssertTrue(error.affects(.interests))
        XCTAssertFalse(error.affects(.introduction))
    }

    func testInterestLabelsFollowCallerProvidedLanguages() {
        XCTAssertEqual(option.label(language: "ja_JP"), "呼び出し元の選択肢")
        XCTAssertEqual(option.label(language: "en_US"), "Caller option")
    }

    func testBluetoothGatesActivationAndRecovery() {
        XCTAssertTrue(BluetoothPermissionState.available.canEnableDiscovery)
        for state in [BluetoothPermissionState.notRequested, .denied, .poweredOff, .unavailable] {
            XCTAssertFalse(state.canEnableDiscovery)
        }
        XCTAssertFalse(BluetoothPermissionState.notRequested.needsRecovery)
        XCTAssertTrue(BluetoothPermissionState.denied.needsRecovery)
        XCTAssertTrue(BluetoothPermissionState.poweredOff.needsRecovery)
    }
}
