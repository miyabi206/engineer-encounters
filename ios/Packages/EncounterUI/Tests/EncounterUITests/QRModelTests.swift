import XCTest
@testable import EncounterUI

final class QRModelTests: XCTestCase {
    @MainActor
    func testIssueCountdownExpiryAndManualReplacement() async throws {
        let driver = QRTestDriver()
        let model = driver.model()
        await model.appear()
        let first = try XCTUnwrap(model.code)
        XCTAssertEqual(model.remainingSeconds, 120)
        driver.now = driver.now.addingTimeInterval(119)
        await model.tick()
        XCTAssertEqual(model.remainingSeconds, 1)
        XCTAssertEqual(driver.issues, 1)
        driver.now = driver.now.addingTimeInterval(1)
        await model.tick()
        let second = try XCTUnwrap(model.code)
        XCTAssertNotEqual(first.payload, second.payload)
        XCTAssertEqual(driver.cancelled, [first])
        XCTAssertEqual(model.remainingSeconds, 120)
        await model.refreshCode()
        XCTAssertNotEqual(model.code?.payload, second.payload)
        XCTAssertEqual(driver.cancelled, [first, second])
        XCTAssertEqual(driver.operations, ["issue", "cancel", "issue", "cancel", "issue"])
    }

    @MainActor
    func testRefreshHidesOldCodeAndFailureNeedsRetry() async throws {
        let driver = QRTestDriver()
        let model = driver.model()
        await model.appear()
        let first = try XCTUnwrap(model.code)
        driver.issueFailure = .network
        driver.duringIssue = {
            XCTAssertNil(model.code)
            XCTAssertTrue(model.isIssuing)
            await model.refreshCode()
        }
        await model.refreshCode()
        XCTAssertNil(model.code)
        XCTAssertEqual(model.error, .network)
        XCTAssertEqual(driver.cancelled, [first])
        await model.tick()
        XCTAssertEqual(driver.issues, 2)
        driver.issueFailure = nil
        await model.retry()
        XCTAssertNotNil(model.code)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testMalformedAndOwnScansNeverReachRedeemIncludingPreviousOwnCode() async throws {
        let driver = QRTestDriver()
        let model = driver.model()
        await model.appear()
        let first = try XCTUnwrap(model.code)
        await model.refreshCode()
        model.select(.scan)
        await model.scan("invalid")
        XCTAssertEqual(model.error, .unknownCode)
        XCTAssertTrue(driver.redeemed.isEmpty)
        await model.retry()
        await model.scan(first.payloadText)
        XCTAssertEqual(model.error, .selfScan)
        XCTAssertTrue(driver.redeemed.isEmpty)
        await model.retry()
        let current = try XCTUnwrap(model.code)
        await model.scan(current.payloadText)
        XCTAssertEqual(model.error, .selfScan)
        XCTAssertTrue(driver.redeemed.isEmpty)
    }

    @MainActor
    func testNetworkRedemptionRetryOpensOnlyAfterAcknowledgement() async throws {
        let driver = QRTestDriver()
        let model = driver.model()
        await model.appear()
        let peer = try XCTUnwrap(QRPayload(token: String(repeating: "a", count: 32)))
        model.select(.scan)
        driver.redeemFailure = .network
        driver.duringRedeem = {
            XCTAssertTrue(model.isRedeeming)
            XCTAssertTrue(driver.opened.isEmpty)
            await model.scan(peer.text)
        }
        await model.scan(peer.text)
        XCTAssertEqual(model.error, .network)
        XCTAssertTrue(driver.opened.isEmpty)
        driver.redeemFailure = nil
        await model.retry()
        XCTAssertEqual(driver.redeemed, [peer, peer])
        XCTAssertEqual(driver.opened, ["confirmed-encounter"])
        XCTAssertTrue(model.hasConfirmed)
        await model.scan(peer.text)
        model.receiveConfirmedEncounter("duplicate")
        XCTAssertEqual(driver.opened.count, 1)
    }

    @MainActor
    func testServerScanErrorsMapToExactWordingAndRequireANewScan() async throws {
        let peer = try XCTUnwrap(QRPayload(token: String(repeating: "a", count: 32)))
        let cases: [(QRActionError, SessionString)] = [
            (.selfScan, .selfScan), (.expired, .expired), (.alreadyUsed, .alreadyUsed),
            (.unknownCode, .unreadable), (.replaced, .unreadable), (.network, .qrNetwork)
        ]
        for (failure, key) in cases {
            let driver = QRTestDriver()
            let model = driver.model()
            await model.appear()
            model.select(.scan)
            driver.redeemFailure = failure
            await model.scan(peer.text)
            XCTAssertEqual(model.error, failure)
            XCTAssertEqual(SessionStrings.error(failure), key)
            XCTAssertTrue(driver.opened.isEmpty)
            if failure != .network {
                await model.retry()
                XCTAssertNil(model.error)
                XCTAssertEqual(driver.redeemed.count, 1)
            }
        }
    }

    @MainActor
    func testCancellationFailureIsRetainedAndRetriedBeforeIssuance() async throws {
        let driver = QRTestDriver()
        let model = driver.model()
        await model.appear()
        let first = try XCTUnwrap(model.code)
        driver.cancelFailure = .network
        await model.refreshCode()
        XCTAssertNil(model.code)
        XCTAssertEqual(model.error, .network)
        XCTAssertEqual(driver.issues, 1)
        driver.cancelFailure = nil
        await model.retry()
        XCTAssertEqual(driver.cancelled, [first, first])
        XCTAssertEqual(driver.issues, 2)
    }

    @MainActor
    func testExpiryWhileScanningClearsTheCodeWithoutIssuingUntilShow() async throws {
        let driver = QRTestDriver()
        let model = driver.model()
        await model.appear()
        model.select(.scan)
        driver.now = driver.now.addingTimeInterval(120)
        await model.tick()
        XCTAssertNil(model.code)
        XCTAssertEqual(driver.issues, 1)
        model.select(.show)
        await model.tick()
        XCTAssertNotNil(model.code)
        XCTAssertEqual(driver.issues, 2)
    }

    @MainActor
    func testLateIssuanceAfterDisappearanceIsCancelledInsteadOfDisplayed() async {
        let driver = QRTestDriver()
        let model = driver.model()
        driver.duringIssue = { model.disappear() }
        await model.appear()
        XCTAssertNil(model.code)
        XCTAssertEqual(driver.cancelled.count, 1)
        XCTAssertEqual(model.remainingSeconds, 0)
        await model.tick()
        XCTAssertEqual(driver.issues, 1)
    }

    @MainActor
    func testLateRedeemAfterDisappearanceDoesNotNavigate() async throws {
        let driver = QRTestDriver()
        let model = driver.model()
        await model.appear()
        driver.duringRedeem = { model.disappear() }
        model.select(.scan)
        let peer = try XCTUnwrap(QRPayload(token: String(repeating: "a", count: 32)))
        await model.scan(peer.text)
        XCTAssertTrue(driver.opened.isEmpty)
        XCTAssertFalse(model.hasConfirmed)
    }

    @MainActor
    func testCameraFramesAfterDisappearanceAreIgnored() async throws {
        let driver = QRTestDriver()
        let model = driver.model()
        await model.appear()
        model.select(.scan)
        model.disappear()
        let peer = try XCTUnwrap(QRPayload(token: String(repeating: "a", count: 32)))
        await model.scan(peer.text)
        XCTAssertTrue(driver.redeemed.isEmpty)
    }

    @MainActor
    func testAlreadyExpiredIssuanceIsNeverDisplayed() async {
        let driver = QRTestDriver()
        let model = driver.model()
        driver.validity = 0
        await model.appear()
        XCTAssertNil(model.code)
        XCTAssertEqual(model.error, .expired)
    }

    @MainActor
    func testPermissionAndShowingParticipantConfirmation() async {
        let driver = QRTestDriver()
        let model = driver.model()
        for permission in [QRCameraPermission.notDetermined, .authorized, .denied, .restricted] {
            model.receiveCameraPermission(permission)
            XCTAssertEqual(model.cameraPermission, permission)
        }
        await model.appear()
        XCTAssertNotNil(model.code) // Denied/restricted camera does not block showing a code.
        model.receiveConfirmedEncounter("shown-confirmation")
        XCTAssertEqual(driver.opened, ["shown-confirmation"])
        XCTAssertTrue(model.hasConfirmed)
        model.cameraFailed()
        XCTAssertEqual(model.error, .cameraUnavailable)
        XCTAssertEqual(SessionStrings.error(.cameraUnavailable), .cameraUnavailable)
    }
}

@MainActor
private final class QRTestDriver {
    var now = Date(timeIntervalSince1970: 1000)
    var validity: TimeInterval = 120
    var issues = 0
    var cancelled: [QRCode] = []
    var redeemed: [QRPayload] = []
    var opened: [String] = []
    var operations: [String] = []
    var issueFailure: QRActionError?
    var cancelFailure: QRActionError?
    var redeemFailure: QRActionError?
    var duringIssue: (@MainActor () async -> Void)?
    var duringRedeem: (@MainActor () async -> Void)?

    func model() -> QRModel {
        QRModel(actions: QRActions(issueCode: {
            self.issues += 1; self.operations.append("issue")
            await self.duringIssue?()
            if let failure = self.issueFailure { throw failure }
            // The decimal digits in these test tokens are also valid lowercase hexadecimal.
            let token = String(format: "%032d", self.issues)
            guard let payload = QRPayload(token: token) else { throw QRActionError.unknownCode }
            return QRCode(payload: payload, expiresAt: self.now.addingTimeInterval(self.validity))
        }, cancelCode: { code in
            self.operations.append("cancel"); self.cancelled.append(code)
            if let failure = self.cancelFailure { throw failure }
        }, redeemCode: { payload in
            self.redeemed.append(payload)
            await self.duringRedeem?()
            if let failure = self.redeemFailure { throw failure }
            return "confirmed-encounter"
        }), navigation: QRNavigationActions(openEncounter: { self.opened.append($0) },
                                            openIOSSettings: {}, close: {}), now: { self.now })
    }
}
