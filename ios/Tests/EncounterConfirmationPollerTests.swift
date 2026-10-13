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
        await poller.openQR(qr)
        await qr.appear()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        XCTAssertEqual(reads, 1)
        let now = await clock.now()
        XCTAssertEqual(scheduler.jobs[0].date, now.wall.addingTimeInterval(5))
        cards = [pollCard("session", kind: .session)]
        await clock.advance(by: 5)
        await scheduler.jobs[0].operation()
        XCTAssertTrue(opened.isEmpty)
        try await appBackendEventually { scheduler.jobs.count == 2 }
        XCTAssertEqual(scheduler.jobs[1].date, now.wall.addingTimeInterval(10))
        cards.append(pollCard("old", kind: .qr)) // Temporarily ineligible content returning is not a redemption.
        await clock.advance(by: 5)
        await scheduler.jobs[1].operation()
        XCTAssertTrue(opened.isEmpty)
        try await appBackendEventually { scheduler.jobs.count == 3 }
        cards.append(pollCard("new", kind: .qr))
        await clock.advance(by: 5)
        await scheduler.jobs[2].operation()
        XCTAssertEqual(opened, ["new"])
        XCTAssertTrue(qr.hasConfirmed)
        XCTAssertNil(qr.code)
        let count = reads
        await scheduler.jobs[2].operation() // A duplicate/cancelled callback cannot read again.
        XCTAssertEqual(reads, count)
        poller.closeQR(qr)
    }

    func testSessionPollsAndUploadEventsRefreshOnlyWhileVisibleAndForeground() async throws {
        let scheduler = ManualReceiptUploadScheduler()
        var reads = 0
        let poller = EncounterConfirmationPoller(clock: ManualEncounterClock(), scheduler: scheduler,
            load: { reads += 1; return [] }, confirm: { _, _ in XCTFail("No QR is open") })
        poller.receive(authorized: true); poller.receive(foreground: true)
        poller.requestReload()
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        await poller.openSession()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        XCTAssertEqual(reads, 1)
        poller.requestReload() // The receipt-resolution callback uses this entry point.
        try await appBackendEventually { reads == 2 && scheduler.jobs.count == 2 }
        XCTAssertTrue(scheduler.jobs[0].cancelled)
        poller.receive(foreground: false)
        XCTAssertTrue(scheduler.jobs[1].cancelled)
        await scheduler.jobs[1].operation()
        poller.requestReload()
        XCTAssertEqual(reads, 2)
        poller.receive(foreground: true)
        try await appBackendEventually { reads == 3 && scheduler.jobs.count == 3 }
        poller.closeSession()
        XCTAssertTrue(scheduler.jobs[2].cancelled)
        await scheduler.jobs[2].operation()
        XCTAssertEqual(reads, 3)
        await poller.openSession()
        try await appBackendEventually { scheduler.jobs.count == 4 }
        poller.receive(authorized: false)
        XCTAssertTrue(scheduler.jobs[3].cancelled)
        await scheduler.jobs[3].operation()
        XCTAssertEqual(reads, 4)
        poller.receive(authorized: true)
        poller.requestReload()
        XCTAssertEqual(reads, 4) // A later account cannot inherit screen visibility.
    }

    func testCodeReplacementAndExpiryReloadAndScanningStopsPeriodicReads() async throws {
        let scheduler = ManualReceiptUploadScheduler()
        var reads = 0
        var monotonic: TimeInterval = 0
        var issued = 0
        let qr = QRModel(actions: .init(issueCode: {
            issued += 1
            return QRCode(payload: QRPayload(token: String(repeating: issued == 1 ? "a" : "b", count: 32))!,
                expiresAt: Date(timeIntervalSince1970: 120))
        }, cancelCode: { _ in }, redeemCode: { _ in "new" }), navigation: pollNavigation { _ in }, monotonicNow: { monotonic })
        let poller = EncounterConfirmationPoller(clock: ManualEncounterClock(), scheduler: scheduler,
            load: { reads += 1; return [] }, confirm: { _, _ in XCTFail("No new QR") })
        poller.receive(authorized: true); poller.receive(foreground: true)
        await poller.openQR(qr)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        await qr.appear()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        await qr.refreshCode()
        try await appBackendEventually { reads > 1 }
        let beforeExpiry = reads
        monotonic = 120
        await qr.tick()
        try await appBackendEventually { reads > beforeExpiry }
        qr.select(.scan)
        let beforeScan = reads
        let pending = scheduler.jobs
        for job in pending { await job.operation() }
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
        opening.cancel()
        await opening.value
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testBackgroundAndDisappearFenceHeldConfirmation() async throws {
        let scheduler = ManualReceiptUploadScheduler()
        var resume: CheckedContinuation<[EncounterFeedCard]?, Never>?
        var reads = 0
        var opened = false
        let qr = pollQR { _ in opened = true }
        let poller = EncounterConfirmationPoller(clock: ManualEncounterClock(), scheduler: scheduler, load: {
            reads += 1
            if reads == 1 { return [] }
            return await withCheckedContinuation { resume = $0 }
        }, confirm: { model, id in model.receiveConfirmedEncounter(id) })
        poller.receive(authorized: true); poller.receive(foreground: true)
        await poller.openQR(qr); await qr.appear()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        let loading = Task { await scheduler.jobs[0].operation() }
        try await appBackendEventually { resume != nil }
        poller.receive(foreground: false)
        poller.closeQR(qr)
        resume?.resume(returning: [pollCard("late", kind: .qr)])
        await loading.value
        XCTAssertFalse(opened)
        XCTAssertEqual(scheduler.jobs.count, 1)
        qr.disappear()
    }
}

private func pollCard(_ id: String, kind: EncounterUI.EncounterKind) -> EncounterFeedCard {
    .init(card: .init(id: id, kind: kind, day: .init(year: 2026, month: 10, day: 13)), favorite: false)
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
