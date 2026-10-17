import SwiftUI

@MainActor
public struct ReportSettingsView: View {
    @ObservedObject private var model: ReportSettingsModel
    @SafetyViewState private var confirmsDiscard = false
    private let notificationControlsEnabled: Bool
    public init(model: ReportSettingsModel, notificationControlsEnabled: Bool = true) {
        self.model = model; self.notificationControlsEnabled = notificationControlsEnabled
    }
    var showsNotificationControls: Bool {
        notificationControlsEnabled && (model.pushAvailable || model.showsNotificationSwitch)
    }
    public var body: some View {
        SafetyPage(title: ReportSettingsStrings.text(.title)) {
            if model.data != nil {
                OnboardingCard {
                    DatePicker(ReportSettingsStrings.text(.time), selection: timeBinding, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        .tint(EncounterPalette.accent)
                        .disabled(model.isBusy)
                    Text(ReportSettingsStrings.text(.localTime)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                    if !model.time.isValid { Text(ReportSettingsStrings.text(.invalidTime)).foregroundStyle(EncounterPalette.destructive) }
                }
                if showsNotificationControls {
                    OnboardingCard {
                        if model.showsNotificationSwitch {
                            Toggle(ReportSettingsStrings.text(.notifications), isOn: Binding(
                                get: { model.data?.notificationsEnabled == true },
                                set: { enabled in Task { await model.setNotifications(enabled) } }))
                                .tint(EncounterPalette.accent).disabled(model.isBusy)
                        }
                        Text(ReportSettingsStrings.text(model.pushAvailable ? model.permission.stringKey : .noPush))
                            .foregroundStyle(EncounterPalette.inkSecondary)
                        if model.pushAvailable, model.permission == .denied {
                            Button(ReportSettingsStrings.text(.systemSettings), action: model.navigation.systemSettings)
                                .buttonStyle(EncounterButtonStyle(.secondary))
                        }
                        Text(ReportSettingsStrings.text(.names)).font(.callout).foregroundStyle(EncounterPalette.inkSecondary)
                    }
                } else { Text(ReportSettingsStrings.text(.noPush)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary) }
                Text(ReportSettingsStrings.text(.ambient)).font(.caption)
                Text(ReportSettingsStrings.text(.inApp)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                Text(ReportSettingsStrings.text(.noReport)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                Text(ReportSettingsStrings.text(.waiting)).font(.callout).foregroundStyle(EncounterPalette.inkSecondary)
                Button(ReportSettingsStrings.text(.saveTime)) { Task { await model.save() } }
                    .buttonStyle(EncounterButtonStyle(.primary)).disabled(!model.canSave)
            }
            if model.isBusy { EncounterProgress(SettingsStrings.text(.loading)) }
            if let error = model.error {
                SafetyFailure(error: error, fallback: model.failedOperation == .load ? .listError : .saveError,
                              disabled: model.isBusy) { await model.retry() }
            }
            if model.savedTime { EncounterNotice(ReportSettingsStrings.text(.saved)) }
        }
        .navigationBarBackButtonHidden(true).interactiveDismissDisabled(model.isBusy)
        .environment(\.safetyPageIsPushed, true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EncounterBackButton(label: SettingsStrings.text(.back)) {
                    if let data = model.data, model.time != data.time { confirmsDiscard = true }
                    else { model.back() }
                }.disabled(model.isBusy)
            }
        }
        .confirmationDialog(ReportSettingsStrings.text(.discard), isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button(SettingsStrings.text(.back), role: .destructive) {
                if let data = model.data { model.time = data.time }; model.back()
            }
            Button(SettingsStrings.text(.cancel), role: .cancel) {}
        }
        .task { await model.load() }
    }
    private var timeBinding: Binding<Date> {
        Binding(get: {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar.date(from: DateComponents(year: 2001, month: 1, day: 1,
                hour: model.time.isValid ? model.time.hour : 21, minute: model.time.isValid ? model.time.minute : 0))!
        }, set: { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = calendar.dateComponents([.hour, .minute], from: date)
            model.time = .init(hour: components.hour ?? 21, minute: components.minute ?? 0)
        })
    }
}

extension ReportSettingsPermission {
    var stringKey: ReportSettingsString {
        switch self {
        case .notRequested: .permissionNotRequested
        case .allowed: .permissionAllowed
        case .denied: .permissionDenied
        case .unavailable: .permissionUnavailable
        }
    }
}
