import Foundation
import CryptoKit

/// Frozen version-1 wire values and encounter timing limits, in seconds.
public enum EncounterProtocol {
    public static let serviceUUID = "7AEF0001-6B8D-4B71-9C13-95DCE08A26F0"
    public static let peripheralTokenCharacteristicUUID = "7AEF0002-6B8D-4B71-9C13-95DCE08A26F0"
    public static let centralTokenCharacteristicUUID = "7AEF0003-6B8D-4B71-9C13-95DCE08A26F0"
    public static let version: UInt8 = 1
    public static let tokenByteCount = 16
    public static let nonceByteCount = 16
    public static let maximumFrameByteCount = 64
    public static let ambientPresenceThreshold: TimeInterval = 120
    public static let tokenWindowDuration: TimeInterval = 15 * 60
    public static let batchCoverage: TimeInterval = 12 * 60 * 60
    public static let receiptLifetime: TimeInterval = 48 * 60 * 60
    public static let presenceAttemptLimit: TimeInterval = 5 * 60
    public static let connectTimeout: TimeInterval = 10
    public static let operationTimeout: TimeInterval = 5
    public static let activeConnectionLimit = 4
    public static let duplicateAttemptBackoff: TimeInterval = 10
}

/// Rejects token or nonce bytes that do not have the required fixed length.
public enum FixedBytesError: Error, Equatable, Sendable {
    case invalidLength(expected: Int, actual: Int)
}

/// A validated 16-byte temporary token; logging and reflection redact its bytes.
public struct TemporaryToken: Codable, Sendable, Equatable, Hashable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let bytes: [UInt8]

    /// Accepts only exactly 16 bytes.
    public init(bytes: [UInt8]) throws {
        guard bytes.count == EncounterProtocol.tokenByteCount else {
            throw FixedBytesError.invalidLength(expected: EncounterProtocol.tokenByteCount, actual: bytes.count)
        }
        self.bytes = bytes
    }

    /// Generates a token with the system's cryptographic random generator.
    public init() {
        var generator = SystemRandomNumberGenerator()
        self.init(using: &generator)
    }

    /// Allows deterministic generators in tests; production must use secure randomness.
    public init<R: RandomNumberGenerator>(using generator: inout R) {
        bytes = (0..<EncounterProtocol.tokenByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(bytes: decoder.singleValueContainer().decode([UInt8].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }

    public var description: String { "TemporaryToken(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A validated 16-byte exchange nonce; logging and reflection redact its bytes.
public struct ExchangeNonce: Codable, Sendable, Equatable, Hashable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let bytes: [UInt8]

    /// Accepts only exactly 16 bytes.
    public init(bytes: [UInt8]) throws {
        guard bytes.count == EncounterProtocol.nonceByteCount else {
            throw FixedBytesError.invalidLength(expected: EncounterProtocol.nonceByteCount, actual: bytes.count)
        }
        self.bytes = bytes
    }

    /// Generates a nonce with the system's cryptographic random generator.
    public init() {
        var generator = SystemRandomNumberGenerator()
        self.init(using: &generator)
    }

    /// Allows deterministic generators in tests; production must use secure randomness.
    public init<R: RandomNumberGenerator>(using generator: inout R) {
        bytes = (0..<EncounterProtocol.nonceByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(bytes: decoder.singleValueContainer().decode([UInt8].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }

    /// First eight hexadecimal SHA-256 characters; never exposes nonce bytes.
    public var diagnosticDigest: String {
        SHA256.hash(data: Data(bytes)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { "ExchangeNonce(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
