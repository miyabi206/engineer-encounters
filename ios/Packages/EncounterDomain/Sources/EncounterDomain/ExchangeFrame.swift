import Foundation

/// Wire phase values are frozen for version 1.
public enum ExchangePhase: UInt8, Codable, Sendable, CaseIterable {
    case initialExchange = 0x01
    case heldConnectionCheckpoint = 0x02
    case reconnectEvidence = 0x03
}

/// Distinct failures for the bound, layout, version, phase and prior-nonce rule.
public enum ExchangeFrameError: Error, Equatable, Sendable {
    case frameTooLarge(actual: Int)
    case malformedLength(actual: Int)
    case unknownVersion(UInt8)
    case invalidPhase(UInt8)
    case priorNonceNotAllowed
}

/// Version-1 layout: byte 0 = 0x01; byte 1 = phase (0x01 initial,
/// 0x02 held checkpoint, 0x03 reconnect); bytes 2–17 = token; bytes 18–33
/// = exchange nonce. Optional bytes 34–49 = original presence-attempt nonce,
/// permitted only for reconnect. Valid lengths are 34 or 50 bytes; the 64-byte
/// bound is checked first. Nonce freshness belongs to exchange validation.
public struct ExchangeFrame: Sendable, Equatable {
    public let phase: ExchangePhase
    public let token: TemporaryToken
    public let nonce: ExchangeNonce
    public let priorNonce: ExchangeNonce?

    /// Rejects a prior nonce unless this is reconnect evidence.
    public init(phase: ExchangePhase, token: TemporaryToken, nonce: ExchangeNonce,
                priorNonce: ExchangeNonce? = nil) throws {
        guard priorNonce == nil || phase == .reconnectEvidence else {
            throw ExchangeFrameError.priorNonceNotAllowed
        }
        self.phase = phase
        self.token = token
        self.nonce = nonce
        self.priorNonce = priorNonce
    }

    /// Encodes the immutable frame using the frozen version-1 layout.
    public func encoded() -> Data {
        var bytes = [EncounterProtocol.version, phase.rawValue] + token.bytes + nonce.bytes
        if let priorNonce { bytes += priorNonce.bytes }
        return Data(bytes)
    }

    /// Validates the bound before inspecting any header or length fields.
    public static func decode(_ data: Data) throws -> Self {
        let count = data.count
        guard count <= EncounterProtocol.maximumFrameByteCount else {
            throw ExchangeFrameError.frameTooLarge(actual: count)
        }
        let baseLength = 2 + EncounterProtocol.tokenByteCount + EncounterProtocol.nonceByteCount
        guard count == baseLength || count == baseLength + EncounterProtocol.nonceByteCount else {
            throw ExchangeFrameError.malformedLength(actual: count)
        }
        let bytes = Array(data)
        guard bytes[0] == EncounterProtocol.version else {
            throw ExchangeFrameError.unknownVersion(bytes[0])
        }
        guard let phase = ExchangePhase(rawValue: bytes[1]) else {
            throw ExchangeFrameError.invalidPhase(bytes[1])
        }
        return try Self(phase: phase,
                        token: TemporaryToken(bytes: Array(bytes[2..<18])),
                        nonce: ExchangeNonce(bytes: Array(bytes[18..<34])),
                        priorNonce: count == baseLength ? nil : ExchangeNonce(bytes: Array(bytes[34..<50])))
    }
}
