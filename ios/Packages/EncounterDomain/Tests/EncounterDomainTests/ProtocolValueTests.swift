import Foundation
import XCTest
import EncounterDomain
import EncounterDomainTestSupport

final class ProtocolValueTests: XCTestCase {
    func testFixedByteValidationIncludesCodable() throws {
        for count in [0, 15, 17, 64] {
            let bytes = [UInt8](repeating: 7, count: count)
            XCTAssertThrowsError(try TemporaryToken(bytes: bytes)) {
                XCTAssertEqual($0 as? FixedBytesError, .invalidLength(expected: 16, actual: count))
            }
            XCTAssertThrowsError(try ExchangeNonce(bytes: bytes)) {
                XCTAssertEqual($0 as? FixedBytesError, .invalidLength(expected: 16, actual: count))
            }
            let data = try JSONEncoder().encode(bytes)
            XCTAssertThrowsError(try JSONDecoder().decode(TemporaryToken.self, from: data))
            XCTAssertThrowsError(try JSONDecoder().decode(ExchangeNonce.self, from: data))
        }
        let token = EncounterSamples.token()
        let nonce = EncounterSamples.nonce()
        XCTAssertEqual(try JSONDecoder().decode(TemporaryToken.self, from: JSONEncoder().encode(token)), token)
        XCTAssertEqual(try JSONDecoder().decode(ExchangeNonce.self, from: JSONEncoder().encode(nonce)), nonce)
    }

    func testRandomGeneratorsAreInjectableAndDeterministic() {
        var first = SeededRandomNumberGenerator(seed: 42)
        var second = SeededRandomNumberGenerator(seed: 42)
        XCTAssertEqual(TemporaryToken(using: &first), TemporaryToken(using: &second))
        XCTAssertEqual(ExchangeNonce(using: &first), ExchangeNonce(using: &second))
        XCTAssertEqual(TemporaryToken().bytes.count, 16)
        XCTAssertEqual(ExchangeNonce().bytes.count, 16)
        XCTAssertNotEqual(EncounterSamples.token(seed: 1), EncounterSamples.token(seed: 2))
        var known = SeededRandomNumberGenerator(seed: 0)
        XCTAssertEqual(known.next(), 0xe220a8397b1dcdaf)
    }

    func testLoggingAndReflectionRedactBytes() throws {
        let token = try TemporaryToken(bytes: Array(UInt8(0)...UInt8(15)))
        let nonce = try ExchangeNonce(bytes: Array(UInt8(16)...UInt8(31)))
        XCTAssertEqual(String(describing: token), "TemporaryToken(<redacted>)")
        XCTAssertEqual(String(reflecting: token), "TemporaryToken(<redacted>)")
        XCTAssertEqual(String(describing: nonce), "ExchangeNonce(<redacted>)")
        XCTAssertEqual(String(reflecting: nonce), "ExchangeNonce(<redacted>)")
        XCTAssertTrue(Mirror(reflecting: token).children.isEmpty)
        XCTAssertTrue(Mirror(reflecting: nonce).children.isEmpty)
        var tokenDump = ""
        var nonceDump = ""
        dump(token, to: &tokenDump)
        dump(nonce, to: &nonceDump)
        XCTAssertFalse(tokenDump.contains("bytes"))
        XCTAssertFalse(nonceDump.contains("bytes"))
        XCTAssertTrue(tokenDump.contains("redacted"))
        XCTAssertTrue(nonceDump.contains("redacted"))
    }

    func testNonceDiagnosticIsShortSHA256Digest() throws {
        let zero = try ExchangeNonce(bytes: [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(zero.diagnosticDigest, "374708ff")
        XCTAssertEqual(EncounterSamples.nonce().diagnosticDigest.count, 8)
        XCTAssertNotEqual(EncounterSamples.nonce(seed: 1).diagnosticDigest,
                          EncounterSamples.nonce(seed: 2).diagnosticDigest)
    }
}
