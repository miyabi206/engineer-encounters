import Foundation

/// Samples wall time and continuous monotonic seconds together.
public struct EncounterTime: Sendable, Equatable {
    public let monotonic: TimeInterval
    public let wall: Date
    public init(monotonic: TimeInterval, wall: Date) { self.monotonic = monotonic; self.wall = wall }
}

/// Waits are cancellable; monotonic time must continue advancing during device sleep.
public protocol EncounterClock: Sendable {
    /// Returns caller-independent continuous time and the current wall time.
    func now() async -> EncounterTime
    /// Suspends until a monotonic deadline or throws when cancelled.
    func wait(until deadline: TimeInterval) async throws
}

/// ContinuousClock counts sleep time; Date is used only for token validity and receipts.
public struct SystemEncounterClock: EncounterClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    public init() { origin = clock.now }
    public func now() async -> EncounterTime {
        let components = origin.duration(to: clock.now).components
        return EncounterTime(monotonic: Double(components.seconds) + Double(components.attoseconds) / 1e18, wall: Date())
    }
    public func wait(until deadline: TimeInterval) async throws {
        try await clock.sleep(until: origin.advanced(by: .seconds(deadline)))
    }
}
