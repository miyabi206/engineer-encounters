import Foundation
import EncounterDomain

/// Repeatable SplitMix64 randomness for tests only, never production token issuance.
public struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

/// Deterministic synthetic evidence shared by domain and storage tests.
public enum EncounterSamples {
    public static let observationTime = Date(timeIntervalSince1970: 1_800_000_000)

    /// The same seed always yields the same validated token.
    public static func token(seed: UInt64 = 1) -> TemporaryToken {
        var generator = SeededRandomNumberGenerator(seed: seed)
        return TemporaryToken(using: &generator)
    }

    /// The same seed always yields the same validated nonce.
    public static func nonce(seed: UInt64 = 2) -> ExchangeNonce {
        var generator = SeededRandomNumberGenerator(seed: seed)
        return ExchangeNonce(using: &generator)
    }

    /// Builds contiguous windows; the default 48 windows cover exactly 12 hours.
    public static func batch(start: Date = observationTime, count: Int = 48) throws -> TokenBatch {
        let windows = try (0..<max(0, count)).map { index in
            let from = start.addingTimeInterval(Double(index) * EncounterProtocol.tokenWindowDuration)
            return try TokenWindow(token: token(seed: UInt64(index)), validFrom: from,
                                   validUntil: from.addingTimeInterval(EncounterProtocol.tokenWindowDuration))
        }
        return try TokenBatch(windows: windows)
    }

    /// Provides distinct stable identities and original evidence for numbered fixtures.
    public static func receipt(_ index: Int = 1, observedAt: Date = observationTime) -> EncounterReceipt {
        let seed = UInt64(bitPattern: Int64(index))
        let identity = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", seed & 0xffffffffffff))!
        return EncounterReceipt(id: identity, role: .central, exchangeNonce: nonce(seed: seed),
                                start: ReceiptTokenPair(ownToken: token(seed: seed),
                                                        peerToken: token(seed: seed &+ 100), observedAt: observedAt))
    }
}
