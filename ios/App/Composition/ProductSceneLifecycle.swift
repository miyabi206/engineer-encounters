import Combine
import SwiftUI
import UIKit

/// Forward the real app lifecycle explicitly into the separate tab hosting trees.
@MainActor
final class ProductSceneLifecycle: ObservableObject {
    @Published private(set) var phase: ScenePhase
    private var subscriptions: Set<AnyCancellable> = []
    let privacyCover = ScenePrivacyCover()

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
        notifications.publisher(for: UIScene.willDeactivateNotification).sink { [weak self] note in
            guard let scene = note.object as? UIWindowScene else { return }
            self?.privacyCover.hide(scene)
        }.store(in: &subscriptions)
        notifications.publisher(for: UIScene.didActivateNotification).sink { [weak self] note in
            guard let scene = note.object as? UIWindowScene else { return }
            self?.privacyCover.show(scene)
        }.store(in: &subscriptions)
        notifications.publisher(for: UIScene.didDisconnectNotification).sink { [weak self] note in
            guard let scene = note.object as? UIWindowScene else { return }
            self?.privacyCover.show(scene)
        }.store(in: &subscriptions)
        if self.phase != .active { coverConnectedScenes() }
    }

    func receive(_ phase: ScenePhase) {
        // UIKit notifications are handled synchronously, before snapshot capture;
        // SwiftUI rendering or an async task is too late for this boundary.
        if phase != .active { coverConnectedScenes() }
        else {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                where scene.activationState == .foregroundActive { privacyCover.show(scene) }
        }
        if self.phase != phase { self.phase = phase }
    }

    private func coverConnectedScenes() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) { privacyCover.hide(scene) }
    }
}

/// A separate opaque window covers the entire scene, including presented sheets.
@MainActor
final class ScenePrivacyCover {
    private var covers: [ObjectIdentifier: UIWindow] = [:]
    func window(for scene: UIWindowScene) -> UIWindow? { covers[ObjectIdentifier(scene)] }
    func hide(_ scene: UIWindowScene) {
        let id = ObjectIdentifier(scene)
        guard covers[id] == nil else { return }
        let cover = UIWindow(windowScene: scene)
        cover.frame = scene.effectiveGeometry.coordinateSpace.bounds
        cover.windowLevel = .alert + 1
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        controller.view.isOpaque = true
        cover.backgroundColor = .systemBackground
        cover.isOpaque = true
        cover.rootViewController = controller
        cover.accessibilityViewIsModal = true
        covers[id] = cover
        cover.isHidden = false
    }
    func show(_ scene: UIWindowScene) {
        covers.removeValue(forKey: ObjectIdentifier(scene))?.isHidden = true
    }
}

/// Also protects a scene whose root is installed during a background launch.
@MainActor
struct ScenePrivacyAttachment: UIViewRepresentable {
    let cover: ScenePrivacyCover
    func makeUIView(context: Context) -> Attachment { Attachment(cover: cover) }
    func updateUIView(_ view: Attachment, context: Context) { view.protectIfNeeded() }
    final class Attachment: UIView {
        let cover: ScenePrivacyCover
        init(cover: ScenePrivacyCover) { self.cover = cover; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() { super.didMoveToWindow(); protectIfNeeded() }
        func protectIfNeeded() {
            if let scene = window?.windowScene, scene.activationState != .foregroundActive { cover.hide(scene) }
        }
    }
}
