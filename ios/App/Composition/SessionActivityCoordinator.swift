import ActivityKit
import Combine
import EncounterUI
import Foundation

struct SessionActivityPayload: Equatable, Sendable {
    let sessionID: String
    let content: SessionActivityAttributes.ContentState

    static func select(snapshot: SessionHolder.Snapshot, displayName: String) -> Self? {
        guard case .active(let session) = snapshot.state, !snapshot.stopPending, !displayName.isEmpty,
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

    init(controller: any SessionActivityControlling) { self.controller = controller }

    func receive(_ snapshot: SessionHolder.Snapshot, displayName: String, isCurrent: Bool = true) {
        let next = isCurrent ? SessionActivityPayload.select(snapshot: snapshot, displayName: displayName) : nil
        guard !received || payload != next else { return }
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
        let content = ActivityContent(state: payload.content, staleDate: payload.content.endsAt)
        if let matching { await matching.update(content) }
        else if ActivityAuthorizationInfo().areActivitiesEnabled {
            // No push token or entitlement. Failure to present never changes the session.
            _ = try? Activity.request(attributes: SessionActivityAttributes(sessionID: payload.sessionID),
                content: content, pushType: nil)
        }
    }
}
