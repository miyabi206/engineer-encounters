import EncounterBackend
import EncounterDomainTestSupport
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class QRAdapterTests: XCTestCase {
    func testIssueCancelAndRedeemMappingAndFeedRefresh() async throws {
        let transport = productTransport([
            "issue_qr_code": [.response(qrIssued())], "cancel_qr_code": [.response(qrCancelled())],
            "redeem_qr_code": [.response(productResponse(["encounter_id": productEncounterID]))],
            "get_encounter_feed": [.response(productFeed()), .response(productFeed())]
        ])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        await composition.discoverAdapter.model?.loadFeed()
        let actions = composition.qrAdapter.actions()
        let code = try await actions.issueCode()
        XCTAssertEqual(code.expiresAt, Date(timeIntervalSince1970: 1120))
        XCTAssertNotNil(QRPayload(text: code.payloadText))
        try await actions.cancelCode(code)
        let id = try await actions.redeemCode(QRPayload(token: String(repeating: "b", count: 32))!)
        XCTAssertEqual(id, productEncounterID)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.compactMap { $0.url?.lastPathComponent }, ["register_time_zone", "get_encounter_feed",
            "issue_qr_code", "cancel_qr_code", "redeem_qr_code", "get_encounter_feed"])
        let parameters = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests[4].httpBody)) as? [String: String])
        XCTAssertEqual(Set(parameters.keys), ["code"])
        XCTAssertEqual(parameters["code"]?.count, 32)
        XCTAssertFalse(parameters["code"]?.hasPrefix("EEQR1:") ?? true)
    }

    func testLeavingQRHidesAndCancelsOutstandingCode() async throws {
        let transport = productTransport(["issue_qr_code": [.response(qrIssued())], "cancel_qr_code": [.response(qrCancelled())]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration()
        let model = composition.qrAdapter.makeModel(navigation: qrNavigation())
        await model.appear()
        XCTAssertNotNil(model.code)
        model.disappear()
        XCTAssertNil(model.code)
        XCTAssertEqual(model.remainingSeconds, 0)
        try await appBackendEventually { await transport.count("cancel_qr_code") == 1 }
    }

    func testLateCleanupCannotCancelReplacementCode() async throws {
        let transport = productTransport(["issue_qr_code": [.response(qrIssued()), .response(qrIssued(token: "b"))],
            "cancel_qr_code": [.response(qrCancelled())]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration()
        let actions = composition.qrAdapter.actions()
        let old = try await actions.issueCode()
        let current = try await actions.issueCode()
        try await actions.cancelCode(old)
        let before = await transport.count("cancel_qr_code")
        XCTAssertEqual(before, 0)
        try await actions.cancelCode(current)
        let after = await transport.count("cancel_qr_code")
        XCTAssertEqual(after, 1)
    }

    func testSigningOutCancelsBeforeCredentialsAndPreservesSample() async throws {
        let defaults = appBackendDefaults()
        let transport = productTransport(["issue_qr_code": [.response(qrIssued())], "cancel_qr_code": [.response(qrCancelled())]])
        let composition = try productComposition(transport, defaults: defaults)
        await composition.waitForRestoration()
        let model = composition.qrAdapter.makeModel(navigation: qrNavigation())
        await model.appear()
        composition.sampleEncounter.dismiss()
        try await composition.account.signOut()
        XCTAssertNil(model.code)
        XCTAssertEqual(composition.account.state, .signedOut)
        let cancellations = await transport.count("cancel_qr_code")
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(defaults.bool(forKey: InstallationSampleDismissalStore.key))
    }

    func testSignOutDoesNotWaitForeverForFailedBestEffortCancel() async throws {
        let clock = ManualEncounterClock()
        let transport = productTransport(["issue_qr_code": [.response(qrIssued())], "cancel_qr_code": [.held]])
        let composition = try productComposition(transport, clock: clock)
        await composition.waitForRestoration()
        _ = try await composition.qrAdapter.actions().issueCode()
        let signingOut = Task { try await composition.account.signOut() }
        try await appBackendEventually { await transport.isHeld("cancel_qr_code") }
        try await appBackendEventually { await clock.pendingWaitCount > 0 }
        await clock.advance(by: 2)
        try await signingOut.value
        XCTAssertEqual(composition.account.state, .signedOut)
        await transport.release("cancel_qr_code", with: qrCancelled())
        XCTAssertNil(composition.qrAdapter.failure)
    }

    func testLeavingDuringIssueCancelsLateResponse() async throws {
        let transport = productTransport(["issue_qr_code": [.held], "cancel_qr_code": [.response(qrCancelled())]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration()
        let model = composition.qrAdapter.makeModel(navigation: qrNavigation())
        let appearing = Task { await model.appear() }
        try await appBackendEventually { await transport.isHeld("issue_qr_code") }
        model.disappear()
        await transport.release("issue_qr_code", with: qrIssued())
        await appearing.value
        XCTAssertNil(model.code)
        let cancellations = await transport.count("cancel_qr_code")
        XCTAssertEqual(cancellations, 1)
    }

    func testHeldOldIssueCannotDelayOrPopulateNextAccountsQR() async throws {
        let other = UUID()
        let transport = productTransport([
            "issue_qr_code": [.held, .response(qrIssued(token: "b"))],
            "signin": [.response(appBackendAuthResponse(userID: other))],
            "accept_declarations": [.response(appAccountOK())]
        ])
        let composition = try productComposition(transport)
        await composition.waitForRestoration()
        let old = composition.qrAdapter.actions()
        let issuing = Task { try await old.issueCode() }
        try await appBackendEventually { await transport.isHeld("issue_qr_code") }
        try await composition.account.signOut()
        try await composition.account.signIn(using: AuthRequest(path: "signin", body: Data()),
            isAdult: true, acceptsTermsAndPrivacy: true, termsVersion: "fixture-terms", privacyVersion: "fixture-privacy")
        let nextIssue = Task { try await composition.qrAdapter.actions().issueCode() }
        // The outgoing transport remains held; the new account must proceed independently.
        try await appBackendEventually { await transport.count("issue_qr_code") == 2 }
        _ = try await nextIssue.value
        await transport.release("issue_qr_code", with: qrIssued())
        do { _ = try await issuing.value; XCTFail("Old issue must not enter the new account") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(composition.account.state, .signedIn(other))
        XCTAssertNil(composition.qrAdapter.failure)
    }

    func testEveryQRActionMapsCodeDetailAndTransportFailures() async throws {
        let failures: [(ControlledAppBackendTransport.Reply, QRActionError, ProfileActionError)] = [
            (.response(productError("prerequisite_missing", details: "discovery")), .prerequisiteMissing(details: ["discovery"]),
             .init(code: .prerequisiteMissing, fields: ["discovery"])),
            (.response(productError("prerequisite_missing", details: "link")), .prerequisiteMissing(details: ["link"]),
             .init(code: .prerequisiteMissing, fields: ["link"])),
            (.response(productError("not_authenticated")), .network, .init(code: .notAuthenticated)),
            (.response(productError("not_found")), .notFound, .init(code: .notFound)),
            (.response(productError("rate_limited")), .rateLimited, .init(code: .rateLimited)),
            (.response(productError("account_not_ready")), .prerequisiteMissing(details: ["account"]), .init(code: .accountNotReady)),
            (.response(productError("invalid_input", details: "code")), .unknownCode, .init(code: .invalidInput, fields: ["code"])),
            (.failure, .network, .init(code: .unavailable)),
            (.response(HTTPResponse(data: Data(), statusCode: 503)), .network, .init(code: .unavailable))
        ]
        for path in ["issue_qr_code", "cancel_qr_code", "redeem_qr_code"] {
            for (reply, expected, detailed) in failures {
                var plans = [path: detailed.code == .notAuthenticated ? [reply, reply] : [reply]]
                plans["token"] = [.response(appBackendAuthResponse())]
                if path == "cancel_qr_code" { plans["issue_qr_code"] = [.response(qrIssued())] }
                let composition = try productComposition(productTransport(plans))
                await composition.waitForRestoration()
                let actions = composition.qrAdapter.actions()
                let issued: QRCode?
                if path == "cancel_qr_code" { issued = try await actions.issueCode() } else { issued = nil }
                do {
                    switch path {
                    case "issue_qr_code": _ = try await actions.issueCode()
                    case "cancel_qr_code": try await actions.cancelCode(XCTUnwrap(issued))
                    default: _ = try await actions.redeemCode(QRPayload(token: String(repeating: "b", count: 32))!)
                    }
                    XCTFail("Expected sanitized failure")
                } catch { XCTAssertEqual(error as? QRActionError, expected, path) }
                if detailed.code == .notAuthenticated {
                    XCTAssertEqual(composition.account.state, .signedOut)
                } else { XCTAssertEqual(composition.qrAdapter.failure, detailed) }
            }
        }
    }

    func testDiscoveryPrerequisiteRoutesBackToOffPanel() async throws {
        let transport = productTransport(["issue_qr_code": [.response(productError("prerequisite_missing", details: "discovery"))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        var routed = false
        let model = composition.qrAdapter.makeModel(navigation: qrNavigation(discovery: {
            routed = true
            composition.discoverAdapter.model?.receiveAccess(discoveryOn: false, isAuthorized: true)
        }))
        await model.appear()
        XCTAssertTrue(routed)
        XCTAssertEqual(composition.discoverAdapter.model?.discoveryOn, false)
        XCTAssertNil(model.code)
    }
}

private func qrIssued(token: String = "a") -> HTTPResponse {
    productResponse(["code": String(repeating: token, count: 32), "expires_at": 1120])
}
private func qrCancelled() -> HTTPResponse { productResponse(["cancelled": true]) }
@MainActor
private func qrNavigation(discovery: @escaping @MainActor () -> Void = {}) -> QRNavigationActions {
    .init(openEncounter: { _ in }, openIOSSettings: {}, close: {}, openDiscoveryOff: discovery)
}
