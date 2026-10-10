import Foundation

/// Rejects windows that violate duration, ordering or non-overlap rules.
public enum TokenWindowError: Error, Equatable, Sendable {
    case invalidDuration
    case unorderedWindows
    case overlappingWindows
}

/// A token valid for exactly 15 minutes in the half-open interval [from, until).
public struct TokenWindow: Codable, Sendable, Equatable {
    public let token: TemporaryToken
    public let validFrom: Date
    public let validUntil: Date

    /// Rejects any interval whose length is not exactly 15 minutes.
    public init(token: TemporaryToken, validFrom: Date, validUntil: Date) throws {
        guard validUntil.timeIntervalSince(validFrom) == EncounterProtocol.tokenWindowDuration else {
            throw TokenWindowError.invalidDuration
        }
        self.token = token
        self.validFrom = validFrom
        self.validUntil = validUntil
    }

    /// The start is inclusive and the end is exclusive.
    public func contains(_ time: Date) -> Bool { validFrom <= time && time < validUntil }

    private enum CodingKeys: String, CodingKey { case token, validFrom, validUntil }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(token: container.decode(TemporaryToken.self, forKey: .token),
                      validFrom: container.decode(Date.self, forKey: .validFrom),
                      validUntil: container.decode(Date.self, forKey: .validUntil))
    }
}

/// An ordered, non-overlapping batch; gaps intentionally provide no token.
public struct TokenBatch: Codable, Sendable, Equatable {
    public let windows: [TokenWindow]

    /// Rejects unsorted or overlapping windows without silently rearranging them.
    public init(windows: [TokenWindow]) throws {
        for (previous, next) in zip(windows, windows.dropFirst()) {
            guard previous.validFrom <= next.validFrom else { throw TokenWindowError.unorderedWindows }
            guard previous.validUntil <= next.validFrom else { throw TokenWindowError.overlappingWindows }
        }
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey { case windows }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(windows: container.decode([TokenWindow].self, forKey: .windows))
    }
}

/// Replaceable batch storage; implementations propagate failed reads and writes.
public protocol TokenBatchStore: Sendable {
    /// Returns the stored batch, or nil when no batch exists.
    func load() async throws -> TokenBatch?
    /// Returns after the replacement batch has been stored.
    func save(_ batch: TokenBatch) async throws
    /// Removes all token material on sign-out or reset.
    func clear() async throws
}

/// Actor-isolated batch storage for portable tests and ephemeral use.
public actor InMemoryTokenBatchStore: TokenBatchStore {
    private var batch: TokenBatch?

    public init(batch: TokenBatch? = nil) { self.batch = batch }
    public func load() async throws -> TokenBatch? { batch }
    public func save(_ batch: TokenBatch) async throws { self.batch = batch }
    public func clear() async throws { batch = nil }
}

/// Selects from stored windows using caller-supplied wall time, without timers.
public struct TokenProvider: Sendable {
    private let store: any TokenBatchStore

    public init(store: any TokenBatchStore) { self.store = store }

    /// Prunes expired windows before returning a current token; never extends validity.
    public func token(at wallTime: Date) async throws -> TemporaryToken? {
        guard let batch = try await store.load() else { return nil }
        let retained = batch.windows.filter { $0.validUntil > wallTime }
        if retained.count != batch.windows.count {
            if retained.isEmpty {
                try await store.clear()
            } else {
                try await store.save(TokenBatch(windows: retained))
            }
        }
        return retained.first { $0.contains(wallTime) }?.token
    }
}
