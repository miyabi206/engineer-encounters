import XCTest
@testable import EncounterUI

final class DiscoverPresentationTests: XCTestCase {
    func testGroupingNewestDayFirstPreservesCallerOrderWithinDay() {
        let old = EncounterDay(year: 2026, month: 9, day: 30)
        let new = EncounterDay(year: 2026, month: 10, day: 1)
        let cards = [EncounterCard(id: "z", kind: .ambient, day: old),
                     EncounterCard(id: "c", kind: .session, day: new),
                     EncounterCard(id: "a", kind: .qr, day: new),
                     EncounterCard(id: "b", kind: .ambient, day: old)]
        let groups = EncounterDayGroup.grouped(cards)
        XCTAssertEqual(groups.map(\.day), [new, old])
        XCTAssertEqual(groups.map { $0.cards.map(\.id) }, [["c", "a"], ["z", "b"]])
        XCTAssertTrue(EncounterDayGroup.grouped([]).isEmpty)
        XCTAssertLessThan(old, new)
        XCTAssertLessThan(new, EncounterDay(year: 2027, month: 1, day: 1))
    }

    func testShellDropsEveryIdentifyingFieldAndSharedIDsRequireAuthorizedInterests() {
        let interest = InterestOption(id: "test", labelJapanese: "テスト", labelEnglish: "Test")
        let shell = EncounterCard(id: "shell", kind: .ambient, day: .init(year: 2026, month: 10, day: 1),
                                  displayName: "Name", introduction: "Intro", interests: [interest],
                                  sharedInterestIDs: ["test"], purposes: [.discovery], contactDetail: "Contact",
                                  links: [DiscoverTestDriver.link()], favorite: true, isShell: true)
        XCTAssertNil(shell.displayName); XCTAssertNil(shell.introduction); XCTAssertNil(shell.contactDetail)
        XCTAssertTrue(shell.interests.isEmpty); XCTAssertTrue(shell.sharedInterests.isEmpty)
        XCTAssertTrue(shell.purposes.isEmpty); XCTAssertTrue(shell.links.isEmpty)
        XCTAssertTrue(shell.favorite)
        let card = EncounterCard(id: "visible", kind: .qr, day: shell.day, displayName: " \n ",
                                 introduction: "", interests: [interest], sharedInterestIDs: ["test", "private"],
                                 contactDetail: "\t")
        XCTAssertNil(card.displayName); XCTAssertNil(card.introduction); XCTAssertNil(card.contactDetail)
        XCTAssertEqual(card.sharedInterestIDs, ["test"])
        XCTAssertEqual(card.sharedInterests, [interest])
    }

    func testDaysAreLocaleFormattedWithoutTimeAndOptionalLinkTextIsOmitted() {
        let day = EncounterDay(year: 2026, month: 10, day: 12)
        for language in ["ja_JP", "en_US"] {
            let formatted = day.formatted(locale: Locale(identifier: language))
            XCTAssertFalse(formatted.isEmpty)
            XCTAssertFalse(formatted.contains(":"))
            XCTAssertTrue(formatted.contains("2026"))
        }
        let link = EncounterLinkCard(id: "link", source: "Source", title: "Title", description: " ",
                                     tags: ["", "swift"], mainLanguage: "\n", openingText: "",
                                     url: URL(string: "https://example.com")!)
        XCTAssertNil(link.description); XCTAssertNil(link.mainLanguage); XCTAssertNil(link.openingText)
        XCTAssertEqual(link.tags, ["swift"])
    }

    @MainActor
    func testSampleVisibilityAndDismissalSurviveModelRecreation() {
        let store = SampleEncounterTestStore()
        let model = SampleEncounterModel(store: store, isNewUser: true)
        XCTAssertTrue(model.isVisible(in: .emptyFeed))
        XCTAssertTrue(model.isVisible(in: .discoveryOff))
        XCTAssertFalse(model.isVisible(in: .populatedFeed))
        XCTAssertTrue(SampleEncounterModel(store: store, isNewUser: false).isVisible(in: .emptyFeed))
        XCTAssertFalse(SampleEncounterModel(store: store, isNewUser: false).isVisible(in: .discoveryOff))
        model.dismiss()
        XCTAssertTrue(store.isSampleEncounterDismissed)
        for context in [SampleEncounterContext.emptyFeed, .discoveryOff, .populatedFeed] {
            XCTAssertFalse(model.isVisible(in: context))
            XCTAssertFalse(SampleEncounterModel(store: store, isNewUser: true).isVisible(in: context))
        }
        XCTAssertEqual(store.dismissals, 1)
    }

    func testSampleIsLocalFictionWithOnlySafeOriginalLinks() {
        for language in ["ja", "en"] {
            let sample = SampleEncounterPresentation.fixture(language: language)
            XCTAssertFalse(sample.displayName.isEmpty)
            XCTAssertFalse(sample.introduction.isEmpty)
            XCTAssertEqual(sample.links.count, 1)
            XCTAssertEqual(sample.links.first?.url.host, "example.com")
            XCTAssertEqual(sample.links.first?.url.scheme, "https")
            XCTAssertFalse(sample.links.contains { $0.saved || $0.verified })
        }
    }
}

@MainActor
final class SampleEncounterTestStore: SampleEncounterDismissalStore {
    var isSampleEncounterDismissed = false
    var dismissals = 0
    func dismissSampleEncounter() { isSampleEncounterDismissed = true; dismissals += 1 }
}
