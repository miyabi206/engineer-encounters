import SwiftUI

@MainActor
public struct ReportSettingsView: View {
    @ObservedObject private var model: ReportSettingsModel
    @SafetyViewState private var confirmsDiscard = false
    public init(model: ReportSettingsModel) { self.model = model }
    public var body: some View {
        SafetyPage(title: ReportSettingsStrings.text(.title)) {
            if model.data != nil {
                OnboardingCard {
                    DatePicker(ReportSettingsStrings.text(.time), selection: timeBinding, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        .disabled(model.isBusy)
                    Text(ReportSettingsStrings.text(.localTime)).foregroundStyle(.secondary)
                    if !model.time.isValid { Text(ReportSettingsStrings.text(.invalidTime)).foregroundStyle(.red) }
                }
                if model.pushAvailable {
                    OnboardingCard {
                        if model.showsNotificationSwitch {
                            Toggle(ReportSettingsStrings.text(.notifications), isOn: Binding(
                                get: { model.data?.notificationsEnabled == true },
                                set: { enabled in Task { await model.setNotifications(enabled) } }))
                                .disabled(model.isBusy)
                        }
                        Text(ReportSettingsStrings.text(model.permission.stringKey)).foregroundStyle(.secondary)
                        if model.permission == .denied {
                            Button(ReportSettingsStrings.text(.systemSettings), action: model.navigation.systemSettings)
                        }
                        Text(ReportSettingsStrings.text(.names)).font(.callout).foregroundStyle(.secondary)
                    }
                } else { Text(ReportSettingsStrings.text(.noPush)).foregroundStyle(.secondary) }
                Text(ReportSettingsStrings.text(.ambient))
                Text(ReportSettingsStrings.text(.inApp)).foregroundStyle(.secondary)
                Text(ReportSettingsStrings.text(.noReport)).foregroundStyle(.secondary)
                Text(ReportSettingsStrings.text(.waiting)).font(.callout).foregroundStyle(.secondary)
                Button(ReportSettingsStrings.text(.saveTime)) { Task { await model.save() } }
                    .buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
            if model.isBusy { ProgressView(SettingsStrings.text(.loading)) }
            if let error = model.error {
                SafetyFailure(error: error, fallback: model.failedOperation == .load ? .listError : .saveError,
                              disabled: model.isBusy) { await model.retry() }
            }
            if model.savedTime { Text(ReportSettingsStrings.text(.saved)).foregroundStyle(.secondary) }
        }
        .navigationBarBackButtonHidden(true).interactiveDismissDisabled(model.isBusy)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(SettingsStrings.text(.back)) {
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
