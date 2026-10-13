import EncounterUI
import Foundation

/// Device notification boundary, injected by composition; tests never request OS permission.
@MainActor
protocol LocalNotificationCenter {
    func permission() async -> ReportSettingsPermission
    func requestPermission() async throws
    func post(body: String) async throws -> String
    func remove(_ id: String)
    func clear()
}
