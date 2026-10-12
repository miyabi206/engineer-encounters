import Combine
import Foundation

@MainActor
public final class SessionModel: ObservableObject {
    @Published public private(set) var lifecycle: SessionLifecycle
    @Published public private(set) var remainingSeconds = 0
    @Published public private(set) var refreshFailed = false
    private let actions: SessionActions
    private let now: @MainActor () -> Date
    private var revision = 0
    private var refreshing = false
    private var syncingStop = false

    public init(state: SessionState = .none, actions: SessionActions,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.actions = actions; self.now = now
        lifecycle = SessionLifecycle(state: state, now: now())
        tick()
    }

    public var state: SessionState { lifecycle.state }
    public var isActive: Bool { lifecycle.isActive }

    public func tick() {
        lifecycle.expire(now: now())
        if case let .active(end) = state {
            remainingSeconds = SessionCountdown.seconds(until: end, now: now())
        } else { remainingSeconds = 0 }
    }

    public func start() async {
        guard lifecycle.beginStart() else { return }
        revision += 1; refreshFailed = false
        do { lifecycle.acknowledgeStart(endsAt: try await actions.startSession(), now: now()) }
        catch { lifecycle.failStart(offline: (error as? SessionActionError) == .offline) }
        tick()
    }

    /// Call synchronously before navigating away. A failed upload can never restore activity.
    @discardableResult
    public func stopLocally() -> Bool {
        guard lifecycle.stopLocally() else { return false }
        revision += 1; refreshFailed = false; tick()
        return true
    }

    public func synchronizeStop() async {
        guard lifecycle.stopPending, !syncingStop else { return }
        syncingStop = true
        defer { syncingStop = false }
        do { try await actions.stopSession(); lifecycle.finishStop(succeeded: true) }
        catch { lifecycle.finishStop(succeeded: false) }
    }

    public func refresh() async {
        tick()
        if lifecycle.stopPending { await synchronizeStop(); return }
        guard !refreshing, !lifecycle.hasEnded, state != .starting else { return }
        refreshing = true
        let requestRevision = revision
        defer { refreshing = false }
        do {
            let response = try await actions.refreshSession()
            guard revision == requestRevision else { return }
            refreshFailed = false; lifecycle.receive(response, now: now()); tick()
        } catch {
            if revision == requestRevision { refreshFailed = true }
        }
    }

    public func retry() async {
        if lifecycle.stopPending { await synchronizeStop() }
        else if refreshFailed { await refresh() }
        else { await start() }
    }
}
