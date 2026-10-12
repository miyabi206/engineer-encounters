import Foundation

public enum SessionState: Equatable, Sendable {
    case none, starting, active(endsAt: Date), stopping, startRefusedOffline, failed
}

public enum SessionActionError: Error, Equatable, Sendable {
    case offline, unavailable
}

/// All durations use the caller's clock. There are no encounter timestamps here.
public enum SessionCountdown {
    public static func seconds(until end: Date, now: Date) -> Int {
        let remaining = end.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return Int(min(remaining.rounded(.up), Double(Int.max / 2)))
    }

    public static func text(seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

/// Pure lifecycle rules, including the latch that prevents a stale refresh from undoing a stop.
public struct SessionLifecycle: Equatable, Sendable {
    public private(set) var state: SessionState
    public private(set) var hasEnded = false
    public private(set) var stopPending = false
    public private(set) var stopFailed = false

    public init(state: SessionState = .none, now: Date) {
        self.state = state
        if state == .stopping { stopPending = true; hasEnded = true }
        expire(now: now)
    }

    public var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    @discardableResult
    public mutating func beginStart() -> Bool {
        guard !isActive, state != .starting, !stopPending else { return false }
        hasEnded = false; stopFailed = false; state = .starting
        return true
    }

    public mutating func acknowledgeStart(endsAt: Date, now: Date) {
        guard state == .starting else { return }
        state = .active(endsAt: endsAt)
        expire(now: now)
    }

    public mutating func failStart(offline: Bool) {
        guard state == .starting else { return }
        state = offline ? .startRefusedOffline : .failed
    }

    @discardableResult
    public mutating func stopLocally() -> Bool {
        guard isActive else { return false }
        hasEnded = true; stopPending = true; stopFailed = false; state = .stopping
        return true
    }

    public mutating func finishStop(succeeded: Bool) {
        guard stopPending else { return }
        state = .none; hasEnded = true; stopFailed = !succeeded; stopPending = !succeeded
    }

    public mutating func expire(now: Date) {
        guard case let .active(end) = state, end <= now else { return }
        state = .none; hasEnded = true
    }

    public mutating func receive(_ state: SessionState, now: Date) {
        guard !hasEnded, !stopPending, self.state != .starting else { return }
        self.state = state
        if state == .stopping { hasEnded = true; stopPending = true }
        expire(now: now)
    }
}

/// The adapter owns server acknowledgement, prerequisites and the durable stop queue.
@MainActor
public struct SessionActions {
    public var startSession: @MainActor () async throws -> Date
    public var stopSession: @MainActor () async throws -> Void
    public var refreshSession: @MainActor () async throws -> SessionState

    public init(startSession: @escaping @MainActor () async throws -> Date,
                stopSession: @escaping @MainActor () async throws -> Void,
                refreshSession: @escaping @MainActor () async throws -> SessionState) {
        self.startSession = startSession; self.stopSession = stopSession; self.refreshSession = refreshSession
    }
}

@MainActor
public struct SessionNavigationActions {
    public var openQR: @MainActor () -> Void
    public var openEncounter: @MainActor (String) -> Void
    public var close: @MainActor () -> Void

    public init(openQR: @escaping @MainActor () -> Void,
                openEncounter: @escaping @MainActor (String) -> Void,
                close: @escaping @MainActor () -> Void) {
        self.openQR = openQR; self.openEncounter = openEncounter; self.close = close
    }
}
