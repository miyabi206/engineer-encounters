import XCTest
@testable import EncounterUI

final class DiscoverModelTests: XCTestCase {
    @MainActor
    func testFeedLoadingDropsContentAndFailureDoesNotDeclareEmpty() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadFeed()
        XCTAssertEqual(model.feedState, .loaded)
        XCTAssertEqual(model.feed.map(\.id), ["card"])
        let gate = DiscoverTestGate<[EncounterCard]>()
        driver.feedHook = { try await gate.wait() }
        let loading = Task { await model.loadFeed() }
        await gate.entered()
        XCTAssertEqual(model.feedState, .loading)
        XCTAssertTrue(model.feed.isEmpty)
        XCTAssertTrue(model.favorites.isEmpty); XCTAssertTrue(model.savedLinks.isEmpty); XCTAssertNil(model.card)
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await loading.value
        XCTAssertEqual(model.feedState, .failed)
        XCTAssertTrue(model.dayGroups.isEmpty)
        driver.feedHook = { [] }
        await model.loadFeed()
        XCTAssertEqual(model.feedState, .loaded)
        XCTAssertTrue(model.feed.isEmpty)
    }

    @MainActor
    func testFavoriteIsOptimisticDuplicateWritesAreDisabledAndFailureRollsBack() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("card")
        let gate = DiscoverTestGate<EncounterCard?>()
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
        await model.loadFavorites()
        let gate = DiscoverTestGate<EncounterCard?>()
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
        let saving = DiscoverTestGate<EncounterCard?>()
        driver.saveHook = { _, _, _ in try await saving.wait() }
        let task = Task { await model.setSaved("card", linkID: "link", saved: true) }
        await saving.entered()
        XCTAssertEqual(model.card?.links.first?.saved, true)
        XCTAssertEqual(model.savedLinks.map(\.id), ["link"])
        saving.resolve(.failure(DiscoverActionError.unavailable))
        await task.value
        XCTAssertEqual(model.card?.links.first?.saved, false)
        XCTAssertTrue(model.savedLinks.isEmpty)
        XCTAssertEqual(model.failedOperation, .save("card", "link", true))
        driver.saveHook = nil
        let retried = await model.retryOperation()
        XCTAssertTrue(retried)
        XCTAssertEqual(model.card?.links.first?.saved, true)
        await model.setSaved("card", linkID: "link", saved: false)
        XCTAssertEqual(model.card?.links.first?.saved, false)
        XCTAssertTrue(model.savedLinks.isEmpty)
        XCTAssertEqual(driver.writes, ["save", "save", "unsave"])
    }

    @MainActor
    func testUnsaveOnlySavedLinkContextRollsBackAndThenRemovesRetention() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(saved: true)]
        let model = driver.model()
        await model.loadFavorites()
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(model.savedLinks.map(\.id), ["link"])
        let gate = DiscoverTestGate<EncounterCard?>()
        driver.saveHook = { _, _, _ in try await gate.wait() }
        let task = Task { await model.setSaved("card", linkID: "link", saved: false) }
        await gate.entered()
        XCTAssertTrue(model.savedLinks.isEmpty)
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await task.value
        XCTAssertEqual(model.savedLinks.map(\.id), ["link"])
        driver.saveHook = { _, _, _ in nil }
        let retried = await model.retryOperation()
        XCTAssertTrue(retried)
        XCTAssertTrue(model.savedLinks.isEmpty)
    }

    @MainActor
    func testFavoritesPublishOnlyAfterBothFreshResponsesAndClearOnError() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true)]
        let model = driver.model()
        let gate = DiscoverTestGate<[EncounterSavedLink]>()
        driver.savedHook = { try await gate.wait() }
        let task = Task { await model.loadFavorites() }
        await gate.entered()
        XCTAssertEqual(model.favoritesState, .loading)
        XCTAssertTrue(model.favorites.isEmpty); XCTAssertTrue(model.savedLinks.isEmpty)
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await task.value
        XCTAssertEqual(model.favoritesState, .failed)
        XCTAssertTrue(model.favorites.isEmpty)
        driver.savedHook = nil
        await model.loadFavorites()
        XCTAssertEqual(model.favoritesState, .loaded)
        XCTAssertEqual(model.favorites.map(\.id), ["card"])
        XCTAssertEqual(model.savedLinks.map(\.id), ["link"])
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
        await model.loadFavorites()
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
        await model.loadFavorites()
        model.receiveAccess(discoveryOn: false, isAuthorized: true)
        XCTAssertTrue(model.favorites.isEmpty); XCTAssertTrue(model.savedLinks.isEmpty)
        let before = driver.reads
        await model.loadFeed(); await model.loadFavorites(); await model.loadCard("card")
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
            let gate = DiscoverTestGate<[EncounterCard]>()
            driver.feedHook = { try await gate.wait() }
            let task = Task { await model.loadFeed() }
            await gate.entered()
            model.receiveAccess(discoveryOn: false, isAuthorized: signedIn)
            gate.resolve(.success(driver.cards))
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
    func testRefreshFencesLateMutationFailureAndDoesNotRestoreOldProtectedContent() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("card")
        let gate = DiscoverTestGate<EncounterCard?>()
        driver.favoriteHook = { _, _ in try await gate.wait() }
        let task = Task { await model.setFavorite("card", favorite: true) }
        await gate.entered()
        driver.cards = [DiscoverTestDriver.card(id: "fresh")]
        await model.loadFeed()
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await task.value
        XCTAssertEqual(model.feed.map(\.id), ["fresh"])
        XCTAssertNil(model.card)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertNil(model.failedOperation)
    }

    @MainActor
    func testMissingCardAndExpiredRetentionRemoveContextWithoutStaleFallback() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("absent")
        XCTAssertEqual(model.detailState, .missing)
        XCTAssertNil(model.card)
        await model.loadCard("card")
        driver.favoriteHook = { _, _ in nil }
        await model.setFavorite("card", favorite: true)
        XCTAssertNil(model.card)
        XCTAssertEqual(model.detailState, .missing)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertTrue(model.savedLinks.isEmpty)
    }

    @MainActor
    func testFreshWriteResponseReplacesPrivateFieldsAndPurgesPrivateSavedLinks() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(saved: true)]
        let model = driver.model()
        await model.loadCard("card")
        driver.favoriteHook = { id, value in
            EncounterCard(id: id, kind: .ambient, day: DiscoverTestDriver.day, favorite: value, isShell: true)
        }
        await model.setFavorite("card", favorite: true)
        XCTAssertEqual(model.card?.isShell, true)
        XCTAssertNil(model.card?.displayName)
        XCTAssertEqual(model.card?.links, [])
        XCTAssertTrue(model.savedLinks.isEmpty)
    }
}

@MainActor
final class DiscoverTestDriver {
    nonisolated static let day = EncounterDay(year: 2026, month: 10, day: 12)
    var cards = [DiscoverTestDriver.card()]
    var writes: [String] = []
    var reads: [String] = []
    var feedHook: (@MainActor () async throws -> [EncounterCard])?
    var savedHook: (@MainActor () async throws -> [EncounterSavedLink])?
    var favoriteHook: (@MainActor (String, Bool) async throws -> EncounterCard?)?
    var saveHook: (@MainActor (String, String, Bool) async throws -> EncounterCard?)?
    var deleteHook: (@MainActor (String) async throws -> Void)?

    nonisolated static func link(saved: Bool = false) -> EncounterLinkCard {
        .init(id: "link", source: "Source", title: "Work", url: URL(string: "https://example.com")!, saved: saved)
    }
    nonisolated static func card(id: String = "card", favorite: Bool = false, saved: Bool = false) -> EncounterCard {
        .init(id: id, kind: .ambient, day: day, displayName: "Name", links: [link(saved: saved)], favorite: favorite)
    }

    func model() -> DiscoverModel {
        DiscoverModel(actions: .init(loadFeed: {
            self.reads.append("feed")
            if let hook = self.feedHook { return try await hook() }
            return self.cards
        }, loadCard: { id in
            self.reads.append("card")
            return self.cards.first { $0.id == id }
        }, setFavorite: { id, value in
            self.writes.append("favorite:\(value)")
            if let hook = self.favoriteHook { return try await hook(id, value) }
            guard let index = self.cards.firstIndex(where: { $0.id == id }) else { return nil }
            self.cards[index].favorite = value
            return self.cards[index]
        }, saveLink: { id, linkID in
            self.writes.append("save")
            return try await self.save(id, linkID: linkID, saved: true)
        }, unsaveLink: { id, linkID in
            self.writes.append("unsave")
            return try await self.save(id, linkID: linkID, saved: false)
        }, deleteEncounter: { id in
            self.writes.append("delete")
            if let hook = self.deleteHook { try await hook(id) }
            self.cards.removeAll { $0.id == id }
        }, loadFavorites: {
            self.reads.append("favorites")
            return self.cards.filter(\.favorite)
        }, loadSavedLinks: {
            self.reads.append("saved")
            if let hook = self.savedHook { return try await hook() }
            return self.cards.flatMap { card in
                card.links.filter(\.saved).map { EncounterSavedLink(encounterID: card.id, link: $0) }
            }
        }), discoveryOn: true)
    }

    private func save(_ id: String, linkID: String, saved: Bool) async throws -> EncounterCard? {
        if let hook = saveHook { return try await hook(id, linkID, saved) }
        guard let cardIndex = cards.firstIndex(where: { $0.id == id }),
              let linkIndex = cards[cardIndex].links.firstIndex(where: { $0.id == linkID }) else { return nil }
        cards[cardIndex].links[linkIndex].saved = saved
        return cards[cardIndex]
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
