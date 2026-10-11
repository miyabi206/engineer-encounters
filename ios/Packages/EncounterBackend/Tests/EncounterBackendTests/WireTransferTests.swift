import XCTest
import Foundation
import EncounterBackend
import EncounterDomain

@MainActor
final class WireTransferTests: XCTestCase {
    private let hex = "000102030405060708090a0b0c0d0e0f"
    private let peerHex = "ffffffffffffffffffffffffffffffff"

    func testTokenAndNonceHexRoundTripAndRedaction() throws {
        let bytes = Array(UInt8(0)...UInt8(15))
        let token = WireToken(try TemporaryToken(bytes: bytes))
        let nonce = WireNonce(try ExchangeNonce(bytes: bytes))
        let encoded = Data(("\"" + hex + "\"").utf8)
        XCTAssertEqual(try JSONEncoder().encode(token), encoded)
        XCTAssertEqual(try JSONEncoder().encode(nonce), encoded)
        XCTAssertEqual(try JSONDecoder().decode(WireToken.self, from: encoded).token.bytes, bytes)
        XCTAssertEqual(try JSONDecoder().decode(WireNonce.self, from: encoded).nonce.bytes, bytes)
        XCTAssertEqual(try WireToken(hex: hex), token)
        XCTAssertEqual(try WireNonce(hex: hex), nonce)
        for value in [token as Any, nonce as Any] {
            XCTAssertTrue(String(describing: value).contains("<redacted>"))
            XCTAssertTrue(String(reflecting: value).contains("<redacted>"))
            XCTAssertFalse(String(reflecting: value).contains(hex))
            XCTAssertEqual(Mirror(reflecting: value).children.count, 0)
        }
    }

    func testHexRejectsWrongLengthsNonHexAndUppercaseWithoutEchoingInput() throws {
        for value in ["", String(repeating: "a", count: 31), String(repeating: "a", count: 33),
                      String(repeating: "g", count: 32), hex.uppercased(), String(repeating: "é", count: 16)] {
            XCTAssertThrowsError(try WireToken(hex: value)) { XCTAssertNotNil($0 as? WireValueError) }
            XCTAssertThrowsError(try WireNonce(hex: value)) { XCTAssertNotNil($0 as? WireValueError) }
            let encoded = try JSONEncoder().encode(value)
            XCTAssertThrowsError(try JSONDecoder().decode(WireToken.self, from: encoded)) {
                XCTAssertNotNil($0 as? WireValueError)
            }
            XCTAssertThrowsError(try JSONDecoder().decode(WireNonce.self, from: encoded)) {
                XCTAssertNotNil($0 as? WireValueError)
            }
        }
        XCTAssertThrowsError(try WireToken(hex: "a")) {
            XCTAssertEqual($0 as? WireValueError, .invalidHexLength(expected: 32, actual: 1))
        }
    }

    func testWholeUnixSecondsInBothDirections() throws {
        for (fractional, whole) in [(1800000000.999, Int64(1800000000)), (-0.25, Int64(-1)), (0.0, Int64(0))] {
            let value = try WireSeconds(Date(timeIntervalSince1970: fractional))
            XCTAssertEqual(value.unixSeconds, whole)
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), String(whole))
            let decoded = try JSONDecoder().decode(WireSeconds.self, from: encoded)
            XCTAssertEqual(decoded.date, Date(timeIntervalSince1970: TimeInterval(whole)))
            XCTAssertEqual(decoded, value)
        }
        for json in ["1.5", "\"1800000000\"", "null", "9223372036854775808", "9007199254740992"] {
            XCTAssertThrowsError(try JSONDecoder().decode(WireSeconds.self, from: Data(json.utf8))) {
                XCTAssertEqual($0 as? WireValueError, .invalidSeconds)
            }
        }
        XCTAssertThrowsError(try WireSeconds(Date(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(try WireSeconds(unixSeconds: .max))
    }

    func testHeldConnectionReceiptConversionAndLocalStatusOmission() throws {
        let receipt = try makeReceipt(checkpoint: true, prior: false)
        let transfer = try SubmitReceiptsParameters(receipts: [receipt])
        let root = try object(transfer)
        XCTAssertEqual(Set(root.keys), ["receipts"])
        let rows = try XCTUnwrap(root["receipts"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(Set(row.keys), ["id", "protocol_version", "role", "exchange_nonce", "start", "checkpoint",
                                       "observed_duration", "session_flag", "is_final_evidence"])
        XCTAssertEqual(row["id"] as? String, receipt.id.uuidString)
        XCTAssertEqual(row["protocol_version"] as? Int, 1)
        XCTAssertEqual(row["role"] as? String, "central")
        XCTAssertEqual(row["exchange_nonce"] as? String, hex)
        XCTAssertEqual(row["observed_duration"] as? Int, 120)
        XCTAssertEqual(row["session_flag"] as? Bool, true)
        XCTAssertEqual(row["is_final_evidence"] as? Bool, true)
        XCTAssertNil(row["upload_status"])
        XCTAssertNil(row["uploadStatus"])
        XCTAssertNil(row["prior_exchange_nonce"])
        try assertPair(row["start"], at: 1800000000)
        try assertPair(row["checkpoint"], at: 1800000120)
        let pending = try object(SubmitReceiptsParameters(receipts: [makeReceipt(checkpoint: true, prior: false, uploaded: false)]))
        // Upload status must not alter the wire evidence.
        let pendingRow = try XCTUnwrap((pending["receipts"] as? [[String: Any]])?.first)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: pendingRow, options: [.sortedKeys]))
        for value in [transfer as Any, transfer.receipts[0] as Any, transfer.receipts[0].start as Any] {
            XCTAssertTrue(String(reflecting: value).contains("<redacted>"))
            XCTAssertEqual(Mirror(reflecting: value).children.count, 0)
        }
    }

    func testSecondExchangeReceiptConversion() throws {
        let receipt = try makeReceipt(checkpoint: false, prior: true)
        let row = try object(ReceiptTransfer(receipt))
        XCTAssertEqual(row["prior_exchange_nonce"] as? String, peerHex)
        XCTAssertNil(row["checkpoint"])
        XCTAssertEqual(row["observed_duration"] as? Int, 120)
        try assertPair(row["start"], at: 1800000000)
        XCTAssertEqual(receipt.uploadStatus, .acceptedAsCandidate)
        let local = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any]
        XCTAssertNotNil(local?["uploadStatus"])
        XCTAssertNotNil(local?["exchangeNonce"] as? [Int])
    }

    func testReceiptRejectsInvalidDuration() throws {
        for duration in [-1.0, Double.infinity, Double.nan] {
            var receipt = try makeReceipt(checkpoint: false, prior: false)
            receipt.observedDuration = duration
            XCTAssertThrowsError(try ReceiptTransfer(receipt)) { XCTAssertEqual($0 as? WireValueError, .invalidSeconds) }
        }
    }

    func testBatchResponseConvertsAndRoundTrips() throws {
        let json = batchJSON(windows: [(1800000000, 1800000900), (1800000900, 1800001800)])
        let transfer = try JSONDecoder().decode(TokenBatchTransfer.self, from: Data(json.utf8))
        let batch = try transfer.domainBatch()
        XCTAssertEqual(transfer.batchID, testUserID)
        XCTAssertEqual(batch.windows.count, 2)
        XCTAssertEqual(batch.windows[0].token, try WireToken(hex: hex).token)
        XCTAssertEqual(batch.windows[0].validFrom, testNow)
        XCTAssertEqual(batch.windows[1].validUntil, testNow.addingTimeInterval(1800))
        let encoded = try JSONEncoder().encode(TokenBatchTransfer(batchID: testUserID, batch: batch))
        let decoded = try JSONDecoder().decode(TokenBatchTransfer.self, from: encoded)
        XCTAssertEqual(try decoded.domainBatch(), batch)
        let root = try object(transfer)
        XCTAssertEqual(Set(root.keys), ["batch_id", "windows"])
        let windows = try XCTUnwrap(root["windows"] as? [[String: Any]])
        XCTAssertEqual(windows[0]["token"] as? String, hex)
        XCTAssertEqual(windows[0]["valid_from"] as? Int, 1800000000)
        XCTAssertEqual(windows[0]["valid_until"] as? Int, 1800000900)
        for value in [transfer as Any, transfer.windows[0] as Any] {
            XCTAssertTrue(String(reflecting: value).contains("<redacted>"))
            XCTAssertEqual(Mirror(reflecting: value).children.count, 0)
        }
        let empty = try JSONDecoder().decode(TokenBatchTransfer.self, from: Data(batchJSON(windows: []).utf8))
        XCTAssertTrue(try empty.domainBatch().windows.isEmpty)
    }

    func testBatchRejectsNon900SecondUnalignedUnorderedAndOverlappingWindows() throws {
        let cases: [([(Int, Int)], any Error)] = [
            ([(1800000000, 1800000899)], TokenWindowError.invalidDuration),
            ([(1800000000, 1800000901)], TokenWindowError.invalidDuration),
            ([(1800000001, 1800000901)], WireValueError.unalignedWindow),
            ([(1800000900, 1800001800), (1800000000, 1800000900)], TokenWindowError.unorderedWindows),
            ([(1800000000, 1800000900), (1800000000, 1800000900)], TokenWindowError.overlappingWindows)
        ]
        for (windows, expected) in cases {
            let value = try JSONDecoder().decode(TokenBatchTransfer.self, from: Data(batchJSON(windows: windows).utf8))
            XCTAssertThrowsError(try value.domainBatch()) {
                XCTAssertEqual($0 as? TokenWindowError, expected as? TokenWindowError)
                XCTAssertEqual($0 as? WireValueError, expected as? WireValueError)
            }
        }
        let wrongHex = batchJSON(windows: [(1800000000, 1800000900)]).replacingOccurrences(of: hex, with: "invalid")
        XCTAssertThrowsError(try JSONDecoder().decode(TokenBatchTransfer.self, from: Data(wrongHex.utf8)))
    }

    func testAllFiveReceiptStatusesAndUnknownStatusRejection() throws {
        XCTAssertEqual(ReceiptStatus.allCases.count, 5)
        for status in ReceiptStatus.allCases {
            let json = "[{\"id\":\"\(testUserID.uuidString)\",\"status\":\"\(status.rawValue)\"}]"
            let decoded = try JSONDecoder().decode([ReceiptStatusTransfer].self, from: Data(json.utf8))
            XCTAssertEqual(decoded, [ReceiptStatusTransfer(id: testUserID, status: status)])
            XCTAssertEqual(status.isTerminal, status != .candidate)
            let encoded = try JSONEncoder().encode(decoded)
            XCTAssertEqual(try JSONDecoder().decode([ReceiptStatusTransfer].self, from: encoded), decoded)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ReceiptStatus.self, from: Data(#""unknown""#.utf8)))
    }

    func testMalformedMetadataCannotEchoSensitiveValuesInDecodingErrors() throws {
        let batch = batchJSON(windows: []).replacingOccurrences(of: testUserID.uuidString, with: hex)
        XCTAssertThrowsError(try JSONDecoder().decode(TokenBatchTransfer.self, from: Data(batch.utf8))) {
            XCTAssertEqual($0 as? WireValueError, .invalidResponse)
            XCTAssertFalse(String(reflecting: $0).contains(self.hex))
        }
        let status = "{\"id\":\"\(hex)\",\"status\":\"candidate\"}"
        XCTAssertThrowsError(try JSONDecoder().decode(ReceiptStatusTransfer.self, from: Data(status.utf8))) {
            XCTAssertEqual($0 as? WireValueError, .invalidResponse)
        }
        let invalidStatus = try JSONEncoder().encode(hex)
        XCTAssertThrowsError(try JSONDecoder().decode(ReceiptStatus.self, from: invalidStatus)) {
            XCTAssertEqual($0 as? WireValueError, .invalidResponse)
        }
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func makeReceipt(checkpoint: Bool, prior: Bool, uploaded: Bool = true) throws -> EncounterReceipt {
        let own = try WireToken(hex: hex).token
        let peer = try WireToken(hex: peerHex).token
        let start = ReceiptTokenPair(ownToken: own, peerToken: peer, observedAt: testNow.addingTimeInterval(0.75))
        let end = ReceiptTokenPair(ownToken: own, peerToken: peer, observedAt: testNow.addingTimeInterval(120.5))
        return EncounterReceipt(id: testUserID, role: .central, exchangeNonce: try WireNonce(hex: hex).nonce,
                                priorExchangeNonce: prior ? try WireNonce(hex: peerHex).nonce : nil,
                                start: start, checkpoint: checkpoint ? end : nil, observedDuration: 120.75,
                                sessionFlag: true, isFinalEvidence: true,
                                uploadStatus: uploaded ? .acceptedAsCandidate : .notYetUploaded)
    }

    private func assertPair(_ object: Any?, at seconds: Int) throws {
        let pair = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(Set(pair.keys), ["own_token", "peer_token", "observed_at"])
        XCTAssertEqual(pair["own_token"] as? String, hex)
        XCTAssertEqual(pair["peer_token"] as? String, peerHex)
        XCTAssertEqual(pair["observed_at"] as? Int, seconds)
    }

    private func batchJSON(windows: [(Int, Int)]) -> String {
        let rows = windows.map { "{\"token\":\"\(hex)\",\"valid_from\":\($0.0),\"valid_until\":\($0.1)}" }.joined(separator: ",")
        return "{\"batch_id\":\"\(testUserID.uuidString)\",\"windows\":[\(rows)]}"
    }
}
