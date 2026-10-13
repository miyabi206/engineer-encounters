import EncounterDomain
import EncounterDomainTestSupport
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class EncounterConfirmationPollerTests: XCTestCase {
    func testShowingPhoneConfirmsOnlyANewQRAndLeavesConsumedCode() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        var cards = [pollCard("old", kind: .qr)]
        var reads = 0
        var opened: [String] = []
        let qr = pollQR { opened.append($0) }
        let poller = EncounterConfirmationPoller(clock: clock, scheduler: scheduler, load: {
            reads += 1; return cards
        }, confirm: { model, id in model.disappear(); model.receiveConfirmedEncounter(id) })
        poller.receive(authorized: true); poller.receive(foreground: true)
        await poller.openQR(qr); await qr.appear()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        XCTAssertEqual(reads, 1)
        let now = await clock.now()
        XCTAssertEqual(scheduler.jobs[0].date, now.wall.addingTimeInterval(5))
        cards = [pollCard("session", kind: .session)]
        try await firePoll(0, clock: clock, scheduler: scheduler)
        XCTAssertTrue(opened.isEmpty)
        try await appBackendEventually { scheduler.jobs.count == 2 }
        XCTAssertEqual(scheduler.jobs[1].date, now.wall.addingTimeInterval(10))
        cards.append(pollCard("old", kind: .qr))
        try await firePoll(1, clock: clock, scheduler: scheduler)
        XCTAssertTrue(opened.isEmpty)
        try await appBackendEventually { scheduler.jobs.count == 3 }
        cards.append(pollCard("new", kind: .qr))
        try await firePoll(2, clock: clock, scheduler: scheduler)
        XCTAssertEqual(opened, ["new"]); XCTAssertTrue(qr.hasConfirmed); XCTAssertNil(qr.code)
        let count = reads
        await scheduler.jobs[2].operation()
        XCTAssertEqual(reads, count)
        poller.closeQR(qr)
    }

    func testSessionPollsAndUploadEventsRefreshOnlyWhileVisibleAndForeground() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        var reads = 0
        let poller = EncounterConfirmationPoller(clock: clock, scheduler: scheduler,
            load: { reads += 1; return [] }, confirm: { _, _ in XCTFail("No QR is open") })
        poller.receive(authorized: true); poller.receive(foreground: true); poller.receive(sessionActive: true)
        poller.requestReload()
        XCTAssertEqual(reads, 0); XCTAssertTrue(scheduler.jobs.isEmpty)
        await poller.openSession()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        XCTAssertEqual(reads, 1)
        poller.requestReload()
        try await appBackendEventually { scheduler.jobs.count == 2 }
        XCTAssertEqual(reads, 1) // Receipt callbacks cannot bypass the five-second interval.
        XCTAssertTrue(scheduler.jobs[0].cancelled)
        try await firePoll(1, clock: clock, scheduler: scheduler)
        XCTAssertEqual(reads, 2)
        try await appBackendEventually { scheduler.jobs.count == 3 }
        poller.receive(foreground: false)
        XCTAssertTrue(scheduler.jobs[2].cancelled)
        await scheduler.jobs[2].operation(); poller.requestReload()
        XCTAssertEqual(reads, 2)
        poller.receive(foreground: true)
        try await appBackendEventually { scheduler.jobs.count == 4 }
        try await firePoll(3, clock: clock, scheduler: scheduler)
        XCTAssertEqual(reads, 3)
        try await appBackendEventually { scheduler.jobs.count == 5 }
        poller.closeSession()
        XCTAssertTrue(scheduler.jobs[4].cancelled)
        await scheduler.jobs[4].operation()
        XCTAssertEqual(reads, 3)
        await clock.advance(by: 5)
        await poller.openSession()
        try await appBackendEventually { scheduler.jobs.count == 6 }
        poller.receive(authorized: false)
        XCTAssertTrue(scheduler.jobs[5].cancelled)
        await scheduler.jobs[5].operation()
        XCTAssertEqual(reads, 4)
        poller.receive(authorized: true); poller.requestReload()
        XCTAssertEqual(reads, 4) // A later account cannot inherit screen visibility.
    }

    func testSessionPollsOnlyAfterActiveInThisVisitAndKeepsCheckingEndedSession() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        var reads = 0
        let poller = EncounterConfirmationPoller(clock: clock, scheduler: scheduler,
            load: { reads += 1; return [] }, confirm: { _, _ in })
        poller.receive(authorized: true); poller.receive(foreground: true)
        await poller.openSession()
        XCTAssertEqual(reads, 1); XCTAssertTrue(scheduler.jobs.isEmpty)
        poller.receive(sessionActive: true)
        try await appBackendEventually { scheduler.jobs.count == 1 }
        poller.receive(sessionActive: false)
        try await firePoll(0, clock: clock, scheduler: scheduler)
        XCTAssertEqual(reads, 2)
        try await appBackendEventually { scheduler.jobs.count == 2 }
        poller.closeSession()
        await clock.advance(by: 5)
        await poller.openSession()
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(scheduler.jobs[1].cancelled)
        XCTAssertEqual(scheduler.jobs.count, 2) // This visit has never had an active session.
        poller.closeSession()
    }

    func testCodeReplacementAndExpiryReloadAndScanningStopsPeriodicReads() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        var reads = 0
        var monotonic: TimeInterval = 0
        var issued = 0
        let qr = QRModel(actions: .init(issueCode: {
            issued += 1
            return QRCode(payload: QRPayload(token: String(repeating: issued == 1 ? "a" : "b", count: 32))!,
                expiresAt: Date(timeIntervalSince1970: 120))
        }, cancelCode: { _ in }, redeemCode: { _ in "new" }), navigation: pollNavigation { _ in }, monotonicNow: { monotonic })
        let poller = EncounterConfirmationPoller(clock: clock, scheduler: scheduler,
            load: { reads += 1; return [] }, confirm: { _, _ in XCTFail("No new QR") })
        poller.receive(authorized: true); poller.receive(foreground: true)
        await poller.openQR(qr)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        await qr.appear()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        await qr.refreshCode()
        try await appBackendEventually { scheduler.jobs.count == 2 }
        XCTAssertEqual(reads, 1)
        try await firePoll(1, clock: clock, scheduler: scheduler)
        XCTAssertEqual(reads, 2)
        try await appBackendEventually { scheduler.jobs.count == 3 }
        monotonic = 120
        await qr.tick()
        try await appBackendEventually { scheduler.jobs.count == 4 }
        try await firePoll(3, clock: clock, scheduler: scheduler)
        XCTAssertEqual(reads, 3)
        qr.select(.scan)
        let beforeScan = reads
        for job in scheduler.jobs { await job.operation() }
        XCTAssertEqual(reads, beforeScan)
        poller.closeQR(qr); qr.disappear()
    }

    func testCancelledScreenOpeningCannotStartPolling() async {
        let scheduler = ManualReceiptUploadScheduler()
        var reads = 0
        let poller = EncounterConfirmationPoller(clock: ManualEncounterClock(), scheduler: scheduler,
            load: { reads += 1; return [] }, confirm: { _, _ in })
        poller.receive(authorized: true); poller.receive(foreground: true)
        let opening = Task {
            await Task.yield()
            await poller.openSession()
            await poller.openQR(pollQR { _ in })
        }
        opening.cancel(); await opening.value
        XCTAssertEqual(reads, 0); XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testBackgroundAndDisappearFenceHeldConfirmation() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        var resume: CheckedContinuation<[EncounterFeedCard]?, Never>?
        var reads = 0
        var opened = false
        let qr = pollQR { _ in opened = true }
        let poller = EncounterConfirmationPoller(clock: clock, scheduler: scheduler, load: {
            reads += 1
            if reads == 1 { return [] }
            return await withCheckedContinuation { resume = $0 }
        }, confirm: { model, id in model.receiveConfirmedEncounter(id) })
        poller.receive(authorized: true); poller.receive(foreground: true)
        await poller.openQR(qr); await qr.appear()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        await clock.advance(by: 5)
        let loading = Task { await scheduler.jobs[0].operation() }
        try await appBackendEventually { resume != nil }
        poller.receive(foreground: false); poller.closeQR(qr)
        resume?.resume(returning: [pollCard("late", kind: .qr)])
        await loading.value
        XCTAssertFalse(opened); XCTAssertEqual(scheduler.jobs.count, 1)
        qr.disappear()
    }

    func testFailedBaselineNeverConfirmsCurrentCodeButReplacementCanUseLaterSuccessfulRead() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        var cards: [EncounterFeedCard]? = nil
        var opened: [String] = []
        let qr = pollQR { opened.append($0) }
        let poller = EncounterConfirmationPoller(clock: clock, scheduler: scheduler, load: { cards },
            confirm: { model, id in model.disappear(); model.receiveConfirmedEncounter(id) })
        poller.receive(authorized: true); poller.receive(foreground: true)
        await poller.openQR(qr); await qr.appear()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        cards = [pollCard("already-observed", kind: .qr)]
        try await firePoll(0, clock: clock, scheduler: scheduler)
        XCTAssertTrue(opened.isEmpty); XCTAssertNotNil(qr.code)
        await qr.refreshCode()
        try await appBackendEventually {
            scheduler.jobs.last?.cancelled == false &&
                scheduler.jobs.last?.date == EncounterSamples.observationTime.addingTimeInterval(10)
        }
        try await firePoll(scheduler.jobs.count - 1, clock: clock, scheduler: scheduler)
        XCTAssertTrue(opened.isEmpty)
        try await appBackendEventually { scheduler.jobs.last?.date == EncounterSamples.observationTime.addingTimeInterval(15) }
        cards = [pollCard("already-observed", kind: .qr), pollCard("new-after-replacement", kind: .qr)]
        try await firePoll(scheduler.jobs.count - 1, clock: clock, scheduler: scheduler)
        XCTAssertEqual(opened, ["new-after-replacement"])
        poller.closeQR(qr)
    }

    func testYesterdayQRAndIDsObservedWhileCodeAbsentCannotConfirm() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        var cards: [EncounterFeedCard] = []
        var opened: [String] = []
        let qr = pollQR { opened.append($0) }
        let poller = EncounterConfirmationPoller(clock: clock, scheduler: scheduler, load: { cards },
            confirm: { model, id in model.disappear(); model.receiveConfirmedEncounter(id) })
        poller.receive(authorized: true); poller.receive(foreground: true)
        await poller.openQR(qr)
        cards = [pollCard("before-code", kind: .qr)]
        poller.requestReload()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        try await firePoll(0, clock: clock, scheduler: scheduler) // Still no displayed code.
        XCTAssertTrue(opened.isEmpty)
        await qr.appear()
        try await appBackendEventually { scheduler.jobs.count == 2 }
        cards = [pollCard("before-code", kind: .qr), pollCard("yesterday", kind: .qr, day: pollDay(offset: -86400)),
                 pollCard("session", kind: .session)]
        try await firePoll(1, clock: clock, scheduler: scheduler)
        XCTAssertTrue(opened.isEmpty)
        try await appBackendEventually { scheduler.jobs.count == 3 }
        cards.append(pollCard("session", kind: .qr))
        cards.append(pollCard("today", kind: .qr))
        try await firePoll(2, clock: clock, scheduler: scheduler)
        XCTAssertEqual(opened, ["today"])
        poller.closeQR(qr)
    }

    func testFeedSucceedingDuringIssuanceCannotBecomeThatCodesBaseline() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        var cards: [EncounterFeedCard]? = nil
        var issue: CheckedContinuation<QRCode, Never>?
        var opened: [String] = []
        let qr = QRModel(actions: .init(issueCode: {
            await withCheckedContinuation { issue = $0 }
        }, cancelCode: { _ in }, redeemCode: { _ in "new" }), navigation: pollNavigation { opened.append($0) })
        let poller = EncounterConfirmationPoller(clock: clock, scheduler: scheduler, load: { cards },
            confirm: { model, id in model.receiveConfirmedEncounter(id) })
        poller.receive(authorized: true); poller.receive(foreground: true)
        await poller.openQR(qr)
        let issuing = Task { await qr.appear() }
        try await appBackendEventually { issue != nil }
        cards = []
        poller.requestReload()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        try await firePoll(0, clock: clock, scheduler: scheduler)
        issue?.resume(returning: QRCode(payload: QRPayload(token: String(repeating: "a", count: 32))!,
            expiresAt: EncounterSamples.observationTime.addingTimeInterval(120)))
        await issuing.value
        try await appBackendEventually { scheduler.jobs.count == 2 }
        cards = [pollCard("new", kind: .qr)]
        try await firePoll(1, clock: clock, scheduler: scheduler)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertNotNil(qr.code)
        poller.closeQR(qr); qr.disappear()
    }

    func testQRRegistersAgainAfterTabRoundTripAndRememberedIDsCannotRedeemReplacement() async throws {
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        var cards = [pollCard("old", kind: .qr)]
        var reads = 0
        var opened: [String] = []
        let qr = pollQR { opened.append($0) }
        let poller = EncounterConfirmationPoller(clock: clock, scheduler: scheduler, load: {
            reads += 1; return cards
        }, confirm: { model, id in model.disappear(); model.receiveConfirmedEncounter(id) })
        poller.receive(authorized: true); poller.receive(foreground: true)
        await poller.openQR(qr); await qr.appear()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        poller.closeQR(qr); qr.disappear()
        await clock.advance(by: 5)
        cards = [] // The old encounter has become ineligible.
        await poller.openQR(qr); await qr.appear()
        try await appBackendEventually { scheduler.jobs.count == 2 }
        XCTAssertEqual(reads, 2)
        cards = [pollCard("old", kind: .qr)]
        try await firePoll(1, clock: clock, scheduler: scheduler)
        XCTAssertTrue(opened.isEmpty)
        try await appBackendEventually { scheduler.jobs.count == 3 }
        cards.append(pollCard("new", kind: .qr))
        try await firePoll(2, clock: clock, scheduler: scheduler)
        XCTAssertEqual(opened, ["new"])
        poller.closeQR(qr)
    }
}

private func pollDay(offset: TimeInterval = 0) -> EncounterDay {
    let date = Calendar.current.dateComponents([.year, .month, .day], from: EncounterSamples.observationTime.addingTimeInterval(offset))
    return .init(year: date.year!, month: date.month!, day: date.day!)
}
private func pollCard(_ id: String, kind: EncounterUI.EncounterKind, day: EncounterDay = pollDay()) -> EncounterFeedCard {
    .init(card: .init(id: id, kind: kind, day: day), favorite: false)
}
@MainActor
private func firePoll(_ index: Int, clock: ManualEncounterClock, scheduler: ManualReceiptUploadScheduler) async throws {
    XCTAssertGreaterThan(scheduler.jobs.count, index)
    guard scheduler.jobs.count > index else { return }
    let job = scheduler.jobs[index]
    let time = await clock.now()
    await clock.advance(by: max(0, job.date.timeIntervalSince(time.wall)))
    await job.operation()
}
@MainActor
private func pollNavigation(_ open: @escaping @MainActor (String) -> Void) -> QRNavigationActions {
    .init(openEncounter: open, openIOSSettings: {}, close: {}, openDiscoveryOff: {})
}
@MainActor
private func pollQR(_ open: @escaping @MainActor (String) -> Void) -> QRModel {
    QRModel(actions: .init(issueCode: {
        QRCode(payload: QRPayload(token: String(repeating: "a", count: 32))!, expiresAt: Date(timeIntervalSince1970: 120))
    }, cancelCode: { _ in }, redeemCode: { _ in "new" }), navigation: pollNavigation(open))
}
