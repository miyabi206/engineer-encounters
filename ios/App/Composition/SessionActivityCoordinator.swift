import ActivityKit
import Combine
import EncounterUI
import Foundation

struct SessionActivityPayload: Equatable, Sendable {
    let sessionID: String
    let content: SessionActivityAttributes.ContentState

    static func select(snapshot: SessionHolder.Snapshot, displayName: String) -> Self? {
        guard case .active(let session) = snapshot.state, !snapshot.stopPending,
              let end = snapshot.activityEndsAt else { return nil }
        return Self(sessionID: session.sessionID,
            content: .init(displayName: displayName, endsAt: end, isActive: true))
    }
}

@MainActor
protocol SessionActivityControlling {
    func apply(_ payload: SessionActivityPayload?) async
}

@MainActor
struct NoSessionActivityController: SessionActivityControlling {
    func apply(_ payload: SessionActivityPayload?) async {}
}

/// Serializes ActivityKit effects; an obsolete update cannot run after an end.
@MainActor
final class SessionActivityCoordinator: ObservableObject {
    @Published private(set) var payload: SessionActivityPayload?
    private let controller: any SessionActivityControlling
    private var received = false
    private var pending: Task<Void, Never>?
    private var lastDisplayName = ""

    init(controller: any SessionActivityControlling) { self.controller = controller }

    func receive(_ snapshot: SessionHolder.Snapshot, displayName: String, isCurrent: Bool = true,
                 awaitingReconciliation: Bool = false) {
        if isCurrent, !displayName.isEmpty { lastDisplayName = displayName }
        let next = isCurrent ? SessionActivityPayload.select(snapshot: snapshot, displayName: lastDisplayName) : nil
        // Process restoration owns no claim, but cannot decide a surviving activity yet.
        if awaitingReconciliation, next == nil, !snapshot.stopPending { return }
        if next == nil { lastDisplayName = "" }
        // A disabled or failed Activity.request is retried on the next holder update.
        guard !received || payload != next || next != nil else { return }
        enqueue(next)
    }

    func end() {
        lastDisplayName = ""
        enqueue(nil)
    }

    private func enqueue(_ next: SessionActivityPayload?) {
        received = true; payload = next
        let previous = pending, controller = controller
        pending = Task {
            await previous?.value
            await controller.apply(next)
        }
    }

    func flush() async { await pending?.value }
}

/// Only the production singleton uses this controller. Hosted composition tests
/// use an injected fake (or the no-op default), never the system's activities.
@MainActor
final class SystemSessionActivityController: SessionActivityControlling {
    func apply(_ payload: SessionActivityPayload?) async {
        var matching: Activity<SessionActivityAttributes>?
        for activity in Activity<SessionActivityAttributes>.activities {
            if let payload, activity.attributes.sessionID == payload.sessionID, matching == nil {
                matching = activity
            } else {
                let state = activity.content.state
                let ended = SessionActivityAttributes.ContentState(displayName: state.displayName,
                    endsAt: state.endsAt, isActive: false)
                await activity.end(ActivityContent(state: ended, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
        guard let payload else { return }
        // A background get may precede the profile read on relaunch. A matching
        // system activity already has the last authorized own display name.
        let name = payload.content.displayName.isEmpty ? (matching?.content.state.displayName ?? "") : payload.content.displayName
        let state = SessionActivityAttributes.ContentState(displayName: name,
            endsAt: payload.content.endsAt, isActive: payload.content.isActive)
        let content = ActivityContent(state: state, staleDate: payload.content.endsAt)
        if let matching { await matching.update(content) }
        else if !name.isEmpty, ActivityAuthorizationInfo().areActivitiesEnabled {
            // No push token or entitlement. Failure to present never changes the session.
            _ = try? Activity.request(attributes: SessionActivityAttributes(sessionID: payload.sessionID),
                content: content, pushType: nil)
        }
    }
}
