import XCTest
@testable import EncounterUI

final class SessionLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testCountdownRoundsUpAndClampsAtExpiry() {
        XCTAssertEqual(SessionCountdown.seconds(until: now.addingTimeInterval(7200), now: now), 7200)
        XCTAssertEqual(SessionCountdown.seconds(until: now.addingTimeInterval(0.01), now: now), 1)
        XCTAssertEqual(SessionCountdown.seconds(until: now, now: now), 0)
        XCTAssertEqual(SessionCountdown.seconds(until: now.addingTimeInterval(-1), now: now), 0)
        XCTAssertEqual(SessionCountdown.text(seconds: 7140), "1:59:00")
        XCTAssertEqual(SessionCountdown.text(seconds: -1), "0:00:00")
        XCTAssertEqual(SessionCountdown.text(seconds: 59), "0:00:59")
    }

    func testOnlyAcknowledgementActivatesAndDoesNotExtendAnActiveSession() {
        var state = SessionLifecycle(now: now)
        XCTAssertTrue(state.beginStart())
        XCTAssertEqual(state.state, .starting)
        XCTAssertFalse(state.isActive)
        state.receive(.active(endsAt: now.addingTimeInterval(1)), now: now)
        XCTAssertEqual(state.state, .starting)
        let end = now.addingTimeInterval(7200)
        state.acknowledgeStart(endsAt: end, now: now)
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.beginStart())
        XCTAssertEqual(state.state, .active(endsAt: end))
    }

    func testOfflineAndFailureRequireExplicitRetry() {
        var state = SessionLifecycle(now: now)
        state.beginStart(); state.failStart(offline: true)
        XCTAssertEqual(state.state, .startRefusedOffline)
        XCTAssertFalse(state.isActive)
        state.beginStart(); state.failStart(offline: false)
        XCTAssertEqual(state.state, .failed)
        XCTAssertTrue(state.beginStart())
        state.acknowledgeStart(endsAt: now, now: now)
        XCTAssertTrue(state.hasEnded)
        XCTAssertFalse(state.isActive)
    }

    func testLocalStopStaysEndedOnUploadFailureOrStaleRefresh() {
        var state = SessionLifecycle(state: .active(endsAt: now.addingTimeInterval(7200)), now: now)
        XCTAssertTrue(state.stopLocally())
        XCTAssertEqual(state.state, .stopping)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.hasEnded)
        XCTAssertFalse(state.beginStart())
        state.finishStop(succeeded: false)
        XCTAssertEqual(state.state, .none)
        XCTAssertTrue(state.stopPending)
        XCTAssertTrue(state.stopFailed)
        state.receive(.active(endsAt: now.addingTimeInterval(7200)), now: now)
        XCTAssertFalse(state.isActive)
        state.finishStop(succeeded: true)
        XCTAssertFalse(state.stopPending)
        state.receive(.active(endsAt: now.addingTimeInterval(7200)), now: now)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.beginStart())
    }

    func testExpiryAtTheExactBoundaryLatchesEnded() {
        var state = SessionLifecycle(state: .active(endsAt: now.addingTimeInterval(1)), now: now)
        state.expire(now: now)
        XCTAssertTrue(state.isActive)
        state.expire(now: now.addingTimeInterval(1))
        XCTAssertTrue(state.hasEnded)
        XCTAssertFalse(state.stopPending)
        state.receive(.active(endsAt: now.addingTimeInterval(7200)), now: now)
        XCTAssertFalse(state.isActive)
        let restored = SessionLifecycle(state: .active(endsAt: now), now: now)
        XCTAssertTrue(restored.hasEnded)
        let stopping = SessionLifecycle(state: .stopping, now: now)
        XCTAssertFalse(stopping.isActive)
        XCTAssertTrue(stopping.stopPending)
    }
}
