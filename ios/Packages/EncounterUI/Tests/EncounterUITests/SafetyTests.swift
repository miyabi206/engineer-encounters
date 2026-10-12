import XCTest
@testable import EncounterUI

final class SafetyTests: XCTestCase {
    func testImpersonationRequiresContextAndOtherReasonsOmitTheLink() throws {
        let link = SafetyReportLinkContext(id: "visible-link")
        for reason in SafetyReportReason.allCases {
            let withLink = try XCTUnwrap(SafetyReportRequest(encounterID: "encounter", reason: reason, link: link))
            XCTAssertEqual(withLink.encounterID, "encounter")
            XCTAssertEqual(withLink.linkID, reason == .impersonation ? link.id : nil)
            let withoutLink = SafetyReportRequest(encounterID: "encounter", reason: reason, link: nil)
            XCTAssertEqual(withoutLink == nil, reason == .impersonation)
        }
        XCTAssertEqual(SafetyReportReason.allCases.map(\.rawValue), ["spam", "harassment", "impersonation", "other"])
    }

    func testSubmissionStateConcealsUntilCancellationAndOnlyAcceptanceIsSuccess() throws {
        let request = try XCTUnwrap(SafetyReportRequest(encounterID: "encounter", reason: .spam, link: nil))
        let submission = SafetySubmission.report(request)
        var state = SafetyReportState.idle
        state.accept()
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(state.isPending)
        XCTAssertTrue(state.begin(submission))
        XCTAssertTrue(state.isHidden)
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.isPending)
        XCTAssertFalse(state.begin(submission))
        XCTAssertFalse(state.cancel())
        state.fail()
        XCTAssertTrue(state.isHidden)
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(state.isPending)
        XCTAssertEqual(state.retry, submission)
        XCTAssertTrue(state.begin(submission))
        state.accept()
        XCTAssertEqual(state, .accepted(submission))
        XCTAssertFalse(state.isPending)
        XCTAssertFalse(state.cancel())
        XCTAssertFalse(state.begin(submission))

        state = .failed(submission)
        XCTAssertTrue(state.cancel())
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(state.isHidden)
    }

    @MainActor
    func testMissingReasonAndUnscopedImpersonationCannotSubmit() async {
        let driver = SafetyTestDriver()
        let model = driver.model()
        await model.submit()
        XCTAssertFalse(model.canSubmit)
        model.reason = .impersonation
        await model.submit()
        XCTAssertFalse(model.canSubmit)
        XCTAssertTrue(driver.calls.isEmpty)
        XCTAssertEqual(model.state, .idle)
    }

    @MainActor
    func testPendingReportHidesBeforeIOAndDisablesAllRepeatedActions() async {
        let driver = SafetyTestDriver()
        let model = driver.model(link: .init(id: "link"))
        XCTAssertEqual(model.reason, .impersonation)
        driver.duringSubmission = {
            XCTAssertEqual(driver.calls, ["conceal", "report"])
            XCTAssertTrue(model.isBusy)
            XCTAssertTrue(model.state.isHidden)
            await model.submit(); await model.block(); await model.retry(); await model.cancel()
        }
        await model.submit()
        XCTAssertEqual(driver.calls, ["conceal", "report", "completed"])
        XCTAssertEqual(driver.requests.first?.linkID, "link")
        XCTAssertNil(model.error)
        guard case .accepted(.report) = model.state else { return XCTFail("Expected accepted report") }
        XCTAssertFalse(model.state.isPending)
    }

    @MainActor
    func testOfflineReportRetainsReasonAndContextForExactRetry() async {
        let driver = SafetyTestDriver()
        driver.failure = .init(code: .unavailable)
        let model = driver.model(link: .init(id: "link"))
        await model.submit()
        XCTAssertEqual(model.reason, .impersonation)
        XCTAssertTrue(model.state.isHidden)
        XCTAssertEqual(driver.calls, ["conceal", "report"])
        XCTAssertNotNil(model.error)
        guard case .failed(.report(let request)) = model.state else { return XCTFail("Expected failed report") }
        XCTAssertEqual(request.linkID, "link")
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(driver.requests, [request, request])
        XCTAssertEqual(driver.calls, ["conceal", "report", "conceal", "report", "completed"])
        XCTAssertNil(model.error)
    }

    @MainActor
    func testBlockFailureAndRetryUseOriginalEncounterAndHideOnSuccess() async {
        let driver = SafetyTestDriver()
        driver.failure = .init(code: .unavailable)
        let model = driver.model()
        await model.block()
        XCTAssertEqual(model.state, .failed(.block("encounter")))
        XCTAssertEqual(driver.blocks, ["encounter"])
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(model.state, .accepted(.block("encounter")))
        XCTAssertFalse(model.state.isPending)
        XCTAssertEqual(driver.blocks, ["encounter", "encounter"])
        XCTAssertEqual(driver.calls, ["conceal", "block", "conceal", "block", "completed"])
    }

    @MainActor
    func testCancelFailedReportClearsPendingHideAndRequiresFreshAuthorization() async {
        for authorized in [false, true] {
            let driver = SafetyTestDriver()
            driver.failure = .init(code: .unavailable)
            driver.authorized = authorized
            let model = driver.model()
            model.reason = .other
            await model.submit()
            driver.duringAuthorization = {
                XCTAssertTrue(model.isBusy)
                XCTAssertFalse(model.canSubmit)
                await model.submit(); await model.block(); await model.cancel()
            }
            await model.cancel()
            XCTAssertEqual(model.state, .idle)
            XCTAssertNil(model.error)
            XCTAssertEqual(driver.calls, ["conceal", "report", "clear", "authorize", authorized ? "reopen" : "completed"])
        }
    }

    @MainActor
    func testAuthorizationFailureNeverReopensAndAcceptedCancelDoesNotClearHide() async {
        let driver = SafetyTestDriver()
        driver.authorizationFails = true
        let model = driver.model()
        model.reason = .spam
        driver.failure = .init(code: .unavailable)
        await model.submit()
        await model.cancel()
        XCTAssertEqual(driver.calls, ["conceal", "report", "clear", "authorize", "completed"])
        driver.calls = []
        driver.failure = nil
        await model.submit()
        await model.cancel()
        XCTAssertEqual(driver.calls, ["conceal", "report", "completed", "completed"])
    }

    @MainActor
    func testCancelIdleSheetOnlyClosesWithoutClearingHideOrAuthorizing() async {
        for reason in [SafetyReportReason?.none, .spam] {
            let driver = SafetyTestDriver()
            driver.authorizationFails = true
            let model = driver.model()
            model.reason = reason
            await model.cancel()
            XCTAssertEqual(driver.calls, ["reopen"])
            XCTAssertEqual(model.state, .idle)
            XCTAssertFalse(model.isBusy)
            XCTAssertNil(model.error)
            XCTAssertTrue(driver.requests.isEmpty)
            XCTAssertTrue(driver.blocks.isEmpty)
        }
    }

    @MainActor
    func testUnblockNotFoundAfterFailedAttemptRemovesOnlyItsRow() async {
        let day = EncounterDay(year: 2026, month: 10, day: 12)
        let block = SafetyBlock(id: "opaque", placedDay: day)
        let other = SafetyBlock(id: "other", placedDay: day)
        var failure = ProfileActionError(code: .unavailable)
        var calls: [String] = []
        let model = SafetyBlockedModel(list: .init(blocks: [block, other], truncated: true), actions: .init(
            load: { XCTFail("Unblock must not reload"); return .init(blocks: []) }, unblock: { id in
                calls.append(id); throw failure
            }), navigation: .init(back: {}))
        await model.unblock(block.id)
        XCTAssertEqual(model.list?.blocks, [block, other])
        XCTAssertEqual(model.failedBlockID, block.id)
        failure = .init(code: .notFound)
        await model.retry()
        await model.unblock(block.id)
        XCTAssertEqual(calls, ["opaque", "opaque"])
        XCTAssertEqual(model.list?.blocks, [other])
        XCTAssertEqual(model.list?.truncated, true)
        XCTAssertNil(model.error)
        XCTAssertNil(model.failedBlockID)
    }

    @MainActor
    func testUnblockFailureKeepsBlockUntilConfirmedAndRetryUsesOpaqueID() async {
        let block = SafetyBlock(id: "opaque", placedDay: .init(year: 2026, month: 10, day: 12))
        var fails = true
        var calls: [String] = []
        let model = SafetyBlockedModel(list: .init(blocks: [block], truncated: true), actions: .init(
            load: { .init(blocks: [block]) }, unblock: { id in
                calls.append(id)
                if fails { throw ProfileActionError(code: .unavailable) }
            }), navigation: .init(back: {}))
        await model.unblock("unknown")
        XCTAssertTrue(calls.isEmpty)
        await model.unblock(block.id)
        XCTAssertEqual(model.list?.blocks, [block])
        XCTAssertEqual(model.failedBlockID, block.id)
        XCTAssertEqual(model.list?.truncated, true)
        fails = false
        await model.retry()
        XCTAssertEqual(calls, ["opaque", "opaque"])
        XCTAssertEqual(model.list?.blocks, [])
        XCTAssertNil(model.error)
        XCTAssertNil(model.failedBlockID)
    }

    @MainActor
    func testBlockListLoadingFailureClearsRowsAndRetryReloads() async {
        var fails = true
        var calls = 0
        let model = SafetyBlockedModel(list: .init(blocks: []), actions: .init(load: {
            calls += 1
            if fails { throw ProfileActionError(code: .unavailable) }
            return .init(blocks: [])
        }, unblock: { _ in }), navigation: .init(back: {}))
        await model.load()
        XCTAssertNil(model.list)
        XCTAssertNotNil(model.error)
        fails = false
        await model.retry()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.list?.blocks, [])
        XCTAssertNil(model.error)
    }
}

@MainActor
private final class SafetyTestDriver {
    var calls: [String] = []
    var requests: [SafetyReportRequest] = []
    var blocks: [String] = []
    var failure: ProfileActionError?
    var authorized = true
    var authorizationFails = false
    var duringSubmission: (@MainActor () async -> Void)?
    var duringAuthorization: (@MainActor () async -> Void)?
    func model(link: SafetyReportLinkContext? = nil) -> SafetyReportModel {
        SafetyReportModel(encounterID: "encounter", link: link, actions: .init(report: { request in
            self.calls.append("report"); self.requests.append(request)
            await self.duringSubmission?(); try self.check()
        }, block: { id in
            self.calls.append("block"); self.blocks.append(id)
            await self.duringSubmission?(); try self.check()
        }, conceal: { self.calls.append("conceal") }, clearPendingHide: { self.calls.append("clear") },
        authorizeReopening: {
            self.calls.append("authorize"); await self.duringAuthorization?()
            if self.authorizationFails { throw ProfileActionError(code: .unavailable) }
            return self.authorized
        }), navigation: .init(completed: { self.calls.append("completed") }, reopenEncounter: { self.calls.append("reopen") }))
    }
    private func check() throws { if let failure { throw failure } }
}

final class SafetyStringsTests: XCTestCase {
    func testBothLanguagesDefineEveryKey() throws {
        for language in ["ja", "en"] {
            let table = try SafetyStrings.table(language: language)
            XCTAssertEqual(Set(table.keys), Set(SafetyString.allCases.map(\.rawValue)))
            for key in SafetyString.allCases {
                let value = try XCTUnwrap(table[key.rawValue])
                XCTAssertFalse(value.isEmpty)
                XCTAssertEqual(SafetyStrings.localized(key.rawValue, language: language), value)
            }
        }
        XCTAssertEqual(SafetyStrings.localized("blockExplanation", language: "ja"),
            "ブロックすると、2人のすれちがいと保存した項目が削除されます。")
        XCTAssertEqual(SafetyStrings.localized("review", language: "en"),
            "The operator reviews suspended profiles within 72 hours")
    }
}
