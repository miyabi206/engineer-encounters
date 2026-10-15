import XCTest
@testable import EncounterUI

final class QRPayloadTests: XCTestCase {
    private let token = "0123456789abcdef0123456789abcdef"

    func testExactOpaqueWireFormatRoundTrips() throws {
        let payload = try XCTUnwrap(QRPayload(token: token))
        XCTAssertEqual(payload.text, "EEQR1:" + token)
        XCTAssertEqual(QRPayload(text: payload.text), payload)
        XCTAssertNotNil(QRPayload(token: String(repeating: "0", count: 32)))
        XCTAssertNotNil(QRPayload(token: String(repeating: "f", count: 32)))
        let code = try XCTUnwrap(QRCode(payloadText: payload.text, expiresAt: Date(timeIntervalSince1970: 120)))
        XCTAssertEqual(code.payloadText, payload.text)
        XCTAssertNil(QRCode(payloadText: "not a code", expiresAt: code.expiresAt))
    }

    func testRejectsEveryMalformedShapeWithoutTrimmingOrNormalizing() {
        let wire = "EEQR1:" + token
        let malformed = [
            "", token, "EEQR1:", "EEQR2:" + token, "eeqr1:" + token,
            "EEQR1" + token, "EEQR1::" + token, "OTHER:" + token,
            "EEQR1:" + String(token.dropLast()), "EEQR1:" + token + "0",
            "EEQR1:" + token.uppercased(), "EEQR1:" + String(repeating: "g", count: 32),
            "EEQR1:" + String(repeating: "-", count: 32),
            "EEQR1:" + String(repeating: "ａ", count: 32),
            "EEQR1:" + String(repeating: "é", count: 32),
            " " + wire, wire + " ", wire + "\n", wire + "\r\n", wire + "\t",
            "\n" + wire, wire + "\0", "\u{FEFF}" + wire,
            "EEQR1:" + String(token.dropLast()) + " ",
            "EEQR1:" + String(token.dropLast()) + "\n",
            "EEQR1:" + String(token.dropLast()) + "\0",
            wire + "?name=person", "https://example.com/" + wire
        ]
        for value in malformed { XCTAssertNil(QRPayload(text: value), value.debugDescription) }
        for byte in UInt8.min...UInt8.max where !((48...57).contains(byte) || (97...102).contains(byte)) {
            let value = String(decoding: Array(repeating: UInt8(48), count: 31) + [byte], as: UTF8.self)
            XCTAssertNil(QRPayload(token: value), "byte \(byte)")
        }
    }

    func testExpiryReplacementAndSelfScanRules() throws {
        let now = Date(timeIntervalSince1970: 100)
        let payload = try XCTUnwrap(QRPayload(token: token))
        let code = QRCode(payload: payload, expiresAt: now.addingTimeInterval(120))
        XCTAssertTrue(QRCodeRules.shouldReplace(nil, now: now))
        XCTAssertFalse(QRCodeRules.shouldReplace(code, now: now))
        XCTAssertFalse(QRCodeRules.isExpired(code, now: now.addingTimeInterval(119.999)))
        XCTAssertTrue(QRCodeRules.shouldReplace(code, now: now.addingTimeInterval(120)))
        XCTAssertEqual(QRCodeRules.validate(payload.text, ownPayloads: [payload]), .failure(.selfScan))
        XCTAssertEqual(QRCodeRules.validate(payload.text, ownPayloads: []), .success(payload))
        XCTAssertEqual(QRCodeRules.validate("invalid", ownPayloads: []), .failure(.unknownCode))
    }

    func testCameraPermissionMappingIncludesUnknownRestrictedFallback() {
        XCTAssertEqual(QRPermissionMapping.permission(authorizationRawValue: 0), .notDetermined)
        XCTAssertEqual(QRPermissionMapping.permission(authorizationRawValue: 1), .restricted)
        XCTAssertEqual(QRPermissionMapping.permission(authorizationRawValue: 2), .denied)
        XCTAssertEqual(QRPermissionMapping.permission(authorizationRawValue: 3), .authorized)
        XCTAssertEqual(QRPermissionMapping.permission(authorizationRawValue: -1), .restricted)
        XCTAssertEqual(QRPermissionMapping.permission(authorizationRawValue: 99), .restricted)
    }
}
