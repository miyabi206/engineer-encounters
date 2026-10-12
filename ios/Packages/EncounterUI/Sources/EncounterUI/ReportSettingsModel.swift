import Combine
import Foundation

public struct ReportSettingsTime: Equatable, Sendable {
    public var hour: Int
    public var minute: Int
    public init(hour: Int = 21, minute: Int = 0) { self.hour = hour; self.minute = minute }
    public var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) }
}

public enum ReportSettingsPermission: Equatable, Sendable { case notRequested, allowed, denied, unavailable }

public struct ReportSettingsData: Equatable, Sendable {
    public var time: ReportSettingsTime
    public var timeZone: String
    public var notificationsEnabled: Bool
    public init(time: ReportSettingsTime = .init(), timeZone: String = "", notificationsEnabled: Bool = false) {
        self.time = time; self.timeZone = timeZone; self.notificationsEnabled = notificationsEnabled
    }
}

@MainActor
public struct ReportSettingsActions {
    public var load: @MainActor () async throws -> ReportSettingsData
    public var saveTime: @MainActor (ReportSettingsTime) async throws -> ReportSettingsData
    public var setNotifications: @MainActor (Bool) async throws -> ReportSettingsData
    public var requestPermission: @MainActor () async throws -> ReportSettingsPermission
    public init(load: @escaping @MainActor () async throws -> ReportSettingsData,
                saveTime: @escaping @MainActor (ReportSettingsTime) async throws -> ReportSettingsData,
                setNotifications: @escaping @MainActor (Bool) async throws -> ReportSettingsData,
                requestPermission: @escaping @MainActor () async throws -> ReportSettingsPermission) {
        self.load = load; self.saveTime = saveTime; self.setNotifications = setNotifications
        self.requestPermission = requestPermission
    }
}

@MainActor
public struct ReportSettingsNavigationActions {
    public var back: @MainActor () -> Void
    public var systemSettings: @MainActor () -> Void
    public init(back: @escaping @MainActor () -> Void, systemSettings: @escaping @MainActor () -> Void) {
        self.back = back; self.systemSettings = systemSettings
    }
}

public enum ReportSettingsOperation: Equatable, Sendable { case load, time, notifications(Bool) }

@MainActor
public final class ReportSettingsModel: ObservableObject {
    @Published public private(set) var data: ReportSettingsData?
    @Published public var time: ReportSettingsTime {
        didSet { if time != oldValue { savedTime = false } }
    }
    @Published public private(set) var permission: ReportSettingsPermission
    @Published public private(set) var isBusy = false
    @Published public private(set) var error: ProfileActionError?
    @Published public private(set) var failedOperation: ReportSettingsOperation?
    @Published public private(set) var savedTime = false
    public let pushAvailable: Bool
    public let navigation: ReportSettingsNavigationActions
    private let actions: ReportSettingsActions

    public init(data: ReportSettingsData? = nil, pushAvailable: Bool, permission: ReportSettingsPermission = .notRequested,
                actions: ReportSettingsActions, navigation: ReportSettingsNavigationActions) {
        self.data = data; time = data?.time ?? .init(); self.pushAvailable = pushAvailable
        self.permission = permission; self.actions = actions; self.navigation = navigation
    }
    public var canSave: Bool { data != nil && time.isValid && !isBusy }
    public var showsNotificationSwitch: Bool {
        pushAvailable && (permission == .notRequested || permission == .allowed)
    }
    public func receive(permission: ReportSettingsPermission) { self.permission = permission }

    public func load() async {
        guard !isBusy else { return }
        begin(.load); data = nil
        defer { isBusy = false }
        do { let fresh = try await actions.load(); data = fresh; time = fresh.time; succeeded() }
        catch { fail(error) }
    }
    public func save() async {
        guard canSave else { return }
        let target = time
        begin(.time)
        defer { isBusy = false }
        do {
            let fresh = try await actions.saveTime(target)
            data = fresh
            guard fresh.time == target else { throw ProfileActionError(code: .unavailable) }
            succeeded(); savedTime = true
        } catch { fail(error) }
    }
    public func setNotifications(_ enabled: Bool) async {
        guard showsNotificationSwitch, data != nil, !isBusy else { return }
        begin(.notifications(enabled))
        defer { isBusy = false }
        do {
            if enabled {
                if permission == .notRequested { permission = try await actions.requestPermission() }
                guard permission == .allowed else { failedOperation = nil; return }
            }
            let fresh = try await actions.setNotifications(enabled)
            data = fresh
            guard fresh.notificationsEnabled == enabled else { throw ProfileActionError(code: .unavailable) }
            succeeded()
        } catch { fail(error) }
    }
    public func retry() async {
        switch failedOperation {
        case .load: await load()
        case .time: await save()
        case .notifications(let enabled): await setNotifications(enabled)
        case nil: break
        }
    }
    public func back() { if !isBusy { navigation.back() } }
    private func begin(_ operation: ReportSettingsOperation) {
        isBusy = true; error = nil; failedOperation = operation; savedTime = false
    }
    private func succeeded() { error = nil; failedOperation = nil }
    private func fail(_ failure: any Error) {
        error = failure as? ProfileActionError ?? .init(code: .unavailable)
    }
}
