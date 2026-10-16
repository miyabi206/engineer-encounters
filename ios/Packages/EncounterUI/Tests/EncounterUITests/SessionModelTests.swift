import Combine
import XCTest
@testable import EncounterUI

final class SessionModelTests: XCTestCase {
    @MainActor
    func testTickDoesNotPublishWhileNoneOrStarting() async {
        let driver = SessionTestDriver()
        let model = driver.model()
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        model.tick()
        driver.elapsed = 0.5
        model.tick()
        XCTAssertEqual(changes, 0)
        driver.duringStart = {
            XCTAssertEqual(model.state, .starting)
            let before = changes
            model.tick()
            driver.elapsed += 0.25
            model.tick()
            XCTAssertEqual(changes, before)
        }
        await model.start()
        XCTAssertTrue(model.isActive)
    }

    @MainActor
    func testTickPublishesOnlyForCountdownChangesAndExpiry() {
        let driver = SessionTestDriver()
        let model = driver.model(active: true)
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        model.tick()
        driver.elapsed = 0.5
        model.tick()
        XCTAssertEqual(changes, 0)
        driver.elapsed = 1
        model.tick()
        XCTAssertEqual(model.remainingSeconds, 7199)
        XCTAssertEqual(changes, 1)
        driver.elapsed = 1.5
        model.tick()
        XCTAssertEqual(changes, 1)
        driver.elapsed = 7200
        model.tick()
        XCTAssertEqual(model.remainingSeconds, 0)
        XCTAssertTrue(model.lifecycle.hasEnded)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(changes, 3)
        model.tick()
        XCTAssertEqual(changes, 3)
    }

    @MainActor
    func testStartWaitsForServerAcknowledgementAndDuplicateStartIsIgnored() async {
        let driver = SessionTestDriver()
        let model = driver.model()
        driver.duringStart = {
            XCTAssertEqual(model.state, .starting)
            XCTAssertFalse(model.isActive)
            await model.start()
        }
        await model.start()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.remainingSeconds, 7200)
        await model.start()
        XCTAssertEqual(driver.starts, 1)
        driver.elapsed += 7200
        model.tick()
        XCTAssertEqual(model.remainingSeconds, 0)
        XCTAssertTrue(model.lifecycle.hasEnded)
        XCTAssertFalse(model.isActive)
    }

    @MainActor
    func testOfflineAndGenericStartErrorsRetry() async {
        let driver = SessionTestDriver()
        let model = driver.model()
        driver.failure = .offline
        await model.start()
        XCTAssertEqual(model.state, .startRefusedOffline)
        XCTAssertFalse(model.isActive)
        driver.failure = .unavailable
        await model.retry()
        XCTAssertEqual(model.state, .failed)
        driver.failure = nil
        await model.retry()
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(driver.starts, 3)
    }

    @MainActor
    func testStopIsSynchronousAndFailureNeverRestoresActivity() async {
        let driver = SessionTestDriver()
        let model = driver.model(active: true)
        XCTAssertTrue(model.stopLocally())
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.remainingSeconds, 0)
        driver.failure = .offline
        await model.synchronizeStop()
        XCTAssertTrue(model.lifecycle.stopFailed)
        XCTAssertTrue(model.lifecycle.stopPending)
        XCTAssertFalse(model.isActive)
        await model.start()
        XCTAssertEqual(driver.starts, 0)
        driver.failure = nil
        await model.retry()
        XCTAssertFalse(model.lifecycle.stopPending)
        XCTAssertFalse(model.isActive)
        await model.refresh()
        XCTAssertEqual(driver.refreshes, 1)
        XCTAssertTrue(model.isActive)
        await model.start()
        XCTAssertTrue(model.isActive)
    }

    @MainActor
    func testRefreshThatCompletesAfterLocalStopCannotReactivate() async {
        let driver = SessionTestDriver()
        let model = driver.model(active: true)
        driver.duringRefresh = { XCTAssertTrue(model.stopLocally()) }
        await model.refresh()
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.lifecycle.stopPending)
        XCTAssertTrue(model.lifecycle.hasEnded)
    }

    @MainActor
    func testRefreshFailureKeepsAnExistingSessionAndRetriesWithInjectedClock() async {
        let driver = SessionTestDriver()
        let model = driver.model(active: true)
        driver.failure = .offline
        await model.refresh()
        XCTAssertTrue(model.refreshFailed)
        XCTAssertTrue(model.isActive)
        driver.failure = nil
        await model.retry()
        XCTAssertFalse(model.refreshFailed)
        XCTAssertEqual(driver.refreshes, 2)
        driver.elapsed = 7200
        await model.refresh()
        XCTAssertTrue(model.lifecycle.hasEnded)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(driver.refreshes, 3)
    }

    @MainActor
    func testCountdownUsesServerTimeAndMonotonicElapsedWithDeviceTenMinutesFast() async {
        let driver = SessionTestDriver(); let model = driver.model()
        XCTAssertEqual(driver.deviceTime.timeIntervalSince(driver.serverTime), 600)
        await model.start()
        XCTAssertEqual(model.remainingSeconds, 7200)
        driver.deviceTime = driver.deviceTime.addingTimeInterval(86_400)
        driver.elapsed = 119.25; model.tick()
        XCTAssertEqual(model.remainingSeconds, 7081)
        driver.deviceTime = driver.deviceTime.addingTimeInterval(-172_800)
        driver.elapsed = 7200; model.tick()
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.remainingSeconds, 0)
    }

    @MainActor
    func testFreshActiveAcknowledgementReplacesEndedStateOnceNoStopIsPending() async {
        let driver = SessionTestDriver(); let model = driver.model(active: true)
        driver.elapsed = 7200; model.tick()
        XCTAssertTrue(model.lifecycle.hasEnded)
        driver.freshSession = SessionAcknowledgement(sessionID: "fresh", startsAt: driver.end,
            expiresAt: driver.end.addingTimeInterval(7200), serverTime: driver.end)
        await model.refresh()
        XCTAssertTrue(model.isActive)
        XCTAssertFalse(model.lifecycle.hasEnded)
        XCTAssertEqual(model.remainingSeconds, 7200)
        XCTAssertTrue(model.stopLocally())
        driver.failure = .offline
        await model.refresh()
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(driver.refreshes, 1)
        driver.failure = nil
        await model.refresh() // Uploads the pending stop before another get is permitted.
        XCTAssertFalse(model.isActive)
        await model.refresh()
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(driver.refreshes, 2)
    }

    @MainActor
    func testDiscoveryPrerequisiteNavigatesForStartAndRefresh() async {
        let driver = SessionTestDriver(); let model = driver.model()
        driver.failure = .prerequisiteMissing(details: ["discovery"])
        await model.start()
        XCTAssertEqual(driver.discoveryRoutes, 1)
        XCTAssertFalse(model.isActive)
        await model.refresh()
        XCTAssertEqual(driver.discoveryRoutes, 2)
        driver.failure = .prerequisiteMissing(details: ["profile"])
        await model.start()
        XCTAssertEqual(driver.discoveryRoutes, 2)
    }

    @MainActor
    func testRefreshLoadsServerSessionAndRestoredStopRetries() async {
        let driver = SessionTestDriver()
        let model = driver.model()
        await model.refresh()
        XCTAssertTrue(model.isActive)
        let pending = SessionModel(state: .stopping, actions: driver.actions, navigation: driver.navigation, monotonicNow: { driver.elapsed })
        XCTAssertFalse(pending.isActive)
        await pending.refresh()
        XCTAssertEqual(driver.stops, 1)
        XCTAssertFalse(pending.lifecycle.stopPending)
    }
}

@MainActor
private final class SessionTestDriver {
    let serverTime = Date(timeIntervalSince1970: 10_000)
    var elapsed: TimeInterval = 0
    var deviceTime = Date(timeIntervalSince1970: 10_600)
    var end: Date { serverTime.addingTimeInterval(7200) }
    var acknowledgement: SessionAcknowledgement {
        SessionAcknowledgement(sessionID: "session", startsAt: serverTime, expiresAt: end,
                               serverTime: serverTime.addingTimeInterval(elapsed))
    }
    var failure: SessionActionError?
    var starts = 0
    var stops = 0
    var refreshes = 0
    var discoveryRoutes = 0
    var freshSession: SessionAcknowledgement?
    var duringStart: (@MainActor () async -> Void)?
    var duringRefresh: (@MainActor () -> Void)?

    var actions: SessionActions {
        SessionActions(startSession: {
            self.starts += 1
            await self.duringStart?()
            if let failure = self.failure { throw failure }
            return self.freshSession ?? self.acknowledgement
        }, stopSession: {
            self.stops += 1
            if let failure = self.failure { throw failure }
        }, refreshSession: {
            self.refreshes += 1
            self.duringRefresh?()
            if let failure = self.failure { throw failure }
            if let freshSession = self.freshSession { return .active(freshSession) }
            return self.elapsed < 7200 ? .active(self.acknowledgement) : .none
        })
    }

    var navigation: SessionNavigationActions {
        SessionNavigationActions(openQR: {}, openEncounter: { _ in }, close: {},
                                 openDiscoveryOff: { self.discoveryRoutes += 1 })
    }

    func model(active: Bool = false) -> SessionModel {
        SessionModel(state: active ? .active(acknowledgement) : .none, actions: actions, navigation: navigation,
                     monotonicNow: { self.elapsed })
    }
}
