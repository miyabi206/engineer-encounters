import Foundation
import XCTest
@testable import EncounterUI

@MainActor
final class DiscoverRetentionTests: XCTestCase {
    // Ordinary retention has expired; the client leaves that decision to the injected read.
    private let expiredDay = EncounterDay(year: 2026, month: 8, day: 1)

    private func retainedCard(favorite: Bool, saved: Bool) -> EncounterDetail {
        .init(card: .init(id: "card", kind: .ambient, day: expiredDay,
                         displayName: "Previously authorized name", introduction: "Introduction",
                         contactDetail: "Private contact", links: [DiscoverTestDriver.link()]),
              favorite: favorite, savedLinkIDs: saved ? ["link"] : [])
    }

    private func removeReason(_ model: DiscoverModel, favorite: Bool) async {
        if favorite { await model.setFavorite("card", favorite: false) }
        else { await model.setSaved("card", linkID: "link", saved: false) }
    }

    private func populatedModel(_ driver: DiscoverTestDriver, favorite: Bool) async -> DiscoverModel {
        driver.cards = [retainedCard(favorite: favorite, saved: !favorite), DiscoverTestDriver.card(id: "other")]
        let model = driver.model()
        await model.loadFeed(); await model.loadFavorites(); await model.loadSavedLinks(); await model.loadCard("card")
        return model
    }

    private func assertConcealed(_ model: DiscoverModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(model.card, file: file, line: line)
        XCTAssertFalse(model.feed.contains { $0.id == "card" }, file: file, line: line)
        XCTAssertFalse(model.favorites.contains { $0.id == "card" }, file: file, line: line)
        XCTAssertFalse(model.savedLinks.contains { $0.encounterID == "card" }, file: file, line: line)
        // With no published card or saved-link copy, neither contact nor original URL is usable.
    }

    func testLastFavoriteAndLastSavedLinkConcealUntilFreshAuthorizedOrReducedAnswer() async {
        for favorite in [true, false] {
            for reduced in [false, true] {
                let driver = DiscoverTestDriver()
                let model = await populatedModel(driver, favorite: favorite)
                let gate = DiscoverTestGate<EncounterDetail?>()
                driver.cardHook = { _ in try await gate.wait() }
                let writing = Task { await self.removeReason(model, favorite: favorite) }
                await gate.entered()
                assertConcealed(model)
                XCTAssertEqual(model.detailState, .loading)
                XCTAssertTrue(model.isWriting)
                XCTAssertEqual(model.feed.map(\.id), ["other"])
                let freshCard = reduced
                    ? EncounterCard(id: "card", kind: .ambient, day: expiredDay, isShell: true)
                    : retainedCard(favorite: false, saved: false).card
                let fresh = EncounterDetail(card: freshCard, favorite: false, savedLinkIDs: [])
                gate.resolve(.success(fresh))
                await writing.value
                XCTAssertEqual(model.card, fresh)
                XCTAssertEqual(model.detailState, .loaded)
                XCTAssertEqual(model.feed.first?.card, freshCard)
                XCTAssertTrue(model.favorites.isEmpty)
                XCTAssertTrue(model.savedLinks.isEmpty)
                XCTAssertFalse(model.isWriting)
                XCTAssertTrue(model.failedCardReloadIDs.isEmpty)
                if reduced {
                    XCTAssertNil(model.card?.card.contactDetail)
                    XCTAssertTrue(model.card?.card.links.isEmpty == true)
                }
            }
        }
    }

    func testLastFavoriteAndLastSavedLinkNotFoundRemoveEveryCopyAndSignalReturnToOrigin() async {
        for favorite in [true, false] {
            for returnsNil in [false, true] {
                let driver = DiscoverTestDriver()
                let model = await populatedModel(driver, favorite: favorite)
                let gate = DiscoverTestGate<EncounterDetail?>()
                driver.cardHook = { _ in try await gate.wait() }
                let writing = Task { await self.removeReason(model, favorite: favorite) }
                await gate.entered()
                assertConcealed(model)
                gate.resolve(returnsNil ? .success(nil) : .failure(ProfileActionError(code: .notFound)))
                await writing.value
                assertConcealed(model)
                // EncounterDetailView routes .missing through encounterRemoved to S06/S10.
                XCTAssertEqual(model.detailState, .missing)
                XCTAssertEqual(model.feed.map(\.id), ["other"])
                XCTAssertTrue(model.failedCardReloadIDs.isEmpty)
            }
        }
    }

    func testLastFavoriteAndLastSavedLinkFailedReloadStayConcealedAndRetryOnlyTheRead() async {
        for favorite in [true, false] {
            let driver = DiscoverTestDriver()
            let model = await populatedModel(driver, favorite: favorite)
            driver.cardHook = { _ in throw DiscoverActionError.unavailable }
            await removeReason(model, favorite: favorite)
            assertConcealed(model)
            XCTAssertEqual(model.detailState, .failed)
            XCTAssertEqual(model.failedCardReloadIDs, ["card"])
            XCTAssertNil(model.failedOperation)
            XCTAssertTrue(model.canRead)
            // Even a list response containing old copies cannot expose this concealed encounter.
            driver.cards = [retainedCard(favorite: true, saved: true), DiscoverTestDriver.card(id: "other")]
            await model.loadFeed(); await model.loadFavorites(); await model.loadSavedLinks()
            assertConcealed(model)
            await model.retryCardReloads()
            assertConcealed(model)
            XCTAssertEqual(model.failedCardReloadIDs, ["card"])
            let fresh = EncounterDetail(card: .init(id: "card", kind: .ambient, day: expiredDay, isShell: true),
                                        favorite: false, savedLinkIDs: [])
            driver.cardHook = { _ in fresh }
            await model.loadCard("card") // The detail Retry uses the same read-only recovery.
            XCTAssertEqual(model.card, fresh)
            XCTAssertEqual(model.feed.first?.card, fresh.card)
            XCTAssertTrue(model.favorites.isEmpty)
            XCTAssertTrue(model.savedLinks.isEmpty)
            XCTAssertTrue(model.failedCardReloadIDs.isEmpty)
            XCTAssertEqual(driver.writes, favorite ? ["favorite:false"] : ["unsave"])
        }
    }

    func testAllCopiesUseFreshFieldsWhenAnotherRetentionReasonRemains() async {
        for favorite in [true, false] {
            let driver = DiscoverTestDriver()
            let second = EncounterLinkCard(id: "second", source: "Source", title: "Old second",
                                          url: URL(string: "https://example.com/old")!)
            let old = EncounterCard(id: "card", kind: .ambient, day: expiredDay, displayName: "Old name",
                                    contactDetail: "Old contact", links: [DiscoverTestDriver.link(), second])
            driver.cards = [.init(card: old, favorite: true, savedLinkIDs: ["link", "second"])]
            let model = driver.model()
            await model.loadFeed(); await model.loadFavorites(); await model.loadSavedLinks(); await model.loadCard("card")
            let gate = DiscoverTestGate<EncounterDetail?>()
            driver.cardHook = { _ in try await gate.wait() }
            let writing = Task { await self.removeReason(model, favorite: favorite) }
            await gate.entered()
            assertConcealed(model)
            let freshLink = EncounterLinkCard(id: "second", source: "Source", title: "Fresh second",
                                             url: URL(string: "https://example.com/fresh")!)
            let fresh = EncounterDetail(card: .init(id: "card", kind: .ambient, day: expiredDay,
                                                   displayName: "Fresh name", links: [freshLink]),
                                        favorite: !favorite, savedLinkIDs: ["second"])
            gate.resolve(.success(fresh))
            await writing.value
            XCTAssertEqual(model.card, fresh)
            XCTAssertEqual(model.feed.first?.card, fresh.card)
            XCTAssertEqual(model.favorites.first?.card, favorite ? nil : fresh.card)
            XCTAssertEqual(model.savedLinks.map(\.link), [freshLink])
            XCTAssertNil(model.card?.card.contactDetail)
        }
    }

    func testListOnlyRemovalDoesNotOpenOrReplaceDetailAndHasReadRetry() async {
        for favorite in [true, false] {
            let driver = DiscoverTestDriver()
            driver.cards = [retainedCard(favorite: favorite, saved: !favorite)]
            let model = driver.model()
            await model.loadFavorites(); await model.loadSavedLinks()
            driver.cardHook = { _ in throw DiscoverActionError.unavailable }
            await removeReason(model, favorite: favorite)
            XCTAssertNil(model.card)
            XCTAssertEqual(model.detailState, .idle)
            XCTAssertEqual(model.failedCardReloadIDs, ["card"])
            driver.cardHook = { _ in nil }
            await model.retryCardReloads()
            XCTAssertTrue(model.failedCardReloadIDs.isEmpty)
            XCTAssertTrue(model.favorites.isEmpty)
            XCTAssertTrue(model.savedLinks.isEmpty)
            XCTAssertEqual(model.detailState, .idle)
            XCTAssertEqual(driver.writes.count, 1)
        }
    }

    func testOldListResponsesCannotRestorePreRemovalAuthorization() async {
        for favorite in [true, false] {
            let driver = DiscoverTestDriver()
            let model = await populatedModel(driver, favorite: favorite)
            let oldFeed = driver.feedResult, oldSaved = driver.savedResult
            let feedGate = DiscoverTestGate<EncounterCardList>()
            let favoritesGate = DiscoverTestGate<EncounterCardList>()
            let savedGate = DiscoverTestGate<EncounterSavedLinkList>()
            driver.feedHook = { try await feedGate.wait() }
            driver.favoritesHook = { try await favoritesGate.wait() }
            driver.savedHook = { try await savedGate.wait() }
            let feed = Task { await model.loadFeed() }
            let favorites = Task { await model.loadFavorites() }
            let saved = Task { await model.loadSavedLinks() }
            await feedGate.entered(); await favoritesGate.entered(); await savedGate.entered()
            driver.cardHook = { _ in .init(card: .init(id: "card", kind: .ambient, day: self.expiredDay, isShell: true),
                                          favorite: false, savedLinkIDs: []) }
            await removeReason(model, favorite: favorite)
            feedGate.resolve(.success(oldFeed)); favoritesGate.resolve(.success(oldFeed)); savedGate.resolve(.success(oldSaved))
            await feed.value; await favorites.value; await saved.value
            XCTAssertTrue(model.card?.card.isShell == true)
            XCTAssertFalse(model.feed.contains { $0.id == "card" && !$0.card.isShell })
            XCTAssertFalse(model.favorites.contains { $0.id == "card" })
            XCTAssertFalse(model.savedLinks.contains { $0.encounterID == "card" })
            XCTAssertEqual(model.feed.map(\.id), ["card", "other"])
            XCTAssertEqual(model.feed.first?.card, model.card?.card)
        }
    }

    func testListsRequestedDuringConcealmentPreserveReauthorizedCardAndLaterListsCanRemoveIt() async {
        let driver = DiscoverTestDriver()
        driver.cards = [retainedCard(favorite: true, saved: true), DiscoverTestDriver.card(id: "other")]
        let model = driver.model()
        await model.loadFeed(); await model.loadFavorites(); await model.loadSavedLinks()
        let oldFeed = driver.feedResult, oldSaved = driver.savedResult
        let cardGate = DiscoverTestGate<EncounterDetail?>()
        driver.cardHook = { _ in try await cardGate.wait() }
        let removing = Task { await model.setFavorite("card", favorite: false) }
        await cardGate.entered()
        let feedGate = DiscoverTestGate<EncounterCardList>(), favoritesGate = DiscoverTestGate<EncounterCardList>()
        let savedGate = DiscoverTestGate<EncounterSavedLinkList>()
        driver.feedHook = { try await feedGate.wait() }
        driver.favoritesHook = { try await favoritesGate.wait() }
        driver.savedHook = { try await savedGate.wait() }
        let feed = Task { await model.loadFeed() }, favorites = Task { await model.loadFavorites() }
        let saved = Task { await model.loadSavedLinks() }
        await feedGate.entered(); await favoritesGate.entered(); await savedGate.entered()
        var fresh = retainedCard(favorite: true, saved: true)
        fresh = .init(card: .init(id: "card", kind: .ambient, day: expiredDay, displayName: "Fresh name",
                                 links: [DiscoverTestDriver.link()]), favorite: true, savedLinkIDs: ["link"])
        cardGate.resolve(.success(fresh)); await removing.value
        feedGate.resolve(.success(oldFeed)); favoritesGate.resolve(.success(oldFeed)); savedGate.resolve(.success(oldSaved))
        await feed.value; await favorites.value; await saved.value
        XCTAssertEqual(model.feed.first?.card, fresh.card)
        XCTAssertEqual(model.favorites.first?.card, fresh.card)
        XCTAssertEqual(model.savedLinks.map(\.encounterID), ["card"])
        driver.feedHook = { .init(cards: [], truncated: false) }
        driver.favoritesHook = { .init(cards: [], truncated: false) }
        driver.savedHook = { .init(links: [], truncated: false) }
        await model.loadFeed(); await model.loadFavorites(); await model.loadSavedLinks()
        XCTAssertTrue(model.feed.isEmpty); XCTAssertTrue(model.favorites.isEmpty); XCTAssertTrue(model.savedLinks.isEmpty)
    }

    func testExtendingAccessKeepsOptimisticContentWithoutCardReload() async {
        let driver = DiscoverTestDriver()
        let model = await populatedModel(driver, favorite: false)
        let before = model.card?.card
        let reads = driver.reads.filter { $0 == "card" }.count
        await model.setFavorite("card", favorite: true)
        await model.setSaved("card", linkID: "link", saved: true)
        XCTAssertEqual(model.card?.card, before)
        XCTAssertEqual(model.card?.favorite, true)
        XCTAssertEqual(model.card?.savedLinkIDs, ["link"])
        XCTAssertEqual(driver.reads.filter { $0 == "card" }.count, reads)
    }
}
