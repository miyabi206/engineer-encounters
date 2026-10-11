import XCTest
@testable import EncounterUI

final class SettingsValidationTests: XCTestCase {
    func testCountsTrimmedUnicodeScalarsInsteadOfGraphemeClusters() {
        XCTAssertEqual(SettingsValidation.textCount(" \n👩🏽‍💻\t "), 4)
        XCTAssertEqual(SettingsValidation.textCount(" e\u{301} "), 2)
        XCTAssertEqual(SettingsValidation.textCount(" \n "), 0)
        XCTAssertTrue(SettingsValidation.validText(" " + String(repeating: "a", count: 30) + "\n", limit: 30, required: true))
        XCTAssertFalse(SettingsValidation.validText(String(repeating: "e\u{301}", count: 16), limit: 30, required: true))
        XCTAssertTrue(SettingsValidation.validText(" \n", limit: 100, required: false))
        XCTAssertFalse(SettingsValidation.validText(" \n", limit: 30, required: true))
    }

    func testAllTextLimitsUseTheSameTrimmedScalarRule() {
        for (field, limit) in [(ProfileField.displayName, 30), (.introduction, 200), (.contactDetail, 100)] {
            var values: [ProfileField: String] = [.displayName: "Name", .introduction: "Introduction", .contactDetail: ""]
            values[field] = " " + String(repeating: "a", count: limit) + "\n"
            XCTAssertFalse(invalid(values).contains(field))
            values[field] = String(repeating: "a", count: limit - 1) + "e\u{301}"
            XCTAssertTrue(invalid(values).contains(field))
        }
    }

    func testSelectionRulesRejectUnknownInterestsAndRequirePurposes() {
        let options = InterimProfileInterests.options
        XCTAssertEqual(Set(options.map(\.id)).count, options.count)
        for option in options {
            XCTAssertFalse(option.labelJapanese.isEmpty)
            XCTAssertFalse(option.labelEnglish.isEmpty)
        }
        let invalid = SettingsValidation.invalidProfileFields(displayName: "Name", introduction: "Intro", contactDetail: "",
                                                              interests: ["unknown"], purposes: [], options: options)
        XCTAssertEqual(invalid, [.interests, .purposes])
        let many = (1...11).map { InterestOption(id: "\($0)", labelJapanese: "項目", labelEnglish: "Item") }
        XCTAssertEqual(SettingsValidation.invalidProfileFields(displayName: "Name", introduction: "Intro", contactDetail: "",
            interests: Set(many.map(\.id)), purposes: [.discovery], options: many), [.interests])
    }

    func testDiscoveryPrerequisitesAndVisibilityDefaults() {
        var profile = OwnProfileState(discoveryOn: true)
        XCTAssertEqual(SettingsValidation.removedPrerequisites(profile: profile, displayName: " ", introduction: "\n", interests: []),
                       [.displayName, .introduction, .interests])
        profile.discoveryOn = false
        XCTAssertTrue(SettingsValidation.removedPrerequisites(profile: profile, displayName: "", introduction: "", interests: []).isEmpty)
        for field in ProfileField.allCases {
            XCTAssertEqual(SettingsValidation.visibility(field, in: [:]), field == .contactDetail ? .private : .everyoneEligible)
        }
        XCTAssertEqual(ProfileValidation.sharedInterestRange, 1...10)
        XCTAssertEqual(OwnProfileState().minimumSharedInterests, 1)
    }

    func testEveryContractErrorMapsToMessageAndOnlyFieldErrorsMarkFields() {
        let cases: [(ProfileActionError.Code, SettingsString)] = [
            (.notAuthenticated, .authenticationError), (.accountNotReady, .accountError),
            (.declarationRequired, .declarationError), (.invalidInput, .invalidField),
            (.prerequisiteMissing, .prerequisiteError), (.rateLimited, .rateLimitError),
            (.notFound, .notFoundError), (.unavailable, .saveError)
        ]
        for (code, expected) in cases {
            let error = ProfileActionError(code: code, fields: ["display_name"])
            for screen in [SettingsScreen.profile, .discovery, .visibility] {
                XCTAssertEqual(SettingsErrorPresentation.message(error, screen: screen, discoveryOn: false), expected)
            }
            XCTAssertEqual(SettingsErrorPresentation.affects(error, field: .displayName), code == .invalidInput || code == .prerequisiteMissing)
        }
        XCTAssertEqual(SettingsErrorPresentation.message(.init(code: .prerequisiteMissing), screen: .profile, discoveryOn: true), .discoveryRequired)
        for alias in ["interest", "interest_ids", "interests"] {
            XCTAssertTrue(SettingsErrorPresentation.affects(.init(code: .invalidInput, fields: [alias]), field: .interests))
        }
        for alias in ["minimum_shared_interests", "value"] {
            XCTAssertTrue(SettingsErrorPresentation.affectsThreshold(.init(code: .invalidInput, fields: [alias])))
        }
        XCTAssertFalse(SettingsErrorPresentation.affectsThreshold(.init(code: .rateLimited, fields: ["value"])))
    }

    private func invalid(_ values: [ProfileField: String]) -> [ProfileField] {
        SettingsValidation.invalidProfileFields(displayName: values[.displayName] ?? "", introduction: values[.introduction] ?? "",
            contactDetail: values[.contactDetail] ?? "", interests: ["ios"], purposes: [.discovery], options: InterimProfileInterests.options)
    }
}
