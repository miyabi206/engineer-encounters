import SwiftUI
import UIKit
import XCTest
@testable import EngineerEncounters

@MainActor
final class ScenePrivacyCoverTests: XCTestCase {
    func testSceneDeactivationSynchronouslyCoversRootSheetsAndRecoveryUntilActivation() throws {
        let scene = try appBackendWindowScene()
        let notifications = NotificationCenter()
        let lifecycle = ProductSceneLifecycle(phase: .active, notifications: notifications)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        defer { for scene in scenes { lifecycle.privacyCover.show(scene) } }
        notifications.post(name: UIScene.willDeactivateNotification, object: scene)
        let cover = try XCTUnwrap(lifecycle.privacyCover.window(for: scene))
        XCTAssertFalse(cover.isHidden)
        XCTAssertTrue(cover.isOpaque)
        XCTAssertEqual(cover.backgroundColor, .systemBackground)
        XCTAssertTrue(try XCTUnwrap(cover.rootViewController).view.isOpaque)
        XCTAssertGreaterThan(cover.windowLevel, .alert)
        XCTAssertEqual(cover.frame, scene.effectiveGeometry.coordinateSpace.bounds)
        // The cover is outside the content hierarchy; tab roots, sheets and
        // AccountDeletionRecoveryView all remain beneath the same opaque window.
        notifications.post(name: UIScene.didActivateNotification, object: scene)
        XCTAssertNil(lifecycle.privacyCover.window(for: scene))
        XCTAssertTrue(cover.isHidden)
    }

    func testApplicationResignationCoversEveryConnectedSceneSynchronously() throws {
        _ = try appBackendWindowScene()
        let notifications = NotificationCenter()
        let lifecycle = ProductSceneLifecycle(phase: .active, notifications: notifications)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        defer { for scene in scenes { lifecycle.privacyCover.show(scene) } }
        notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertEqual(lifecycle.phase, .inactive)
        for scene in scenes { XCTAssertNotNil(lifecycle.privacyCover.window(for: scene)) }
        for scene in scenes {
            notifications.post(name: UIScene.didActivateNotification, object: scene)
            XCTAssertNil(lifecycle.privacyCover.window(for: scene))
        }
    }
}
