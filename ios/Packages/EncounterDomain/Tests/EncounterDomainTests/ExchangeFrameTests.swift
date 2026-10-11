import Foundation
import XCTest
import EncounterDomain
import EncounterDomainTestSupport

final class ExchangeFrameTests: XCTestCase {
    func testFrozenConstants() {
        XCTAssertEqual(EncounterProtocol.serviceUUID, "7AEF0001-6B8D-4B71-9C13-95DCE08A26F0")
        XCTAssertEqual(EncounterProtocol.peripheralTokenCharacteristicUUID, "7AEF0002-6B8D-4B71-9C13-95DCE08A26F0")
        XCTAssertEqual(EncounterProtocol.centralTokenCharacteristicUUID, "7AEF0003-6B8D-4B71-9C13-95DCE08A26F0")
        XCTAssertEqual(EncounterProtocol.version, 1)
        XCTAssertEqual(EncounterProtocol.tokenByteCount, 16)
        XCTAssertEqual(EncounterProtocol.nonceByteCount, 16)
        XCTAssertEqual(EncounterProtocol.maximumFrameByteCount, 64)
        XCTAssertEqual(EncounterProtocol.ambientPresenceThreshold, 120)
        XCTAssertEqual(EncounterProtocol.tokenWindowDuration, 900)
        XCTAssertEqual(EncounterProtocol.batchCoverage, 43_200)
        XCTAssertEqual(EncounterProtocol.receiptLifetime, 172_800)
        XCTAssertEqual(EncounterProtocol.presenceAttemptLimit, 300)
        XCTAssertEqual(EncounterProtocol.connectTimeout, 10)
        XCTAssertEqual(EncounterProtocol.operationTimeout, 5)
        XCTAssertEqual(EncounterProtocol.activeConnectionLimit, 4)
        XCTAssertEqual(EncounterProtocol.duplicateAttemptBackoff, 10)
    }

    func testEveryValidLayoutAgainstIndependentWireBytes() throws {
        let tokenBytes = Array(UInt8(0)...UInt8(15))
        let nonceBytes = Array(UInt8(16)...UInt8(31))
        let priorBytes = Array(UInt8(32)...UInt8(47))
        for phase in ExchangePhase.allCases {
            for includePrior in [false, true] where !includePrior || phase == .reconnectEvidence {
                let expected = Data([1, phase.rawValue] + tokenBytes + nonceBytes + (includePrior ? priorBytes : []))
                let frame = try ExchangeFrame(phase: phase, token: TemporaryToken(bytes: tokenBytes),
                                              nonce: ExchangeNonce(bytes: nonceBytes),
                                              priorNonce: includePrior ? ExchangeNonce(bytes: priorBytes) : nil)
                XCTAssertEqual(frame.encoded(), expected)
                XCTAssertEqual(try ExchangeFrame.decode(expected), frame)
                XCTAssertEqual(try ExchangeFrame.decode(expected).encoded(), expected)
            }
        }
    }

    func testArbitraryPayloadsRoundTrip() throws {
        var generator = SeededRandomNumberGenerator(seed: 99)
        for _ in 0..<64 {
            for phase in ExchangePhase.allCases {
                let token = TemporaryToken(using: &generator)
                let nonce = ExchangeNonce(using: &generator)
                let frame = try ExchangeFrame(phase: phase, token: token, nonce: nonce)
                XCTAssertEqual(try ExchangeFrame.decode(frame.encoded()), frame)
                if phase == .reconnectEvidence {
                    let reconnect = try ExchangeFrame(phase: phase, token: token, nonce: nonce,
                                                       priorNonce: ExchangeNonce(using: &generator))
                    XCTAssertEqual(try ExchangeFrame.decode(reconnect.encoded()), reconnect)
                }
            }
        }
    }

    func testBoundPrecedesAllOtherValidation() {
        assertDecodeError(Data(repeating: 255, count: 65), .frameTooLarge(actual: 65))
        assertDecodeError(Data(repeating: 255, count: 100), .frameTooLarge(actual: 100))
    }

    func testEveryMalformedLengthWithinBound() {
        for length in 0...64 where length != 34 && length != 50 {
            assertDecodeError(Data(repeating: 1, count: length), .malformedLength(actual: length))
        }
    }

    func testEveryUnknownVersionAndInvalidPhase() {
        for version in UInt8.min...UInt8.max where version != 1 {
            var bytes = [UInt8](repeating: 0, count: 34)
            bytes[0] = version
            bytes[1] = 1
            assertDecodeError(Data(bytes), .unknownVersion(version))
        }
        for phase in UInt8.min...UInt8.max where !(1...3).contains(phase) {
            var bytes = [UInt8](repeating: 0, count: 34)
            bytes[0] = 1
            bytes[1] = phase
            assertDecodeError(Data(bytes), .invalidPhase(phase))
        }
    }

    func testPriorNonceRejectedForBothNonReconnectPhases() {
        for phase in [ExchangePhase.initialExchange, .heldConnectionCheckpoint] {
            XCTAssertThrowsError(try ExchangeFrame(phase: phase, token: EncounterSamples.token(),
                                                   nonce: EncounterSamples.nonce(), priorNonce: EncounterSamples.nonce(seed: 4))) {
                XCTAssertEqual($0 as? ExchangeFrameError, .priorNonceNotAllowed)
            }
            assertDecodeError(Data([1, phase.rawValue] + [UInt8](repeating: 0, count: 48)), .priorNonceNotAllowed)
        }
    }

    private func assertDecodeError(_ data: Data, _ expected: ExchangeFrameError,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ExchangeFrame.decode(data), file: file, line: line) {
            XCTAssertEqual($0 as? ExchangeFrameError, expected, file: file, line: line)
        }
    }
}
