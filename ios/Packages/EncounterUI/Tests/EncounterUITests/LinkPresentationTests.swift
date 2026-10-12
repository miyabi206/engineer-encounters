import Foundation
import XCTest
@testable import EncounterUI

final class LinkPresentationTests: XCTestCase {
    private func draft() -> LinkPreviewDraft {
        LinkPreviewDraft(previewID: "server-preview", source: .github,
                         url: URL(string: "https://github.com/owner/repository")!, verified: true,
                         sourceLabel: "GitHub", title: "Repository")
    }

    func testNewPreviewRequiresExplicitVisibilityAndTitle() {
        var value = draft()
        XCTAssertNil(value.visibility)
        XCTAssertEqual(LinkValidation.invalidFields(value), [.visibility])
        XCTAssertFalse(LinkValidation.canSave(value, linkCount: 0))
        for visibility in VisibilityLevel.allCases {
            value.visibility = visibility
            XCTAssertTrue(LinkValidation.canSave(value, linkCount: 0))
        }
        value.title = " \n\t"
        XCTAssertEqual(LinkValidation.invalidFields(value), [.title])
        XCTAssertFalse(LinkValidation.canSave(value, linkCount: 0))
    }

    func testEveryTextLimitCountsTrimmedUnicodeScalarsAtBoundary() {
        var value = draft(); value.visibility = .private
        let fields: [(WritableKeyPath<LinkPreviewDraft, String>, Int, LinkField)] = [
            (\.title, 100, .title), (\.description, 200, .description),
            (\.openingText, 200, .openingText), (\.mainLanguage, 30, .mainLanguage)
        ]
        for (keyPath, limit, field) in fields {
            value[keyPath: keyPath] = " \n" + String(repeating: "e\u{301}", count: limit / 2) + "\t "
            XCTAssertEqual(LinkValidation.count(value[keyPath: keyPath]), limit)
            XCTAssertTrue(LinkValidation.invalidFields(value).isEmpty)
            value[keyPath: keyPath] += "a"
            XCTAssertEqual(LinkValidation.invalidFields(value), [field])
            value[keyPath: keyPath] = "Valid"
        }
        XCTAssertEqual(LinkValidation.count(" 👨‍👩‍👧‍👦e\u{301}あ "), 10)
    }

    func testTenTagsOfThirtyCharactersAndOptionalMetadata() {
        var value = draft(); value.visibility = .everyoneEligible
        XCTAssertTrue(LinkValidation.invalidFields(value).isEmpty)
        value.tags = Array(repeating: String(repeating: "e\u{301}", count: 15), count: 10)
        XCTAssertTrue(LinkValidation.invalidFields(value).isEmpty)
        value.tags[0] += "a"
        XCTAssertEqual(LinkValidation.invalidFields(value), [.tags])
        value.tags[0] = "tag"; value.tags.append("eleventh")
        XCTAssertEqual(LinkValidation.invalidFields(value), [.tags])
        value.tags = [" \n"]
        XCTAssertEqual(LinkValidation.invalidFields(value), [.tags])
        value.tags = []
        XCTAssertTrue(LinkValidation.invalidFields(value).isEmpty)
    }

    func testLinkLimitVisibilityAndLastLinkRule() {
        var value = draft(); value.visibility = .private
        for count in 0..<10 { XCTAssertTrue(LinkValidation.canSave(value, linkCount: count)) }
        XCTAssertFalse(LinkValidation.canAdd(count: 10))
        XCTAssertFalse(LinkValidation.canAdd(count: 11))
        XCTAssertFalse(LinkValidation.canAdd(count: -1))
        XCTAssertFalse(LinkValidation.canSave(value, linkCount: 10))
        XCTAssertFalse(LinkValidation.canDelete(count: 0, discoveryOn: false))
        XCTAssertFalse(LinkValidation.canDelete(count: 1, discoveryOn: true))
        XCTAssertTrue(LinkValidation.canDelete(count: 1, discoveryOn: false))
        XCTAssertTrue(LinkValidation.canDelete(count: 2, discoveryOn: true))
        let existing = OwnLinkState(id: "saved", source: .github, sourceLabel: "GitHub", title: "Title",
                                   url: value.url, visibility: .private)
        XCTAssertTrue(LinkValidation.canSave(LinkPreviewDraft(link: existing), linkCount: 10))
    }

    func testRefreshMergePreservesOwnerVisibilityAndLinkIdentity() {
        let original = OwnLinkState(id: "saved", source: .github, sourceLabel: "Owner label", title: "Owner title",
                                    description: "Owner description", mainLanguage: "Swift", tags: ["Owner tag"],
                                    openingText: "Owner opening", url: draft().url, visibility: .compatibleOnly, verified: true)
        let edited = LinkPreviewDraft(link: original)
        let fresh = LinkPreviewDraft(previewID: "new-preview", source: .github, url: original.url, verified: false,
                                     sourceLabel: "GitHub", title: "New title", description: "New description",
                                     mainLanguage: "Rust", tags: ["New tag"], openingText: "New opening")
        let merged = edited.replacingMetadata(with: fresh)
        XCTAssertEqual(edited.title, "Owner title")
        XCTAssertEqual(merged.previewID, "new-preview")
        XCTAssertEqual(merged.existingLinkID, "saved")
        XCTAssertEqual(merged.visibility, .compatibleOnly)
        XCTAssertEqual(merged.source, original.source)
        XCTAssertEqual(merged.url, original.url)
        XCTAssertFalse(merged.verified)
        XCTAssertEqual(merged.sourceLabel, fresh.sourceLabel)
        XCTAssertEqual(merged.title, fresh.title)
        XCTAssertEqual(merged.description, fresh.description)
        XCTAssertEqual(merged.mainLanguage, fresh.mainLanguage)
        XCTAssertEqual(merged.tags, fresh.tags)
        XCTAssertEqual(merged.openingText, fresh.openingText)
        var renamed = edited; renamed.sourceLabel = "A display label"
        XCTAssertEqual(renamed.source, .github)
        XCTAssertTrue(renamed.verified)
    }

    func testPagingShowsOnlyUniqueOwnPublicRepositoriesAndValidNextPage() {
        let url = draft().url
        let own = GitHubRepositoryChoice(id: "own", ownerHandle: "OWNER", name: "Own", url: url)
        let privateRepo = GitHubRepositoryChoice(id: "private", ownerHandle: "owner", name: "Private", url: url, isPublic: false)
        let foreign = GitHubRepositoryChoice(id: "foreign", ownerHandle: "another", name: "Foreign", url: url)
        var paging = GitHubRepositoryPaging()
        paging.receive(GitHubRepositoryPage(repositories: [own, own, privateRepo, foreign], nextPage: 2), page: 1, handle: "owner")
        XCTAssertEqual(paging.repositories, [own])
        XCTAssertEqual(paging.page, 1)
        XCTAssertNil(paging.previousPage)
        XCTAssertEqual(paging.nextPage, 2)
        paging.receive(GitHubRepositoryPage(repositories: [], nextPage: 2), page: 2, handle: "owner")
        XCTAssertTrue(paging.repositories.isEmpty)
        XCTAssertEqual(paging.previousPage, 1)
        XCTAssertNil(paging.nextPage)
        paging.receive(GitHubRepositoryPage(repositories: [own], nextPage: 3), page: 0, handle: "owner")
        XCTAssertEqual(paging.page, 2)
        XCTAssertTrue(paging.repositories.isEmpty)
    }

    func testFirstLinkResumeGateDoesNotChangeLegacyFlow() {
        var profile = OwnProfileState(displayName: "Name", introduction: "Introduction", interestIDs: ["swift"], purposes: [.discovery])
        XCTAssertEqual(OnboardingStep.unfinishedStep(profile: profile), .permissions)
        XCTAssertEqual(OnboardingStep.unfinishedStep(profile: profile, requiresFirstLink: true), .firstLink)
        for level in VisibilityLevel.allCases {
            profile.linkCount = 1
            XCTAssertFalse(FirstLinkStepGate.needsFirstLink(profile, enabled: true), level.rawValue)
            XCTAssertEqual(OnboardingStep.unfinishedStep(profile: profile, requiresFirstLink: true), .permissions)
        }
        profile.linkCount = 0; profile.purposes = []
        XCTAssertEqual(OnboardingStep.unfinishedStep(profile: profile, requiresFirstLink: true), .interests)
        profile.displayName = ""
        XCTAssertEqual(OnboardingStep.unfinishedStep(profile: profile, requiresFirstLink: true), .basics)
    }
}
