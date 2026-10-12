import XCTest
@testable import EncounterUI

final class DiscoverModelTests: XCTestCase {
    @MainActor
    func testFeedRefreshPreservesContentAndOrdinaryFailureDoesNotDeclareEmpty() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadFeed()
        XCTAssertEqual(model.feedState, .loaded)
        XCTAssertEqual(model.feed.map(\.id), ["card"])
        let gate = DiscoverTestGate<EncounterCardList>()
        driver.feedHook = { try await gate.wait() }
        let loading = Task { await model.loadFeed() }
        await gate.entered()
        XCTAssertEqual(model.feedState, .loading)
        XCTAssertEqual(model.feed.map(\.id), ["card"])
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await loading.value
        XCTAssertEqual(model.feedState, .failed)
        XCTAssertEqual(model.dayGroups.first?.cards.map(\.id), ["card"])
        driver.feedHook = { .init(cards: [], truncated: false) }
        await model.loadFeed()
        XCTAssertEqual(model.feedState, .loaded)
        XCTAssertTrue(model.feed.isEmpty)
    }

    @MainActor
    func testFavoriteIsOptimisticDuplicateWritesAreDisabledAndFailureRollsBack() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadFavorites()
        await model.loadCard("card")
        let gate = DiscoverTestGate<EncounterFavoriteResult>()
        driver.favoriteHook = { _, _ in try await gate.wait() }
        let writing = Task { await model.setFavorite("card", favorite: true) }
        await gate.entered()
        XCTAssertTrue(model.isWriting)
        XCTAssertEqual(model.card?.favorite, true)
        XCTAssertEqual(model.favorites.map(\.id), ["card"])
        await model.setFavorite("card", favorite: false)
        XCTAssertEqual(driver.writes, ["favorite:true"])
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await writing.value
        XCTAssertFalse(model.isWriting)
        XCTAssertEqual(model.card?.favorite, false)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(model.failedOperation, .favorite("card", true))
        driver.favoriteHook = nil
        let success = await model.retryOperation()
        XCTAssertTrue(success)
        XCTAssertEqual(model.card?.favorite, true)
        XCTAssertNil(model.failedOperation)
    }

    @MainActor
    func testRemovingFavoriteFromS10RollsBackItsOriginalPosition() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(id: "z", favorite: true),
                        DiscoverTestDriver.card(id: "a", favorite: true)]
        let model = driver.model()
        await model.loadFavorites(); await model.loadSavedLinks()
        let gate = DiscoverTestGate<EncounterFavoriteResult>()
        driver.favoriteHook = { _, _ in try await gate.wait() }
        let writing = Task { await model.setFavorite("z", favorite: false) }
        await gate.entered()
        XCTAssertEqual(model.favorites.map(\.id), ["a"])
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await writing.value
        XCTAssertEqual(model.favorites.map(\.id), ["z", "a"])
        XCTAssertEqual(model.favoriteDayGroups.first?.cards.map(\.id), ["z", "a"])
    }

    @MainActor
    func testSaveAndUnsaveOptimisticStateAndRollbackUseDistinctActions() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("card")
        await model.loadSavedLinks()
        let saving = DiscoverTestGate<EncounterSavedResult>()
        driver.saveHook = { _, _, _ in try await saving.wait() }
        let task = Task { await model.setSaved("card", linkID: "link", saved: true) }
        await saving.entered()
        XCTAssertEqual(model.card.map { $0.savedLinkIDs.contains("link") }, true)
        XCTAssertEqual(model.savedLinks.map { $0.link.id }, ["link"])
        saving.resolve(.failure(DiscoverActionError.unavailable))
        await task.value
        XCTAssertEqual(model.card.map { $0.savedLinkIDs.contains("link") }, false)
        XCTAssertTrue(model.savedLinks.isEmpty)
        XCTAssertEqual(model.failedOperation, .save("card", "link", true))
        driver.saveHook = nil
        let retried = await model.retryOperation()
        XCTAssertTrue(retried)
        XCTAssertEqual(model.card.map { $0.savedLinkIDs.contains("link") }, true)
        await model.setSaved("card", linkID: "link", saved: false)
        XCTAssertEqual(model.card.map { $0.savedLinkIDs.contains("link") }, false)
        XCTAssertTrue(model.savedLinks.isEmpty)
        XCTAssertEqual(driver.writes, ["save", "save", "unsave"])
    }

    @MainActor
    func testUnsaveOnlySavedLinkContextRollsBackAndThenRemovesRetention() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(saved: true)]
        let model = driver.model()
        await model.loadFavorites(); await model.loadSavedLinks()
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(model.savedLinks.map { $0.link.id }, ["link"])
        let gate = DiscoverTestGate<EncounterSavedResult>()
        driver.saveHook = { _, _, _ in try await gate.wait() }
        let task = Task { await model.setSaved("card", linkID: "link", saved: false) }
        await gate.entered()
        XCTAssertTrue(model.savedLinks.isEmpty)
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await task.value
        XCTAssertEqual(model.savedLinks.map { $0.link.id }, ["link"])
        driver.saveHook = { id, linkID, value in .init(encounterID: id, linkID: linkID, saved: value) }
        let retried = await model.retryOperation()
        XCTAssertTrue(retried)
        XCTAssertTrue(model.savedLinks.isEmpty)
    }

    @MainActor
    func testFavoritesAndSavedLinksPublishIndependentlyAndPreserveContentOnFailure() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true)]
        let model = driver.model()
        await model.loadFavorites()
        let gate = DiscoverTestGate<EncounterSavedLinkList>()
        driver.savedHook = { try await gate.wait() }
        let task = Task { await model.loadSavedLinks() }
        await gate.entered()
        XCTAssertEqual(model.favoritesState, .loaded)
        XCTAssertEqual(model.favorites.map(\.id), ["card"])
        XCTAssertEqual(model.savedLinksState, .loading)
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await task.value
        XCTAssertEqual(model.savedLinksState, .failed)
        XCTAssertEqual(model.favorites.map(\.id), ["card"])
        driver.savedHook = nil
        await model.loadSavedLinks()
        XCTAssertEqual(model.savedLinksState, .loaded)
        XCTAssertEqual(model.savedLinks.map { $0.link.id }, ["link"])
        driver.favoritesHook = { throw DiscoverActionError.unavailable }
        await model.loadFavorites()
        XCTAssertEqual(model.favoritesState, .failed)
        XCTAssertEqual(model.favorites.map(\.id), ["card"])
        XCTAssertEqual(model.savedLinks.map { $0.link.id }, ["link"])
    }

    @MainActor
    func testDeletionRequiresConfirmationCancelDoesNothingAndFailureCanRetry() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("card")
        let unconfirmed = await model.confirmDeletion()
        XCTAssertFalse(unconfirmed)
        model.requestDeletion("card")
        XCTAssertEqual(model.deletion, .confirming("card"))
        model.cancelDeletion()
        XCTAssertEqual(model.deletion, .none)
        XCTAssertTrue(driver.writes.isEmpty)
        let gate = DiscoverTestGate<Void>()
        driver.deleteHook = { _ in try await gate.wait() }
        model.requestDeletion("card")
        let task = Task { await model.confirmDeletion() }
        await gate.entered()
        XCTAssertEqual(model.deletion, .deleting("card"))
        XCTAssertNotNil(model.card)
        model.cancelDeletion()
        XCTAssertEqual(model.deletion, .deleting("card"))
        gate.resolve(.failure(DiscoverActionError.unavailable))
        let deleted = await task.value
        XCTAssertFalse(deleted)
        XCTAssertNotNil(model.card)
        XCTAssertEqual(model.deletion, .failed("card"))
        driver.deleteHook = nil
        let retried = await model.retryOperation()
        XCTAssertTrue(retried)
        XCTAssertNil(model.card)
        XCTAssertEqual(model.detailState, .missing)
        XCTAssertEqual(model.deletion, .none)
    }

    @MainActor
    func testSuccessfulDeletionPurgesFavoritesAndSavedLinksOnlyAfterConfirmation() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true)]
        let model = driver.model()
        await model.loadFavorites(); await model.loadSavedLinks()
        model.requestDeletion("card")
        let deleted = await model.confirmDeletion()
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.favorites.isEmpty); XCTAssertTrue(model.savedLinks.isEmpty)
        XCTAssertEqual(driver.writes, ["delete"])
    }

    @MainActor
    func testConfirmationSurfaceDismissalCannotCancelAnApprovedDeletion() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("card")
        model.requestDeletion("card")
        model.approveDeletion()
        model.cancelDeletion() // SwiftUI dismisses the surface before starting the async task.
        XCTAssertEqual(model.deletion, .deleting("card"))
        let deleted = await model.confirmDeletion()
        XCTAssertTrue(deleted)
        XCTAssertEqual(driver.writes, ["delete"])
    }

    @MainActor
    func testDiscoveryOffAndSignOutClearAllProtectedMemoryAndRefuseReads() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true)]
        let model = driver.model()
        await model.loadFavorites(); await model.loadSavedLinks()
        model.receiveAccess(discoveryOn: false, isAuthorized: true)
        XCTAssertTrue(model.favorites.isEmpty); XCTAssertTrue(model.savedLinks.isEmpty)
        let before = driver.reads
        await model.loadFeed(); await model.loadFavorites(); await model.loadSavedLinks(); await model.loadCard("card")
        XCTAssertEqual(driver.reads, before)
        model.receiveAccess(discoveryOn: true, isAuthorized: true)
        await model.loadFeed()
        model.receiveAccess(discoveryOn: true, isAuthorized: false)
        XCTAssertTrue(model.feed.isEmpty); XCTAssertNil(model.card)
        XCTAssertFalse(model.canRead)
    }

    @MainActor
    func testLateResponseCannotResurrectCardAfterSignOutOrOff() async {
        for signedIn in [false, true] {
            let driver = DiscoverTestDriver()
            let model = driver.model()
            let gate = DiscoverTestGate<EncounterCardList>()
            driver.feedHook = { try await gate.wait() }
            let task = Task { await model.loadFeed() }
            await gate.entered()
            model.receiveAccess(discoveryOn: false, isAuthorized: signedIn)
            gate.resolve(.success(driver.feedResult))
            await task.value
            XCTAssertTrue(model.feed.isEmpty)
            XCTAssertEqual(model.feedState, .idle)
        }
    }

    @MainActor
    func testAuthorizationFailureClearsOptimisticChangesWithoutRollback() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("card")
        driver.favoriteHook = { _, _ in throw DiscoverActionError.authorizationFailed }
        await model.setFavorite("card", favorite: true)
        XCTAssertFalse(model.isAuthorized)
        XCTAssertNil(model.card); XCTAssertTrue(model.favorites.isEmpty); XCTAssertTrue(model.savedLinks.isEmpty)
        XCTAssertNil(model.failedOperation)
        XCTAssertFalse(model.isWriting)
        model.receiveAccess(discoveryOn: true, isAuthorized: true)
        driver.feedHook = { throw ProfileActionError(code: .notAuthenticated) }
        await model.loadFeed()
        XCTAssertFalse(model.isAuthorized)
        XCTAssertEqual(model.feedState, .failed)
    }

    @MainActor
    func testFeedRefreshDoesNotCancelDetailMutationAndRollbackKeepsFreshFeed() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("card")
        let gate = DiscoverTestGate<EncounterFavoriteResult>()
        driver.favoriteHook = { _, _ in try await gate.wait() }
        let task = Task { await model.setFavorite("card", favorite: true) }
        await gate.entered()
        driver.cards = [DiscoverTestDriver.card(id: "fresh")]
        await model.loadFeed()
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await task.value
        XCTAssertEqual(model.feed.map(\.id), ["fresh"])
        XCTAssertEqual(model.card?.card.id, "card")
        XCTAssertEqual(model.card?.favorite, false)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(model.failedOperation, .favorite("card", true))
    }

    @MainActor
    func testMissingCardAndNotFoundWriteRemoveContextWithoutStaleFallback() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("absent")
        XCTAssertEqual(model.detailState, .missing)
        XCTAssertNil(model.card)
        await model.loadCard("card")
        driver.favoriteHook = { _, _ in throw DiscoverActionError.notFound }
        await model.setFavorite("card", favorite: true)
        XCTAssertNil(model.card)
        XCTAssertEqual(model.detailState, .missing)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertTrue(model.savedLinks.isEmpty)
    }

    @MainActor
    func testFlagOnlyWritesPreservePrivateFieldsAndUnrelatedSavedReferences() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(saved: true), DiscoverTestDriver.card(id: "other", saved: true)]
        let model = driver.model()
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        await model.loadCard("card")
        let before = model.card?.card
        await model.setFavorite("card", favorite: true)
        XCTAssertEqual(model.card?.card, before)
        XCTAssertEqual(model.card?.favorite, true)
        XCTAssertEqual(model.card?.savedLinkIDs, ["link"])
        XCTAssertEqual(model.feed.first { $0.id == "other" }?.favorite, false)
        XCTAssertEqual(model.savedLinks.count, 2)
        await model.setSaved("card", linkID: "link", saved: false)
        XCTAssertEqual(model.card?.card, before)
        XCTAssertEqual(model.card?.favorite, true)
        XCTAssertEqual(model.savedLinks.map(\.encounterID), ["other"])
    }

    @MainActor
    func testFreshAuthorizedReadsPurgePrivateFieldsAndHiddenSavedReferences() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(saved: true)]
        let model = driver.model()
        await model.loadCard("card")
        await model.loadSavedLinks()
        driver.cards = [.init(card: EncounterCard(id: "card", kind: .ambient, day: DiscoverTestDriver.day,
                                                 isShell: true), favorite: false, savedLinkIDs: [])]
        await model.loadCard("card")
        await model.loadSavedLinks()
        XCTAssertEqual(model.card?.card.isShell, true)
        XCTAssertNil(model.card?.card.displayName)
        XCTAssertEqual(model.card?.card.links, [])
        XCTAssertTrue(model.savedLinks.isEmpty)
    }

}

@MainActor
final class DiscoverTestDriver {
    nonisolated static let day = EncounterDay(year: 2026, month: 10, day: 12)
    var cards = [DiscoverTestDriver.card()]
    var writes: [String] = []
    var reads: [String] = []
    var feedHook: (@MainActor () async throws -> EncounterCardList)?
    var favoritesHook: (@MainActor () async throws -> EncounterCardList)?
    var savedHook: (@MainActor () async throws -> EncounterSavedLinkList)?
    var cardHook: (@MainActor (String) async throws -> EncounterDetail?)?
    var favoriteHook: (@MainActor (String, Bool) async throws -> EncounterFavoriteResult)?
    var saveHook: (@MainActor (String, String, Bool) async throws -> EncounterSavedResult)?
    var deleteHook: (@MainActor (String) async throws -> Void)?

    nonisolated static func link() -> EncounterLinkCard {
        .init(id: "link", source: "Source", title: "Work", url: URL(string: "https://example.com")!)
    }
    nonisolated static func card(id: String = "card", favorite: Bool = false, saved: Bool = false) -> EncounterDetail {
        .init(card: .init(id: id, kind: .ambient, day: day, displayName: "Name", links: [link()]),
              favorite: favorite, savedLinkIDs: saved ? ["link"] : [])
    }
    var feedResult: EncounterCardList {
        .init(cards: cards.map { .init(card: $0.card, favorite: $0.favorite) }, truncated: false)
    }
    var savedResult: EncounterSavedLinkList {
        .init(links: cards.flatMap { detail in
            detail.card.links.filter { detail.savedLinkIDs.contains($0.id) }.map {
                EncounterSavedLink(encounterID: detail.card.id, day: detail.card.day, kind: detail.card.kind, link: $0)
            }
        }, truncated: false)
    }

    func model() -> DiscoverModel {
        DiscoverModel(actions: .init(loadFeed: {
            self.reads.append("feed")
            if let hook = self.feedHook { return try await hook() }
            return self.feedResult
        }, loadCard: { id in
            self.reads.append("card")
            if let hook = self.cardHook { return try await hook(id) }
            return self.cards.first { $0.card.id == id }
        }, setFavorite: { id, value in
            self.writes.append("favorite:\(value)")
            if let hook = self.favoriteHook { return try await hook(id, value) }
            guard let index = self.cards.firstIndex(where: { $0.card.id == id }) else { throw DiscoverActionError.notFound }
            self.cards[index].favorite = value
            return .init(encounterID: id, favorite: value)
        }, saveLink: { id, linkID in
            self.writes.append("save")
            return try await self.save(id, linkID: linkID, saved: true)
        }, unsaveLink: { id, linkID in
            self.writes.append("unsave")
            return try await self.save(id, linkID: linkID, saved: false)
        }, deleteEncounter: { id in
            self.writes.append("delete")
            if let hook = self.deleteHook { try await hook(id) }
            self.cards.removeAll { $0.card.id == id }
        }, loadFavorites: {
            self.reads.append("favorites")
            if let hook = self.favoritesHook { return try await hook() }
            return .init(cards: self.feedResult.cards.filter(\.favorite), truncated: false)
        }, loadSavedLinks: {
            self.reads.append("saved")
            if let hook = self.savedHook { return try await hook() }
            return self.savedResult
        }), discoveryOn: true)
    }

    private func save(_ id: String, linkID: String, saved: Bool) async throws -> EncounterSavedResult {
        if let hook = saveHook { return try await hook(id, linkID, saved) }
        guard let index = cards.firstIndex(where: { $0.card.id == id }),
              cards[index].card.links.contains(where: { $0.id == linkID }) else { throw DiscoverActionError.notFound }
        if saved { cards[index].savedLinkIDs.insert(linkID) }
        else { cards[index].savedLinkIDs.remove(linkID) }
        return .init(encounterID: id, linkID: linkID, saved: saved)
    }
}

/// Deterministic suspension: tests inject completion rather than sleeping or reading wall time.
@MainActor
final class DiscoverTestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasEntered = false

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            hasEntered = true
            for waiter in entryWaiters { waiter.resume() }
            entryWaiters = []
        }
    }

    func entered() async {
        if hasEntered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func resolve(_ result: Result<Value, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
