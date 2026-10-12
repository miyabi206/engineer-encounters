import XCTest
@testable import EncounterUI

final class DiscoverScreenTests: XCTestCase {
    func testS06SelectionDoesNotDeclareEmptyBeforeSuccessfulLoad() {
        for state in [DiscoverLoadState.idle, .loading] {
            for hasCards in [false, true] {
                XCTAssertEqual(DiscoverFeedContent.select(discoveryOn: true, isAuthorized: true,
                                                         state: state, hasCards: hasCards), .loading)
            }
        }
        for state in [DiscoverLoadState.failed, .missing] {
            XCTAssertEqual(DiscoverFeedContent.select(discoveryOn: true, isAuthorized: true,
                                                     state: state, hasCards: false), .failure)
        }
        XCTAssertEqual(DiscoverFeedContent.select(discoveryOn: true, isAuthorized: true,
                                                 state: .loaded, hasCards: false), .empty)
        XCTAssertEqual(DiscoverFeedContent.select(discoveryOn: true, isAuthorized: true,
                                                 state: .loaded, hasCards: true), .cards)
        for state in [DiscoverLoadState.idle, .loading, .loaded, .failed, .missing] {
            XCTAssertEqual(DiscoverFeedContent.select(discoveryOn: false, isAuthorized: true,
                                                     state: state, hasCards: true), .discoveryOff)
            XCTAssertEqual(DiscoverFeedContent.select(discoveryOn: true, isAuthorized: false,
                                                     state: state, hasCards: true), .failure)
        }
    }

    func testS23CheckingNeverSelectsUnavailable() {
        XCTAssertEqual(DiscoverBluetoothContent.select(.checking), .checking)
        XCTAssertEqual(DiscoverBluetoothContent.select(.available), .hidden)
        for status in [DiscoverBluetoothStatus.poweredOff, .denied, .unavailable, .failed] {
            XCTAssertEqual(DiscoverBluetoothContent.select(status), .unavailable(status))
        }
    }

    func testS24OwnPrerequisitesHaveLoadingFailureAndActionableGuidance() {
        let complete = ProfilePrerequisites(displayName: true, introduction: true, interest: true, link: true)
        for state in [DiscoverLoadState.idle, .loading] {
            XCTAssertEqual(DiscoverPrerequisiteContent.select(state: state, prerequisites: complete), .loading)
        }
        for state in [DiscoverLoadState.failed, .missing] {
            XCTAssertEqual(DiscoverPrerequisiteContent.select(state: state, prerequisites: complete), .failure)
        }
        XCTAssertEqual(DiscoverPrerequisiteContent.select(state: .loaded, prerequisites: complete),
                       .guidance(editProfile: false, editLinks: false))
        XCTAssertEqual(DiscoverPrerequisiteContent.select(state: .loaded, prerequisites: .init()),
                       .guidance(editProfile: true, editLinks: true))
        for missing in [ProfilePrerequisites(displayName: false, introduction: true, interest: true, link: true),
                        ProfilePrerequisites(displayName: true, introduction: false, interest: true, link: true),
                        ProfilePrerequisites(displayName: true, introduction: true, interest: false, link: true)] {
            XCTAssertEqual(DiscoverPrerequisiteContent.select(state: .loaded, prerequisites: missing),
                           .guidance(editProfile: true, editLinks: false))
        }
        XCTAssertEqual(DiscoverPrerequisiteContent.select(state: .loaded,
                       prerequisites: .init(displayName: true, introduction: true, interest: true, link: false)),
                       .guidance(editProfile: false, editLinks: true))
    }

    @MainActor
    func testActiveSessionOpensS08ForEveryRadioStateAndInactiveSessionCanRecover() {
        let spy = DiscoverNavigationSpy()
        let navigation = spy.actions()
        for status in [DiscoverBluetoothStatus.available, .poweredOff, .denied, .unavailable, .checking, .failed] {
            let active = DiscoverSessionDestination.select(sessionActive: true, bluetooth: status)
            XCTAssertEqual(active, .session)
            active.open(using: navigation)
            let inactive = DiscoverSessionDestination.select(sessionActive: false, bluetooth: status)
            XCTAssertEqual(inactive, status == .available ? .session : .bluetoothRecovery)
            inactive.open(using: navigation)
        }
        XCTAssertEqual(spy.sessions, 7)
        XCTAssertEqual(spy.bluetoothRecoveries, 5)
    }

    @MainActor
    func testS06HasOnlyFavoritesShortcutAndItOpensS10() {
        let spy = DiscoverNavigationSpy()
        XCTAssertEqual(DiscoverFeedShortcut.allCases, [.favorites])
        XCTAssertEqual(DiscoverFeedShortcut.favorites.label, .favorites)
        DiscoverFeedShortcut.favorites.open(using: spy.actions())
        XCTAssertEqual(spy.favorites, 1)
    }

    func testS07OwnStateControlsNeverOfferAddOrSaveForExistingRetention() {
        let base = DiscoverTestDriver.card().card
        let existing = EncounterDetailControls(detail: .init(card: base, favorite: true, savedLinkIDs: ["link", "hidden"]))
        XCTAssertEqual(existing.favoriteLabel, .removeFavorite)
        XCTAssertEqual(existing.savedLabel(linkID: "link"), .unsaveLink)
        XCTAssertEqual(existing.savedLinkIDs, ["link"])
        let absent = EncounterDetailControls(detail: .init(card: base, favorite: false, savedLinkIDs: []))
        XCTAssertEqual(absent.favoriteLabel, .addFavorite)
        XCTAssertEqual(absent.savedLabel(linkID: "link"), .saveLink)
    }

    @MainActor
    func testPerLinkImpersonationPassesAuthorizedCardAndCorrectLinkID() {
        let spy = DiscoverNavigationSpy()
        let second = EncounterLinkCard(id: "second", source: "Source", title: "Second work",
                                       url: URL(string: "https://example.com/second")!)
        let card = EncounterCard(id: "card", kind: .qr, day: DiscoverTestDriver.day,
                                 displayName: "Name", links: [DiscoverTestDriver.link(), second])
        for link in card.links {
            EncounterDetailControls.report(card: card, linkID: link.id, navigation: spy.actions())
        }
        XCTAssertEqual(spy.reportedCards, [card, card])
        XCTAssertEqual(spy.reportedLinks, ["link", "second"])
        EncounterDetailControls.report(card: card, linkID: "hidden", navigation: spy.actions())
        XCTAssertEqual(spy.reportedLinks, ["link", "second"])
    }

    @MainActor
    func testDeferredControlsHideIndividuallyWhenAbsentAndShowWhenSupplied() {
        let driver = DiscoverTestDriver()
        var actions = driver.model().actions
        var navigation = DiscoverNavigationSpy().actions()
        XCTAssertEqual(EncounterDetailControls.availableDeferredControls(actions: actions, navigation: navigation),
                       [.safety, .impersonation, .deletion])
        navigation.openReportOrBlock = nil
        XCTAssertEqual(EncounterDetailControls.availableDeferredControls(actions: actions, navigation: navigation),
                       [.impersonation, .deletion])
        navigation.reportImpersonation = nil
        XCTAssertEqual(EncounterDetailControls.availableDeferredControls(actions: actions, navigation: navigation), [.deletion])
        actions.deleteEncounter = nil
        XCTAssertTrue(EncounterDetailControls.availableDeferredControls(actions: actions, navigation: navigation).isEmpty)
        // A missing report action remains safe even for callers of the public helper.
        EncounterDetailControls.report(card: DiscoverTestDriver.card().card, linkID: "link", navigation: navigation)
    }

    @MainActor
    func testAbsentDeletionCannotEnterConfirmationOrMutateAnEncounter() async {
        let driver = DiscoverTestDriver()
        var actions = driver.model().actions
        actions.deleteEncounter = nil
        let model = DiscoverModel(actions: actions, discoveryOn: true)
        await model.loadFeed()
        model.requestDeletion("card")
        XCTAssertEqual(model.deletion, .none)
        let deleted = await model.confirmDeletion()
        XCTAssertFalse(deleted)
        XCTAssertTrue(driver.writes.isEmpty)
        XCTAssertEqual(model.feed.count, 1)
    }

    func testFeedSharedInterestIDsDistinguishOmissionFromEmptyIntersection() {
        let card = DiscoverTestDriver.card().card
        XCTAssertNil(EncounterFeedCard(card: card, favorite: false).sharedInterestIDs)
        XCTAssertEqual(EncounterFeedCard(card: card, favorite: false, sharedInterestIDs: []).sharedInterestIDs, [])
    }
}

@MainActor
final class DiscoverNavigationSpy {
    var sessions = 0
    var bluetoothRecoveries = 0
    var favorites = 0
    var reportedCards: [EncounterCard] = []
    var reportedLinks: [String] = []

    func actions() -> DiscoverNavigationActions {
        .init(openEncounter: { _ in }, openFavorites: { self.favorites += 1 },
              openSession: { self.sessions += 1 }, openQR: {}, openDiscoverySettings: {},
              openProfileEditing: {}, openReportOrBlock: { _ in },
              reportImpersonation: { card, linkID in
                  self.reportedCards.append(card); self.reportedLinks.append(linkID)
              }, openSample: {}, openOwnLinks: {}, openSystemSettings: {},
              openBluetoothRecovery: { self.bluetoothRecoveries += 1 }, back: {}, encounterRemoved: {})
    }
}
