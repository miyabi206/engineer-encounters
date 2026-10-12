import XCTest
@testable import EncounterUI

final class MyCardPreviewTests: XCTestCase {
    func testEveryFieldHonorsBothAudiencesAndPrivateNeverAppears() {
        for field in ProfileField.allCases {
            for level in VisibilityLevel.allCases {
                let profile = OwnProfileState(displayName: "Owner", introduction: "Introduction", contactDetail: "Contact",
                    interestIDs: ["ios"], purposes: [.discovery], fieldVisibility: [field: level])
                let data = MyCardData(profile: profile, links: [])
                for audience in MyCardAudience.allCases {
                    let preview = MyCardPreview(data: data, audience: audience)
                    let expected = level == .everyoneEligible || (level == .compatibleOnly && audience == .compatibleOnly)
                    switch field {
                    case .displayName: XCTAssertEqual(preview.displayName != nil, expected)
                    case .introduction: XCTAssertEqual(preview.introduction != nil, expected)
                    case .contactDetail: XCTAssertEqual(preview.contactDetail != nil, expected)
                    case .interests: XCTAssertEqual(!preview.interestIDs.isEmpty, expected)
                    case .purposes: XCTAssertEqual(!preview.purposes.isEmpty, expected)
                    }
                }
            }
        }
    }

    func testLinksHaveNoDefaultAndStableOrderAndFieldsHonorVisibility() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        func link(_ id: String, _ visibility: VisibilityLevel?, _ order: Int) -> OwnLinkState {
            .init(id: id, source: .other, sourceLabel: "Source", title: id, url: url,
                  visibility: visibility, displayOrder: order)
        }
        let profile = OwnProfileState(displayName: "Owner", contactDetail: "Private", purposes: [.collaboration])
        let data = MyCardData(profile: profile, links: [link("b", .everyoneEligible, 1), link("c", .compatibleOnly, 0),
            link("a", .everyoneEligible, 1), link("private", .private, 0), link("unset", nil, 0)])
        let eligible = MyCardPreview(data: data, audience: .everyoneEligible)
        XCTAssertEqual(eligible.links.map(\.id), ["a", "b"])
        XCTAssertEqual(eligible.purposes, [.collaboration])
        XCTAssertNil(eligible.contactDetail)
        XCTAssertEqual(MyCardPreview(data: data, audience: .compatibleOnly).links.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(eligible.displayName, "Owner")
    }

    func testAllPrivatePreviewHasNoInferredIdentityAndEmptyNamesHaveNoInitial() {
        var profile = OwnProfileState(displayName: "Secret", introduction: "Secret", contactDetail: "Secret",
            interestIDs: ["secret"], purposes: [.discovery],
            fieldVisibility: Dictionary(uniqueKeysWithValues: ProfileField.allCases.map { ($0, .private) }))
        for audience in MyCardAudience.allCases {
            let preview = MyCardPreview(data: .init(profile: profile, links: []), audience: audience)
            XCTAssertTrue(preview.isEmpty); XCTAssertNil(preview.initial)
        }
        profile.displayName = "  \n"
        profile.fieldVisibility[.displayName] = .everyoneEligible
        XCTAssertNil(MyCardPreview(data: .init(profile: profile, links: []), audience: .everyoneEligible).initial)
    }

    @MainActor
    func testLoadingFailureClearsPreviewAndRetryRestoresOnlyFreshOwnerData() async {
        var fails = true
        let data = MyCardData(profile: .init(displayName: "Owner"), links: [])
        let model = MyCardModel(data: data, actions: .init(load: {
            if fails { throw ProfileActionError(code: .unavailable) }; return data
        }, openOriginal: { _ in }), navigation: .init(editProfile: {}, links: {}, visibility: {}))
        await model.load()
        XCTAssertTrue(model.failed); XCTAssertNil(model.data); XCTAssertNil(model.preview)
        fails = false
        await model.load()
        XCTAssertFalse(model.failed); XCTAssertEqual(model.preview?.displayName, "Owner")
        XCTAssertTrue(model.needsBasics)
    }
}

final class MyCardStringsTests: XCTestCase {
    func testBothLanguagesDefineEveryKey() throws {
        for language in ["ja", "en"] {
            let table = try MyCardStrings.table(language: language)
            XCTAssertEqual(Set(table.keys), Set(MyCardString.allCases.map(\.rawValue)))
            for key in MyCardString.allCases {
                let value = try XCTUnwrap(table[key.rawValue]); XCTAssertFalse(value.isEmpty)
                XCTAssertEqual(MyCardStrings.localized(key.rawValue, language: language), value)
            }
        }
        XCTAssertEqual(MyCardStrings.localized("preview", language: "ja"), "公開カードのプレビュー")
    }
}
