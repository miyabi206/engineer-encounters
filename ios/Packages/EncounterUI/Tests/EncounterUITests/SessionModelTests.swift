import XCTest
@testable import EncounterUI

final class SessionModelTests: XCTestCase {
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
        driver.now = driver.now.addingTimeInterval(7200)
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
        XCTAssertEqual(driver.refreshes, 0)
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
        driver.now = driver.end
        await model.refresh()
        XCTAssertTrue(model.lifecycle.hasEnded)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(driver.refreshes, 2)
    }

    @MainActor
    func testRefreshLoadsServerSessionAndRestoredStopRetries() async {
        let driver = SessionTestDriver()
        let model = driver.model()
        await model.refresh()
        XCTAssertTrue(model.isActive)
        let pending = SessionModel(state: .stopping, actions: driver.actions, now: { driver.now })
        XCTAssertFalse(pending.isActive)
        await pending.refresh()
        XCTAssertEqual(driver.stops, 1)
        XCTAssertFalse(pending.lifecycle.stopPending)
    }
}

@MainActor
private final class SessionTestDriver {
    var now = Date(timeIntervalSince1970: 10_000)
    var end: Date { now.addingTimeInterval(7200) }
    var failure: SessionActionError?
    var starts = 0
    var stops = 0
    var refreshes = 0
    var duringStart: (@MainActor () async -> Void)?
    var duringRefresh: (@MainActor () -> Void)?

    var actions: SessionActions {
        SessionActions(startSession: {
            self.starts += 1
            await self.duringStart?()
            if let failure = self.failure { throw failure }
            return self.end
        }, stopSession: {
            self.stops += 1
            if let failure = self.failure { throw failure }
        }, refreshSession: {
            self.refreshes += 1
            self.duringRefresh?()
            if let failure = self.failure { throw failure }
            return .active(endsAt: self.end)
        })
    }

    func model(active: Bool = false) -> SessionModel {
        SessionModel(state: active ? .active(endsAt: end) : .none, actions: actions, now: { self.now })
    }
}
