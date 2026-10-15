#if DEVELOPMENT_BUILD || INTERNAL_BUILD
import Combine
import EncounterBackend
import EncounterUI
import Foundation
import UserNotifications

@MainActor
struct SystemDemoNotificationCenter: LocalNotificationCenter {
    func permission() async -> ReportSettingsPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notRequested
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        @unknown default: .unavailable
        }
    }
    func requestPermission() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func post(body: String) async throws -> String {
        let content = UNMutableNotificationContent()
        content.title = DiagnosticsStrings.text("demoNotificationTitle")
        content.body = body
        // Random local reference; no account, encounter, token or other protected identifier.
        let id = UUID().uuidString
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        return id
    }
    func remove(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
    func clear() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}

/// Only server-new, currently authorized cards may produce a demo notification.
@MainActor
final class DemoRevealController: ObservableObject {
    @Published private(set) var unavailable = false
    var allowsNotification: @MainActor (String) -> Bool = { _ in true }
    private let setting: DemoSwitchSetting
    private let center: any LocalNotificationCenter
    private var requestedPermission = false
    private var generation = UUID()
    private var running: (id: UUID, task: Task<Void, any Error>)?
    private var backend: SessionBackendServices?
    private let account: AccountModel

    init(setting: DemoSwitchSetting, center: any LocalNotificationCenter, account: AccountModel) {
        self.setting = setting; self.center = center; self.account = account
        center.clear()
    }
    func configure(_ backend: SessionBackendServices?) {
        if self.backend?.epoch != backend?.epoch || self.backend?.owner != backend?.owner { invalidate() }
        self.backend = backend
    }
    func invalidate() {
        generation = UUID(); running?.task.cancel(); running = nil; backend = nil; unavailable = false
    }
    func clear() { invalidate(); center.clear() }
    func switchedOff() { generation = UUID(); running?.task.cancel(); running = nil; unavailable = false; center.clear() }
    func switchedOn() async {
        guard setting.isEnabled, !requestedPermission else { return }
        requestedPermission = true
        if await center.permission() == .notRequested { try? await center.requestPermission() }
    }
    func reveal() async throws {
        guard setting.isEnabled, !unavailable, !account.deletionSuspended,
              account.state.isSignedIn, let backend, backend.isCurrent else { return }
        if let running { try await running.task.value; return }
        let id = UUID(), revision = generation
        let task = Task {
            do {
                let result = try await self.call(backend) { try await $0.report.revealAmbientNow() }
                guard self.current(revision, backend: backend) else { return }
                guard await self.center.permission() == .allowed else { return }
                guard self.current(revision, backend: backend) else { return }
                if result.truncated {
                    await self.notify(displayName: nil, revision: revision, backend: backend)
                } else {
                    for item in result.cards {
                        guard self.current(revision, backend: backend) else { return }
                        // Recheck at handoff; discard the response immediately after posting.
                        let detail: EncounterCardTransfer
                        do { detail = try await self.call(backend) { try await $0.encounter.getEncounterCard(encounterID: item.card.encounterID) } }
                        catch BackendError.notAuthenticated { throw BackendError.notAuthenticated }
                        catch is CancellationError { throw CancellationError() }
                        catch { continue }
                        guard self.current(revision, backend: backend) else { return }
                        guard self.allowsNotification(detail.card.encounterID.uuidString.lowercased()) else { continue }
                        await self.notify(displayName: detail.card.displayName, revision: revision, backend: backend)
                    }
                }
            } catch BackendError.notFound {
                if self.current(revision, backend: backend) { self.unavailable = true }
            }
        }
        running = (id, task)
        defer { if running?.id == id { running = nil } }
        try await task.value
    }
    private func call<Value>(_ backend: SessionBackendServices,
                             _ operation: @MainActor (SessionBackendServices.Services) async throws -> Value) async throws -> Value {
        var rejected = false
        do {
            return try await backend.call {
                do { return try await operation($0) }
                catch { rejected = error as? BackendError == .notAuthenticated; throw error }
            }
        } catch {
            if rejected, error as? BackendError == .notAuthenticated {
                await account.rejectDeadSession(generation: backend.epoch)
            }
            throw error
        }
    }
    private func notify(displayName: String?, revision: UUID, backend: SessionBackendServices) async {
        guard current(revision, backend: backend) else { return }
        if let id = try? await center.post(body: Self.notificationBody(displayName: displayName)),
           !current(revision, backend: backend) { center.remove(id) }
    }
    private func current(_ revision: UUID, backend: SessionBackendServices) -> Bool {
        revision == generation && setting.isEnabled && self.backend === backend && backend.isCurrent &&
        account.state.isSignedIn && !account.deletionSuspended
    }
    static func notificationBody(displayName: String?) -> String {
        DiagnosticsStrings.text("demoNotificationReady")
    }
}
#endif
