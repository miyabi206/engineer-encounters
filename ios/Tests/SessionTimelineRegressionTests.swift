import Combine
import EncounterUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SessionTimelineRegressionTests: XCTestCase {
    func testStartingSessionTimelineReturnsControlWithoutRepeatedPublishing() async throws {
        let navigation = SessionNavigationActions(openQR: {}, openEncounter: { _ in },
                                                  close: {}, openDiscoveryOff: {})
        var startReached = false
        let model = SessionModel(actions: .init(startSession: {
            startReached = true
            // Keep the model in .starting for the entire observation window.
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }, stopSession: {}, refreshSession: { .none }), navigation: navigation)
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        try await withHostedView(SessionView(model: model, navigation: navigation)) {
            let start = Task { await model.start() }
            defer { start.cancel() }
            try await pumpRunLoop(for: 2.1)

            XCTAssertTrue(startReached)
            XCTAssertEqual(model.state, .starting)
            XCTAssertGreaterThan(changes, 0)
            XCTAssertLessThanOrEqual(changes, 8, "The timeline must not feed model updates back into rendering.")
            start.cancel()
            await start.value
        }
    }

    func testShowingQRTimelineReturnsControlWithBoundedCountdownPublishing() async throws {
        let navigation = QRNavigationActions(openEncounter: { _ in }, openIOSSettings: {},
                                             close: {}, openDiscoveryOff: {})
        let payload = try XCTUnwrap(QRPayload(token: String(repeating: "a", count: 32)))
        let code = QRCode(payload: payload, expiresAt: Date().addingTimeInterval(120))
        var issues = 0
        let model = QRModel(actions: .init(issueCode: {
            issues += 1
            return code
        }, cancelCode: { _ in }, redeemCode: { _ in "unused" }), navigation: navigation)
        await model.appear()
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        try await withHostedView(QRView(model: model, navigation: navigation)) {
            try await pumpRunLoop(for: 2.1)

            XCTAssertEqual(model.code, code)
            XCTAssertEqual(issues, 1)
            XCTAssertLessThan(model.remainingSeconds, 120)
            XCTAssertGreaterThan(model.remainingSeconds, 0)
            XCTAssertGreaterThan(changes, 0)
            XCTAssertLessThanOrEqual(changes, 8, "The timeline must publish only bounded countdown changes.")
        }
    }

    private func withHostedView<Content: View>(_ content: Content,
                                              perform: () async throws -> Void) async throws {
        let scene = try appBackendWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack {
            content.environment(\.scenePhase, .active)
        })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.layoutIfNeeded()
        try await perform()
    }

    private func pumpRunLoop(for duration: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        repeat {
            runLoopTurn()
            // Release the main actor between turns so view and action tasks can run.
            try await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
    }

    private func runLoopTurn() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
