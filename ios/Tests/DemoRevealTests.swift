#if DEVELOPMENT_BUILD || INTERNAL_BUILD
import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class DemoRevealTests: XCTestCase {
    func testOffDoesNotCallRevealAndOnOrdersRevealBeforeEachFeedRead() async throws {
        let transport = productTransport(["get_encounter_feed": [.response(productFeed()), .response(productFeed()), .response(productFeed())],
            "reveal_ambient_now": [.response(demoFeed()), .response(demoFeed())]])
        let center = TestLocalNotificationCenter(); center.authorization = .denied
        let composition = settingsComposition(transport, defaults: appBackendDefaults(),
            store: InMemorySessionStore(session: try appBackendTestSession()), center: center)
        await composition.waitForRestoration(); productAuthorize(composition)
        let actions = composition.discoverAdapter.actions()
        _ = try await actions.loadFeed()
        let before = await transport.count("reveal_ambient_now"); XCTAssertEqual(before, 0)
        composition.demoSwitch.isEnabled = true
        _ = try await actions.loadFeed(); _ = try await actions.loadFeed()
        let relevant = await transport.recorded().compactMap { $0.url?.lastPathComponent }.filter {
            ["reveal_ambient_now", "get_encounter_feed"].contains($0)
        }
        XCTAssertEqual(relevant, ["get_encounter_feed", "reveal_ambient_now", "get_encounter_feed", "reveal_ambient_now", "get_encounter_feed"])
        XCTAssertTrue(center.bodies.isEmpty)
    }

    func testPermissionIsAskedOnlyOnceAndRefusalDoesNotDisableReveal() async throws {
        let center = TestLocalNotificationCenter()
        let composition = settingsComposition(productTransport([:]), defaults: appBackendDefaults(),
            store: InMemorySessionStore(session: try appBackendTestSession()), center: center)
        await composition.waitForRestoration()
        composition.demoSwitch.isEnabled = true
        await composition.demoReveal.switchedOn(); await composition.demoReveal.switchedOn()
        composition.demoSwitch.isEnabled = false; composition.demoSwitch.isEnabled = true
        await composition.demoReveal.switchedOn()
        XCTAssertEqual(center.requests, 1); XCTAssertTrue(composition.demoSwitch.isEnabled)
        let allowed = TestLocalNotificationCenter(); allowed.authorization = .allowed
        let other = settingsComposition(productTransport([:]), defaults: appBackendDefaults(),
            store: InMemorySessionStore(session: try appBackendTestSession()), center: allowed)
        await other.waitForRestoration(); other.demoSwitch.isEnabled = true
        await other.demoReveal.switchedOn(); XCTAssertEqual(allowed.requests, 0)
    }

    func testNewOnlyNotificationsReauthorizeAndUseOnlyAuthorizedNames() async throws {
        var shell = productCard(detail: true)
        shell.removeValue(forKey: "display_name"); shell.removeValue(forKey: "introduction")
        let transport = productTransport(["reveal_ambient_now": [.response(demoFeed(cards: [productCard()])), .response(demoFeed()),
            .response(demoFeed(cards: [productCard()])), .response(demoFeed(cards: [productCard()]))],
            "get_encounter_card": [.response(productResponse(productCard(detail: true))),
                .response(productResponse(shell)), .response(productError("not_found"))]])
        let center = TestLocalNotificationCenter(); center.authorization = .allowed
        let composition = settingsComposition(transport, defaults: appBackendDefaults(),
            store: InMemorySessionStore(session: try appBackendTestSession()), center: center)
        await composition.waitForRestoration(); productAuthorize(composition); composition.demoSwitch.isEnabled = true
        try await composition.demoReveal.reveal()
        XCTAssertEqual(center.bodies, [DemoRevealController.notificationBody(displayName: "Person")])
        try await composition.demoReveal.reveal(); XCTAssertEqual(center.bodies.count, 1)
        try await composition.demoReveal.reveal()
        XCTAssertEqual(center.bodies.last, DemoRevealController.notificationBody(displayName: nil))
        try await composition.demoReveal.reveal(); XCTAssertEqual(center.bodies.count, 2)
        XCTAssertFalse(center.bodies.joined().contains(productEncounterID))
        XCTAssertFalse(center.bodies.joined().contains("Contact")); XCTAssertFalse(center.bodies.joined().contains("Work"))
    }

    func testTruncatedRevealProducesOneNeutralNotificationAndNoInventedCount() async throws {
        let transport = productTransport(["reveal_ambient_now": [.response(demoFeed(cards: [productCard()], truncated: true))]])
        let center = TestLocalNotificationCenter(); center.authorization = .allowed
        let composition = settingsComposition(transport, defaults: appBackendDefaults(),
            store: InMemorySessionStore(session: try appBackendTestSession()), center: center)
        await composition.waitForRestoration(); productAuthorize(composition); composition.demoSwitch.isEnabled = true
        try await composition.demoReveal.reveal()
        XCTAssertEqual(center.bodies, [DemoRevealController.notificationBody(displayName: nil)])
        let reads = await transport.count("get_encounter_card"); XCTAssertEqual(reads, 0)
    }

    func testNotFoundDisablesDemoForThisBackendWhileFeedRemainsAvailable() async throws {
        let transport = productTransport(["reveal_ambient_now": [.response(productError("not_found"))],
            "get_encounter_feed": [.response(productFeed()), .response(productFeed())]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition); composition.demoSwitch.isEnabled = true
        let actions = composition.discoverAdapter.actions()
        _ = try await actions.loadFeed(); _ = try await actions.loadFeed()
        XCTAssertTrue(composition.demoReveal.unavailable)
        let count = await transport.count("reveal_ambient_now"); XCTAssertEqual(count, 1)
        XCTAssertTrue(composition.account.state.isSignedIn)
    }

    func testReceiptUploadResolvesBeforeDemoAndFeedRead() async throws {
        let queue = InMemoryReceiptQueue()
        let receipt = appBackendFinalReceipt()
        try await queue.enqueue(receipt)
        let resolved = HTTPResponse(data: try JSONEncoder().encode([ReceiptStatusTransfer(id: receipt.id, status: .resolved)]), statusCode: 200)
        let transport = productTransport(["submit_receipts": [.held], "reveal_ambient_now": [.response(demoFeed()), .response(demoFeed())],
            "get_encounter_feed": [.response(productFeed())]])
        let center = TestLocalNotificationCenter(); center.authorization = .denied
        let composition = settingsComposition(transport, defaults: appBackendDefaults(), queue: queue,
            store: InMemorySessionStore(session: try appBackendTestSession()), center: center)
        await composition.waitForRestoration(); productAuthorize(composition)
        try await appBackendEventually { await transport.isHeld("submit_receipts") }
        composition.demoSwitch.isEnabled = true
        let feed = Task { try await composition.discoverAdapter.actions().loadFeed() }
        // The refresh cannot get ahead of the already-running receipt resolution.
        await Task.yield()
        let early = await transport.count("reveal_ambient_now"); XCTAssertEqual(early, 0)
        await transport.release("submit_receipts", with: resolved)
        _ = try await feed.value
        let paths = await transport.recorded().compactMap { $0.url?.lastPathComponent }.filter {
            ["submit_receipts", "reveal_ambient_now", "get_encounter_feed"].contains($0)
        }
        XCTAssertEqual(paths, ["submit_receipts", "reveal_ambient_now", "reveal_ambient_now", "get_encounter_feed"])
    }

    func testLateNotificationCompletionIsRemovedAfterSignOut() async throws {
        let transport = productTransport(["reveal_ambient_now": [.response(demoFeed(cards: [productCard()]))],
            "get_encounter_card": [.response(productResponse(productCard(detail: true)))]])
        let center = TestLocalNotificationCenter(); center.authorization = .allowed; center.holdsPosts = true
        let composition = settingsComposition(transport, defaults: appBackendDefaults(),
            store: InMemorySessionStore(session: try appBackendTestSession()), center: center)
        await composition.waitForRestoration(); productAuthorize(composition); composition.demoSwitch.isEnabled = true
        let reveal = Task { try? await composition.demoReveal.reveal() }
        try await appBackendEventually { center.hasHeldPost }
        try await composition.account.signOut()
        center.releasePost(); await reveal.value
        XCTAssertTrue(center.bodies.isEmpty)
    }

    func testSignOutAndSwitchOffFenceHeldDemoResponsesAndClearNotifications() async throws {
        for signOut in [false, true] {
            let transport = productTransport(["reveal_ambient_now": [.held]])
            let center = TestLocalNotificationCenter(); center.authorization = .allowed
            let composition = settingsComposition(transport, defaults: appBackendDefaults(),
                store: InMemorySessionStore(session: try appBackendTestSession()), center: center)
            await composition.waitForRestoration(); productAuthorize(composition); composition.demoSwitch.isEnabled = true
            let reveal = Task { try? await composition.demoReveal.reveal() }
            try await appBackendEventually { await transport.isHeld("reveal_ambient_now") }
            if signOut { try await composition.account.signOut() }
            else { composition.demoSwitch.isEnabled = false }
            await transport.release("reveal_ambient_now", with: demoFeed(cards: [productCard()]))
            await reveal.value
            XCTAssertTrue(center.bodies.isEmpty)
            let reads = await transport.count("get_encounter_card"); XCTAssertEqual(reads, 0)
            if signOut { XCTAssertEqual(center.clears, 1) }
        }
    }
}

func demoFeed(cards: [[String: Any]] = [], truncated: Bool = false) -> HTTPResponse {
    productResponse(["cards": cards, "truncated": truncated])
}
#endif
