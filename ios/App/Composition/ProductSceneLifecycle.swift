import Combine
import SwiftUI
import UIKit

/// Forward the real app lifecycle explicitly into the separate tab hosting trees.
@MainActor
final class ProductSceneLifecycle: ObservableObject {
    @Published private(set) var phase: ScenePhase
    private var subscriptions: Set<AnyCancellable> = []

    init(phase: ScenePhase? = nil, notifications: NotificationCenter = .default) {
        self.phase = phase ?? (UIApplication.shared.applicationState == .active ? .active : .background)
        notifications.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.receive(.active)
        }.store(in: &subscriptions)
        notifications.publisher(for: UIApplication.willResignActiveNotification).sink { [weak self] _ in
            self?.receive(.inactive)
        }.store(in: &subscriptions)
        notifications.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            self?.receive(.background)
        }.store(in: &subscriptions)
    }

    func receive(_ phase: ScenePhase) { if self.phase != phase { self.phase = phase } }
}
