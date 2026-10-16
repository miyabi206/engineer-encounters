import Combine
import Foundation

@MainActor
public final class SessionModel: ObservableObject {
    @Published public private(set) var lifecycle: SessionLifecycle
    @Published public private(set) var remainingSeconds = 0
    @Published public private(set) var refreshFailed = false
    private let actions: SessionActions
    private let monotonicNow: @MainActor () -> TimeInterval
    private let openDiscoveryOff: @MainActor () -> Void
    private var acknowledgedAt: TimeInterval
    private var serverTime: Date
    private var revision = 0
    private var refreshing = false
    private var syncingStop = false

    public init(state: SessionState = .none, actions: SessionActions, navigation: SessionNavigationActions,
                monotonicNow: @escaping @MainActor () -> TimeInterval = { SessionMonotonicClock.now() }) {
        self.actions = actions; self.monotonicNow = monotonicNow; self.openDiscoveryOff = navigation.openDiscoveryOff
        acknowledgedAt = monotonicNow()
        if case let .active(session) = state { serverTime = session.serverTime }
        else { serverTime = Date(timeIntervalSince1970: 0) }
        lifecycle = SessionLifecycle(state: state, now: serverTime)
        tick()
    }

    public var state: SessionState { lifecycle.state }
    public var isActive: Bool { lifecycle.isActive }

    private var estimatedServerTime: Date {
        serverTime.addingTimeInterval(max(0, monotonicNow() - acknowledgedAt))
    }
    private func anchor(_ response: SessionState) {
        if case let .active(session) = response {
            serverTime = session.serverTime; acknowledgedAt = monotonicNow()
        }
    }
    private func routePrerequisite(_ error: Error) {
        if case let .prerequisiteMissing(details) = error as? SessionActionError, details.contains("discovery") {
            openDiscoveryOff()
        }
    }

    public func tick() {
        let now = estimatedServerTime
        var updatedLifecycle = lifecycle
        updatedLifecycle.expire(now: now)
        if updatedLifecycle != lifecycle { lifecycle = updatedLifecycle }
        let remaining: Int
        if case let .active(session) = updatedLifecycle.state {
            remaining = SessionCountdown.seconds(until: session.expiresAt, now: now)
        } else { remaining = 0 }
        if remaining != remainingSeconds { remainingSeconds = remaining }
    }

    public func start() async {
        guard lifecycle.beginStart() else { return }
        revision += 1; refreshFailed = false
        do {
            let session = try await actions.startSession()
            anchor(.active(session))
            lifecycle.acknowledgeStart(session, now: estimatedServerTime)
        } catch {
            lifecycle.failStart(offline: (error as? SessionActionError) == .offline)
            routePrerequisite(error)
        }
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
        guard !refreshing, state != .starting else { return }
        refreshing = true
        let requestRevision = revision
        defer { refreshing = false }
        do {
            let response = try await actions.refreshSession()
            guard revision == requestRevision else { return }
            refreshFailed = false; anchor(response); lifecycle.receive(response, now: estimatedServerTime); tick()
        } catch {
            if revision == requestRevision { refreshFailed = true; routePrerequisite(error) }
        }
    }

    public func retry() async {
        if lifecycle.stopPending { await synchronizeStop() }
        else if refreshFailed { await refresh() }
        else { await start() }
    }
}
