import XCTest
@testable import EncounterUI

final class DiscoverRecoveryTests: XCTestCase {
    @MainActor
    func testAllFourRefreshesHaveIndependentStatesAndKeepContentOnOrdinaryFailures() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true)]
        let model = driver.model()
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        await model.loadCard("card")
        let originalFeed = model.feed, originalFavorites = model.favorites, originalSaved = model.savedLinks
        let originalCard = model.card
        let feed = DiscoverTestGate<EncounterCardList>()
        let favorites = DiscoverTestGate<EncounterCardList>()
        let saved = DiscoverTestGate<EncounterSavedLinkList>()
        let card = DiscoverTestGate<EncounterDetail?>()
        driver.feedHook = { try await feed.wait() }
        driver.favoritesHook = { try await favorites.wait() }
        driver.savedHook = { try await saved.wait() }
        driver.cardHook = { _ in try await card.wait() }
        let feedTask = Task { await model.loadFeed() }
        await feed.entered()
        XCTAssertEqual(model.feedState, .loading)
        XCTAssertEqual(model.favoritesState, .loaded)
        XCTAssertEqual(model.savedLinksState, .loaded)
        XCTAssertEqual(model.detailState, .loaded)
        let favoritesTask = Task { await model.loadFavorites() }
        await favorites.entered()
        XCTAssertEqual(model.feedState, .loading)
        XCTAssertEqual(model.favoritesState, .loading)
        XCTAssertEqual(model.savedLinksState, .loaded)
        XCTAssertEqual(model.detailState, .loaded)
        let savedTask = Task { await model.loadSavedLinks() }
        await saved.entered()
        let cardTask = Task { await model.loadCard("card") }
        await card.entered()
        XCTAssertEqual(model.savedLinksState, .loading)
        XCTAssertEqual(model.detailState, .loading)
        XCTAssertEqual(model.feed, originalFeed)
        XCTAssertEqual(model.favorites, originalFavorites)
        XCTAssertEqual(model.savedLinks, originalSaved)
        XCTAssertEqual(model.card, originalCard)
        feed.resolve(.failure(DiscoverActionError.unavailable))
        await feedTask.value
        XCTAssertEqual(model.feedState, .failed)
        XCTAssertEqual(model.favoritesState, .loading)
        XCTAssertEqual(model.savedLinksState, .loading)
        XCTAssertEqual(model.detailState, .loading)
        favorites.resolve(.failure(DiscoverActionError.unavailable))
        saved.resolve(.failure(DiscoverActionError.unavailable))
        card.resolve(.failure(DiscoverActionError.unavailable))
        await favoritesTask.value
        await savedTask.value
        await cardTask.value
        XCTAssertEqual(model.feed, originalFeed)
        XCTAssertEqual(model.favorites, originalFavorites)
        XCTAssertEqual(model.savedLinks, originalSaved)
        XCTAssertEqual(model.card, originalCard)
        XCTAssertEqual(model.favoritesState, .failed)
        XCTAssertEqual(model.savedLinksState, .failed)
        XCTAssertEqual(model.detailState, .failed)
    }

    @MainActor
    func testEachResourceFencesItsOwnSupersededResponseAndNewerCardWins() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true)]
        let oldFeed = driver.feedResult, oldSaved = driver.savedResult, oldCard = driver.cards.first
        let model = driver.model()
        let feed = DiscoverTestGate<EncounterCardList>()
        let favorites = DiscoverTestGate<EncounterCardList>()
        let saved = DiscoverTestGate<EncounterSavedLinkList>()
        let card = DiscoverTestGate<EncounterDetail?>()
        driver.feedHook = { try await feed.wait() }
        driver.favoritesHook = { try await favorites.wait() }
        driver.savedHook = { try await saved.wait() }
        driver.cardHook = { _ in try await card.wait() }
        let feedTask = Task { await model.loadFeed() }
        let favoritesTask = Task { await model.loadFavorites() }
        let savedTask = Task { await model.loadSavedLinks() }
        let cardTask = Task { await model.loadCard("card") }
        await feed.entered()
        await favorites.entered()
        await saved.entered()
        await card.entered()
        driver.feedHook = nil; driver.favoritesHook = nil; driver.savedHook = nil; driver.cardHook = nil
        driver.cards = [DiscoverTestDriver.card(id: "new", favorite: true, saved: true)]
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        await model.loadCard("new")
        feed.resolve(.success(oldFeed))
        favorites.resolve(.failure(DiscoverActionError.authorizationFailed))
        saved.resolve(.success(oldSaved))
        card.resolve(.success(oldCard))
        await feedTask.value
        await favoritesTask.value
        await savedTask.value
        await cardTask.value
        XCTAssertEqual(model.feed.map(\.id), ["new"])
        XCTAssertEqual(model.favorites.map(\.id), ["new"])
        XCTAssertEqual(model.savedLinks.map(\.encounterID), ["new"])
        XCTAssertEqual(model.card?.card.id, "new")
        XCTAssertEqual(model.feedState, .loaded)
        XCTAssertEqual(model.favoritesState, .loaded)
        XCTAssertEqual(model.savedLinksState, .loaded)
        XCTAssertEqual(model.detailState, .loaded)
        XCTAssertTrue(model.isAuthorized)
    }

    @MainActor
    func testSignOutWithDiscoveryOnFencesAllLoadsAndRefusesReads() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true)]
        let model = driver.model()
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        await model.loadCard("card")
        let feed = DiscoverTestGate<EncounterCardList>()
        let favorites = DiscoverTestGate<EncounterCardList>()
        let saved = DiscoverTestGate<EncounterSavedLinkList>()
        let card = DiscoverTestGate<EncounterDetail?>()
        driver.feedHook = { try await feed.wait() }
        driver.favoritesHook = { try await favorites.wait() }
        driver.savedHook = { try await saved.wait() }
        driver.cardHook = { _ in try await card.wait() }
        let feedTask = Task { await model.loadFeed() }
        let favoritesTask = Task { await model.loadFavorites() }
        let savedTask = Task { await model.loadSavedLinks() }
        let cardTask = Task { await model.loadCard("card") }
        await feed.entered()
        await favorites.entered()
        await saved.entered()
        await card.entered()
        model.receiveAccess(discoveryOn: true, isAuthorized: false)
        XCTAssertTrue(model.discoveryOn)
        XCTAssertFalse(model.canRead)
        XCTAssertTrue(model.feed.isEmpty)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertTrue(model.savedLinks.isEmpty)
        XCTAssertNil(model.card)
        feed.resolve(.success(driver.feedResult))
        favorites.resolve(.success(driver.feedResult))
        saved.resolve(.success(driver.savedResult))
        card.resolve(.success(driver.cards.first))
        await feedTask.value
        await favoritesTask.value
        await savedTask.value
        await cardTask.value
        let reads = driver.reads
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        await model.loadCard("card")
        XCTAssertEqual(driver.reads, reads)
        XCTAssertTrue(model.feed.isEmpty)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertTrue(model.savedLinks.isEmpty)
        XCTAssertNil(model.card)
        XCTAssertEqual(model.feedState, .idle)
        XCTAssertEqual(model.favoritesState, .idle)
        XCTAssertEqual(model.savedLinksState, .idle)
        XCTAssertEqual(model.detailState, .idle)
    }

    @MainActor
    func testAuthorizationCodesClearAllContentAndAccessReturnAutomaticallyReloads() async {
        for code in [ProfileActionError.Code.notAuthenticated, .accountNotReady, .declarationRequired] {
            let driver = DiscoverTestDriver()
            driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true)]
            let model = driver.model()
            await model.loadFeed()
            await model.loadFavorites()
            await model.loadSavedLinks()
            await model.loadCard("card")
            driver.feedHook = { throw ProfileActionError(code: code) }
            await model.loadFeed()
            XCTAssertFalse(model.isAuthorized, code.rawValue)
            XCTAssertTrue(model.feed.isEmpty)
            XCTAssertTrue(model.favorites.isEmpty)
            XCTAssertTrue(model.savedLinks.isEmpty)
            XCTAssertNil(model.card)
            driver.feedHook = nil
            let before = driver.reads.count
            let reload = model.receiveAccess(discoveryOn: true, isAuthorized: true)
            await reload?.value
            XCTAssertEqual(driver.reads.count, before + 4)
            XCTAssertEqual(model.feedState, .loaded)
            XCTAssertEqual(model.favoritesState, .loaded)
            XCTAssertEqual(model.savedLinksState, .loaded)
            XCTAssertEqual(model.detailState, .loaded)
            XCTAssertEqual(model.card?.card.id, "card")
            XCTAssertEqual(model.favorites.map(\.id), ["card"])
            XCTAssertEqual(model.savedLinks.map(\.encounterID), ["card"])
        }
    }

    @MainActor
    func testRetryPerformsReadEvenAfterAuthorizationFailureForEveryResource() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        driver.feedHook = { throw ProfileActionError(code: .notAuthenticated) }
        await model.loadFeed()
        driver.feedHook = nil
        await model.loadFeed()
        XCTAssertTrue(model.canRead)
        XCTAssertEqual(model.feedState, .loaded)
        driver.favoritesHook = { throw ProfileActionError(code: .accountNotReady) }
        await model.loadFavorites()
        driver.favoritesHook = nil
        await model.loadFavorites()
        XCTAssertTrue(model.canRead)
        XCTAssertEqual(model.favoritesState, .loaded)
        driver.savedHook = { throw ProfileActionError(code: .declarationRequired) }
        await model.loadSavedLinks()
        driver.savedHook = nil
        await model.loadSavedLinks()
        XCTAssertTrue(model.canRead)
        XCTAssertEqual(model.savedLinksState, .loaded)
        driver.cardHook = { _ in throw ProfileActionError(code: .notAuthenticated) }
        await model.loadCard("card")
        driver.cardHook = nil
        await model.loadCard("card")
        XCTAssertTrue(model.canRead)
        XCTAssertEqual(model.detailState, .loaded)
        XCTAssertEqual(driver.reads, ["feed", "feed", "favorites", "favorites", "saved", "saved", "card", "card"])
    }

    @MainActor
    func testUnchangedAccessDoesNotClearContentOrCancelLoads() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("card")
        let gate = DiscoverTestGate<EncounterCardList>()
        driver.feedHook = { try await gate.wait() }
        let task = Task { await model.loadFeed() }
        await gate.entered()
        let reload = model.receiveAccess(discoveryOn: true, isAuthorized: true)
        XCTAssertNil(reload)
        XCTAssertNotNil(model.card)
        XCTAssertEqual(model.feedState, .loading)
        gate.resolve(.success(driver.feedResult))
        await task.value
        XCTAssertEqual(model.feedState, .loaded)
        XCTAssertNotNil(model.card)
    }

    @MainActor
    func testDiscoveryPrerequisiteSelectsS24AndActivationReloadsFeed() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadCard("card")
        driver.feedHook = { throw ProfileActionError(code: .prerequisiteMissing, fields: ["discovery"]) }
        await model.loadFeed()
        XCTAssertFalse(model.discoveryOn)
        XCTAssertNil(model.card)
        XCTAssertEqual(DiscoverFeedContent.select(discoveryOn: model.discoveryOn, isAuthorized: model.isAuthorized,
                                                 state: model.feedState, hasCards: !model.feed.isEmpty), .discoveryOff)
        driver.feedHook = nil
        let reload = model.receiveAccess(discoveryOn: true, isAuthorized: true)
        await reload?.value
        XCTAssertEqual(model.feedState, .loaded)
        XCTAssertEqual(model.detailState, .loaded)
        driver.feedHook = { throw ProfileActionError(code: .prerequisiteMissing, fields: ["link"]) }
        await model.loadFeed()
        XCTAssertTrue(model.discoveryOn)
        XCTAssertEqual(model.feedState, .failed)
        XCTAssertNotNil(model.card)
    }

    @MainActor
    func testTwoSavedReferencesToSameLinkHaveDifferentIdentitiesAndUnsaveChangesOnlyOne() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(id: "first", saved: true),
                        DiscoverTestDriver.card(id: "second", saved: true)]
        let model = driver.model()
        await model.loadSavedLinks()
        await model.loadCard("second")
        XCTAssertEqual(Set(model.savedLinks.map(\.id)).count, 2)
        XCTAssertEqual(model.savedLinks.map(\.day), [DiscoverTestDriver.day, DiscoverTestDriver.day])
        XCTAssertEqual(model.savedLinks.map(\.kind), [.ambient, .ambient])
        await model.setSaved("first", linkID: "link", saved: false)
        XCTAssertEqual(model.savedLinks.map(\.encounterID), ["second"])
        XCTAssertEqual(model.card?.savedLinkIDs, ["link"])
        await model.loadCard("first")
        await model.setSaved("first", linkID: "link", saved: true)
        XCTAssertEqual(Set(model.savedLinks.map(\.id)).count, 2)
        XCTAssertEqual(model.card?.savedLinkIDs, ["link"])
    }

    @MainActor
    func testSingleCardOwnStateIsIndependentOfAllListFlagsAndCaps() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true)]
        let model = driver.model()
        driver.feedHook = { .init(cards: [.init(card: DiscoverTestDriver.card().card, favorite: false)], truncated: true) }
        driver.favoritesHook = { .init(cards: [], truncated: true) }
        driver.savedHook = { .init(links: [], truncated: true) }
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        await model.loadCard("card")
        let controls = model.card.map(EncounterDetailControls.init)
        XCTAssertEqual(controls?.favoriteLabel, .removeFavorite)
        XCTAssertEqual(controls?.savedLabel(linkID: "link"), .unsaveLink)
        XCTAssertEqual(model.card?.favorite, true)
        XCTAssertEqual(model.card?.savedLinkIDs, ["link"])
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        XCTAssertEqual(model.card?.favorite, true)
        XCTAssertEqual(model.card?.savedLinkIDs, ["link"])
    }

    @MainActor
    func testTruncationFlagsAreIndependentAndResetOnSuccessfulUntruncatedReads() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        driver.feedHook = { .init(cards: [], truncated: true) }
        driver.favoritesHook = { .init(cards: [], truncated: true) }
        driver.savedHook = { .init(links: [], truncated: true) }
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        XCTAssertTrue(model.feedTruncated)
        XCTAssertTrue(model.favoritesTruncated)
        XCTAssertTrue(model.savedLinksTruncated)
        driver.feedHook = nil
        await model.loadFeed()
        XCTAssertFalse(model.feedTruncated)
        XCTAssertTrue(model.favoritesTruncated)
        XCTAssertTrue(model.savedLinksTruncated)
        driver.favoritesHook = nil; driver.savedHook = nil
        await model.loadFavorites()
        await model.loadSavedLinks()
        XCTAssertFalse(model.favoritesTruncated)
        XCTAssertFalse(model.savedLinksTruncated)
    }

    @MainActor
    func testSuccessfulWritesUseReturnedValueAndRejectMismatchedIdentifiers() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        await model.loadCard("card")
        driver.favoriteHook = { id, _ in .init(encounterID: id, favorite: false) }
        await model.setFavorite("card", favorite: true)
        XCTAssertEqual(model.card?.favorite, false)
        XCTAssertEqual(model.feed.first?.favorite, false)
        XCTAssertTrue(model.favorites.isEmpty)
        driver.saveHook = { id, linkID, _ in .init(encounterID: id, linkID: linkID, saved: false) }
        await model.setSaved("card", linkID: "link", saved: true)
        XCTAssertEqual(model.card?.savedLinkIDs, [])
        XCTAssertTrue(model.savedLinks.isEmpty)
        driver.favoriteHook = { _, _ in .init(encounterID: "other", favorite: true) }
        await model.setFavorite("card", favorite: true)
        XCTAssertEqual(model.card?.favorite, false)
        XCTAssertEqual(model.failedOperation, .favorite("card", true))
        driver.saveHook = { id, _, _ in .init(encounterID: id, linkID: "other", saved: true) }
        await model.setSaved("card", linkID: "link", saved: true)
        XCTAssertEqual(model.card?.savedLinkIDs, [])
        XCTAssertTrue(model.savedLinks.isEmpty)
        XCTAssertEqual(model.failedOperation, .save("card", "link", true))
    }

    @MainActor
    func testNotFoundCardDoesNotCancelListReadsOrResurrectItsContext() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true), DiscoverTestDriver.card(id: "other")]
        let model = driver.model()
        await model.loadCard("card")
        let gate = DiscoverTestGate<EncounterCardList>()
        driver.feedHook = { try await gate.wait() }
        let task = Task { await model.loadFeed() }
        await gate.entered()
        driver.cardHook = { _ in throw ProfileActionError(code: .notFound) }
        await model.loadCard("card")
        XCTAssertNil(model.card)
        XCTAssertEqual(model.detailState, .missing)
        XCTAssertEqual(model.feedState, .loading)
        gate.resolve(.success(driver.feedResult))
        await task.value
        XCTAssertEqual(model.feedState, .loaded)
        XCTAssertEqual(model.feed.map(\.id), ["other"])
    }
    @MainActor
    func testDeletingPreviousCardDoesNotFenceNewCardLoad() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(), DiscoverTestDriver.card(id: "new")]
        let model = driver.model()
        await model.loadCard("card")
        let deletion = DiscoverTestGate<Void>()
        driver.deleteHook = { _ in try await deletion.wait() }
        model.requestDeletion("card")
        let deleting = Task { await model.confirmDeletion() }
        await deletion.entered()
        let card = DiscoverTestGate<EncounterDetail?>()
        driver.cardHook = { _ in try await card.wait() }
        let loading = Task { await model.loadCard("new") }
        await card.entered()
        deletion.resolve(.success(()))
        let deleted = await deleting.value
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.detailState, .loading)
        card.resolve(.success(DiscoverTestDriver.card(id: "new")))
        await loading.value
        XCTAssertEqual(model.detailState, .loaded)
        XCTAssertEqual(model.card?.card.id, "new")
    }

    @MainActor
    func testSignOutFencesLateWriteSuccessAndFailureWithoutRestoringOptimisticContent() async {
        for succeeds in [true, false] {
            let driver = DiscoverTestDriver()
            let model = driver.model()
            await model.loadFeed()
            await model.loadFavorites()
            await model.loadCard("card")
            let gate = DiscoverTestGate<EncounterFavoriteResult>()
            driver.favoriteHook = { _, _ in try await gate.wait() }
            let task = Task { await model.setFavorite("card", favorite: true) }
            await gate.entered()
            model.receiveAccess(discoveryOn: true, isAuthorized: false)
            if succeeds { gate.resolve(.success(.init(encounterID: "card", favorite: true))) }
            else { gate.resolve(.failure(DiscoverActionError.unavailable)) }
            await task.value
            XCTAssertNil(model.card)
            XCTAssertTrue(model.feed.isEmpty)
            XCTAssertTrue(model.favorites.isEmpty)
            XCTAssertFalse(model.isWriting)
            XCTAssertNil(model.failedOperation)
        }
    }

    @MainActor
    func testSavingOneLinkPreservesOtherLinkStateAndFavorite() async {
        let driver = DiscoverTestDriver()
        let second = EncounterLinkCard(id: "second", source: "Source", title: "Second",
                                       url: URL(string: "https://example.com/second")!)
        let card = EncounterCard(id: "card", kind: .qr, day: DiscoverTestDriver.day,
                                 links: [DiscoverTestDriver.link(), second])
        driver.cards = [.init(card: card, favorite: true, savedLinkIDs: ["second"])]
        let model = driver.model()
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        await model.loadCard("card")
        await model.setSaved("card", linkID: "link", saved: true)
        XCTAssertEqual(model.card?.savedLinkIDs, ["link", "second"])
        XCTAssertEqual(model.card?.favorite, true)
        XCTAssertEqual(model.card?.card, card)
        XCTAssertEqual(Set(model.savedLinks.map { $0.link.id }), ["link", "second"])
        await model.setFavorite("card", favorite: false)
        XCTAssertEqual(model.card?.savedLinkIDs, ["link", "second"])
        XCTAssertEqual(Set(model.savedLinks.map { $0.link.id }), ["link", "second"])
        await model.setSaved("card", linkID: "link", saved: false)
        XCTAssertEqual(model.card?.savedLinkIDs, ["second"])
        XCTAssertEqual(model.savedLinks.map { $0.link.id }, ["second"])
        XCTAssertEqual(model.card?.favorite, false)
    }

    @MainActor
    func testPositiveListFlagsCannotOverrideNegativeSingleCardOwnState() async {
        let driver = DiscoverTestDriver()
        driver.cards = [DiscoverTestDriver.card(favorite: true, saved: true)]
        driver.cardHook = { _ in DiscoverTestDriver.card() }
        let model = driver.model()
        await model.loadCard("card")
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadSavedLinks()
        XCTAssertEqual(model.card?.favorite, false)
        XCTAssertEqual(model.card?.savedLinkIDs, [])
        XCTAssertEqual(model.card.map { EncounterDetailControls(detail: $0).favoriteLabel }, .addFavorite)
        XCTAssertEqual(model.card.map { EncounterDetailControls(detail: $0).savedLabel(linkID: "link") }, .saveLink)
    }

    @MainActor
    func testFailedWriteRollsBackEvenWhenOrdinaryRefreshFailsWhileItIsInFlight() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadCard("card")
        let write = DiscoverTestGate<EncounterFavoriteResult>()
        let read = DiscoverTestGate<EncounterDetail?>()
        driver.favoriteHook = { _, _ in try await write.wait() }
        driver.cardHook = { _ in try await read.wait() }
        let writing = Task { await model.setFavorite("card", favorite: true) }
        await write.entered()
        let refreshing = Task { await model.loadCard("card") }
        await read.entered()
        read.resolve(.failure(DiscoverActionError.unavailable))
        await refreshing.value
        write.resolve(.failure(DiscoverActionError.unavailable))
        await writing.value
        XCTAssertEqual(model.card?.favorite, false)
        XCTAssertEqual(model.feed.first?.favorite, false)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(model.detailState, .failed)
        XCTAssertEqual(model.failedOperation, .favorite("card", true))
    }

    @MainActor
    func testNotFoundReadDuringWriteCannotBeRolledBackIntoProtectedContent() async {
        let driver = DiscoverTestDriver()
        let model = driver.model()
        await model.loadFeed()
        await model.loadFavorites()
        await model.loadCard("card")
        let gate = DiscoverTestGate<EncounterFavoriteResult>()
        driver.favoriteHook = { _, _ in try await gate.wait() }
        let writing = Task { await model.setFavorite("card", favorite: true) }
        await gate.entered()
        driver.cardHook = { _ in throw DiscoverActionError.notFound }
        await model.loadCard("card")
        gate.resolve(.failure(DiscoverActionError.unavailable))
        await writing.value
        XCTAssertNil(model.card)
        XCTAssertTrue(model.feed.isEmpty)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(model.detailState, .missing)
        XCTAssertNil(model.failedOperation)
        XCTAssertFalse(model.isWriting)
    }

    @MainActor
    func testWritesOnAnOpenCardBeyondListCapsKeepOwnStateAndDisplayedListsCapped() async {
        let driver = DiscoverTestDriver()
        let entries = (0..<200).map { DiscoverTestDriver.card(id: "entry-\($0)", favorite: true, saved: true) }
        driver.cards = entries
        let favorites = driver.feedResult.cards, saved = driver.savedResult.links
        driver.favoritesHook = { .init(cards: favorites, truncated: true) }
        driver.savedHook = { .init(links: saved, truncated: true) }
        driver.cards.append(DiscoverTestDriver.card(id: "beyond"))
        let model = driver.model()
        await model.loadFavorites()
        await model.loadSavedLinks()
        await model.loadCard("beyond")
        XCTAssertEqual(model.card?.favorite, false)
        XCTAssertEqual(model.card?.savedLinkIDs, [])
        await model.setFavorite("beyond", favorite: true)
        await model.setSaved("beyond", linkID: "link", saved: true)
        XCTAssertEqual(model.card?.favorite, true)
        XCTAssertEqual(model.card?.savedLinkIDs, ["link"])
        XCTAssertEqual(model.favorites.count, 200)
        XCTAssertEqual(model.savedLinks.count, 200)
        XCTAssertTrue(model.favoritesTruncated)
        XCTAssertTrue(model.savedLinksTruncated)
    }

}
