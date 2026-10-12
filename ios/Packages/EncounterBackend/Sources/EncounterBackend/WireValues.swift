import Foundation
import EncounterDomain

/// Validates the backend's fixed-length hexadecimal and integer-second format.
public enum WireValueError: Error, Equatable, Sendable {
    case invalidHexLength(expected: Int, actual: Int)
    case invalidHex
    case invalidSeconds
    case invalidResponse
    case unalignedWindow
}

private enum Hex {
    static func encode(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func decode(_ value: String, count: Int) throws -> [UInt8] {
        let characters = Array(value.utf8)
        guard characters.count == count * 2 else {
            throw WireValueError.invalidHexLength(expected: count * 2, actual: characters.count)
        }
        func nibble(_ character: UInt8) throws -> UInt8 {
            switch character {
            case 48...57: return character - 48
            case 97...102: return character - 97 + 10
            default: throw WireValueError.invalidHex
            }
        }
        return try stride(from: 0, to: characters.count, by: 2).map {
            try nibble(characters[$0]) * 16 + nibble(characters[$0 + 1])
        }
    }
}

/// A temporary token encoded as 32 lowercase hexadecimal characters.
public struct WireToken: Codable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let token: TemporaryToken
    public init(_ token: TemporaryToken) { self.token = token }
    public init(hex: String) throws { token = try TemporaryToken(bytes: Hex.decode(hex, count: EncounterProtocol.tokenByteCount)) }

    public init(from decoder: any Decoder) throws {
        let value: String
        do { value = try decoder.singleValueContainer().decode(String.self) }
        catch { throw WireValueError.invalidResponse }
        try self.init(hex: value)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Hex.encode(token.bytes))
    }
    public var description: String { "WireToken(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// An exchange nonce encoded as 32 lowercase hexadecimal characters.
public struct WireNonce: Codable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let nonce: ExchangeNonce
    public init(_ nonce: ExchangeNonce) { self.nonce = nonce }
    public init(hex: String) throws { nonce = try ExchangeNonce(bytes: Hex.decode(hex, count: EncounterProtocol.nonceByteCount)) }

    public init(from decoder: any Decoder) throws {
        let value: String
        do { value = try decoder.singleValueContainer().decode(String.self) }
        catch { throw WireValueError.invalidResponse }
        try self.init(hex: value)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Hex.encode(nonce.bytes))
    }
    public var description: String { "WireNonce(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Whole Unix seconds; fractional dates are rounded down, including before the epoch.
public struct WireSeconds: Codable, Sendable, Equatable {
    public let unixSeconds: Int64
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(unixSeconds)) }

    public init(_ date: Date) throws {
        let seconds = floor(date.timeIntervalSince1970)
        guard seconds.isFinite, abs(seconds) < 9_007_199_254_740_992 else { throw WireValueError.invalidSeconds }
        unixSeconds = Int64(seconds)
    }
    public init(unixSeconds: Int64) throws {
        guard unixSeconds > -9_007_199_254_740_992, unixSeconds < 9_007_199_254_740_992 else {
            throw WireValueError.invalidSeconds
        }
        self.unixSeconds = unixSeconds
    }
    public init(from decoder: any Decoder) throws {
        let value: Int64
        do { value = try decoder.singleValueContainer().decode(Int64.self) }
        catch { throw WireValueError.invalidSeconds }
        try self.init(unixSeconds: value)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(unixSeconds)
    }
}

/// A token pair in the receipt upload format.
public struct ReceiptTokenPairTransfer: Encodable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let ownToken: WireToken
    public let peerToken: WireToken
    public let observedAt: WireSeconds

    public init(_ pair: ReceiptTokenPair) throws {
        ownToken = WireToken(pair.ownToken)
        peerToken = WireToken(pair.peerToken)
        observedAt = try WireSeconds(pair.observedAt)
    }
    private enum CodingKeys: String, CodingKey {
        case ownToken = "own_token", peerToken = "peer_token", observedAt = "observed_at"
    }
    public var description: String { "ReceiptTokenPairTransfer(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Receipt evidence for submit_receipts, excluding local upload status.
public struct ReceiptTransfer: Encodable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let id: UUID
    public let protocolVersion: UInt8
    public let role: ExchangeRole
    public let exchangeNonce: WireNonce
    public let priorExchangeNonce: WireNonce?
    public let start: ReceiptTokenPairTransfer
    public let checkpoint: ReceiptTokenPairTransfer?
    public let observedDuration: Int64
    public let sessionFlag: Bool
    public let isFinalEvidence: Bool

    public init(_ receipt: EncounterReceipt) throws {
        id = receipt.id
        protocolVersion = receipt.protocolVersion
        role = receipt.role
        exchangeNonce = WireNonce(receipt.exchangeNonce)
        priorExchangeNonce = receipt.priorExchangeNonce.map(WireNonce.init)
        start = try ReceiptTokenPairTransfer(receipt.start)
        checkpoint = try receipt.checkpoint.map(ReceiptTokenPairTransfer.init)
        let seconds = floor(receipt.observedDuration)
        guard seconds.isFinite, seconds >= 0, seconds < 9_007_199_254_740_992 else { throw WireValueError.invalidSeconds }
        observedDuration = Int64(seconds)
        sessionFlag = receipt.sessionFlag
        isFinalEvidence = receipt.isFinalEvidence
    }
    private enum CodingKeys: String, CodingKey {
        case id, role, start, checkpoint
        case protocolVersion = "protocol_version", exchangeNonce = "exchange_nonce"
        case priorExchangeNonce = "prior_exchange_nonce", observedDuration = "observed_duration"
        case sessionFlag = "session_flag", isFinalEvidence = "is_final_evidence"
    }
    public var description: String { "ReceiptTransfer(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Named JSON parameters for submit_receipts.
public struct SubmitReceiptsParameters: Encodable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let receipts: [ReceiptTransfer]
    public init(receipts: [EncounterReceipt]) throws { self.receipts = try receipts.map(ReceiptTransfer.init) }
    public var description: String { "SubmitReceiptsParameters(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The five server statuses; only a candidate needs another upload.
public enum ReceiptStatus: String, Codable, Sendable, CaseIterable {
    case candidate, resolved, consumed, rejected, expired
    public var isTerminal: Bool { self != .candidate }

    public init(from decoder: any Decoder) throws {
        do {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let status = Self(rawValue: raw) else { throw WireValueError.invalidResponse }
            self = status
        } catch { throw WireValueError.invalidResponse }
    }
}

/// Status acknowledgement in the same order as the submitted receipt identities.
public struct ReceiptStatusTransfer: Codable, Sendable, Equatable {
    public let id: UUID
    public let status: ReceiptStatus
    public init(id: UUID, status: ReceiptStatus) { self.id = id; self.status = status }

    private enum CodingKeys: String, CodingKey { case id, status }
    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            status = try container.decode(ReceiptStatus.self, forKey: .status)
        } catch { throw WireValueError.invalidResponse }
    }
}

/// One wire token window, validated on conversion into the domain.
public struct TokenWindowTransfer: Codable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let token: WireToken
    public let validFrom: WireSeconds
    public let validUntil: WireSeconds

    public init(_ window: TokenWindow) throws {
        token = WireToken(window.token)
        validFrom = try WireSeconds(window.validFrom)
        validUntil = try WireSeconds(window.validUntil)
    }
    private enum CodingKeys: String, CodingKey {
        case token, validFrom = "valid_from", validUntil = "valid_until"
    }
    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            token = try container.decode(WireToken.self, forKey: .token)
            validFrom = try container.decode(WireSeconds.self, forKey: .validFrom)
            validUntil = try container.decode(WireSeconds.self, forKey: .validUntil)
        } catch let error as WireValueError { throw error }
        catch { throw WireValueError.invalidResponse }
    }
    public func domainWindow() throws -> TokenWindow {
        guard validFrom.unixSeconds % 900 == 0 else { throw WireValueError.unalignedWindow }
        return try TokenWindow(token: token.token, validFrom: validFrom.date, validUntil: validUntil.date)
    }
    public var description: String { "TokenWindowTransfer(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// issue_token_batch response with a validated conversion to ordered domain windows.
public struct TokenBatchTransfer: Codable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let batchID: UUID
    public let windows: [TokenWindowTransfer]

    public init(batchID: UUID, batch: TokenBatch) throws {
        self.batchID = batchID
        windows = try batch.windows.map(TokenWindowTransfer.init)
    }
    private enum CodingKeys: String, CodingKey { case batchID = "batch_id", windows }
    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            batchID = try container.decode(UUID.self, forKey: .batchID)
            windows = try container.decode([TokenWindowTransfer].self, forKey: .windows)
        } catch let error as WireValueError { throw error }
        catch { throw WireValueError.invalidResponse }
    }
    public func domainBatch() throws -> TokenBatch { try TokenBatch(windows: windows.map { try $0.domainWindow() }) }
    public var description: String { "TokenBatchTransfer(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
