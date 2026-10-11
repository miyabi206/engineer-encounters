import Foundation
import EncounterDomain

/// A continuous test clock: advancing it resumes waits without real sleeping.
public actor ManualEncounterClock: EncounterClock {
    private var time: EncounterTime
    private var waits: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
    public init(monotonic: TimeInterval = 0, wall: Date = EncounterSamples.observationTime) {
        time = EncounterTime(monotonic: monotonic, wall: wall)
    }
    public func now() -> EncounterTime { time }
    public func wait(until deadline: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if deadline <= time.monotonic { continuation.resume() }
                else { waits[id] = (deadline, continuation) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    /// Moves monotonic time forward and, independently if supplied, wall time.
    public func advance(by seconds: TimeInterval, wallBy: TimeInterval? = nil, deliverWakeUps: Bool = true) {
        precondition(seconds >= 0)
        time = EncounterTime(monotonic: time.monotonic + seconds, wall: time.wall.addingTimeInterval(wallBy ?? seconds))
        guard deliverWakeUps else { return }
        let ready = waits.filter { $0.value.0 <= time.monotonic }
        for (id, value) in ready { waits.removeValue(forKey: id); value.1.resume() }
    }
    /// Exposes pending waits for deterministic cancellation checks.
    public var pendingWaitCount: Int { waits.count }
    private func cancel(_ id: UUID) { waits.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
}

/// The caller owns session policy, including changes during an attempt.
public actor ManualSessionFlag {
    private var value: Bool
    public init(_ value: Bool = false) { self.value = value }
    public func set(_ value: Bool) { self.value = value }
    public func get() -> Bool { value }
}
