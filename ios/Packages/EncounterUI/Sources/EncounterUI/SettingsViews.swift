import SwiftUI
import UIKit

// Resolve the property wrapper rather than the SDK's same-named compiler macro.
typealias SettingsViewState<Value> = State<Value>

/// Navigation belongs to the caller, including the additional rows and their build gates.
@MainActor
public struct SettingsListView<AdditionalRows: View>: View {
    private let navigation: SettingsNavigationActions
    private let destinations: AccountSettingsListNavigationActions
    private let additionalRows: AdditionalRows

    public init(navigation: SettingsNavigationActions, destinations: AccountSettingsListNavigationActions = .init(),
                @ViewBuilder additionalRows: () -> AdditionalRows) {
        self.navigation = navigation
        self.destinations = destinations
        self.additionalRows = additionalRows()
    }

    public var body: some View {
        List {
            ForEach(AccountSettingsListComposition.entries(destinations: destinations), id: \.self) { entry in
                switch entry {
                case .discovery: row(.discoveryMatching, action: navigation.discovery)
                case .visibility: row(.visibility, action: navigation.visibility)
                case .dailyReport: row(.dailyReportTitle, action: destinations.dailyReport)
                case .blockedUsers: row(.blockedUsers, action: destinations.blockedUsers)
                case .account: row(.account, action: destinations.account)
                case .legal: row(.legal, action: destinations.legal)
                case .diagnostics:
                    if let diagnostics = destinations.diagnostics { row(.diagnostics, action: diagnostics) }
                }
            }
            additionalRows
        }
        .listStyle(.plain)
        .navigationTitle(SettingsStrings.text(.settings))
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(.teal)
    }

    private func row(_ title: SettingsString, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(SettingsStrings.text(title)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .frame(minHeight: 44)
        }
        .accessibilityLabel(SettingsStrings.text(title))
    }
}

extension SettingsListView where AdditionalRows == EmptyView {
    public init(navigation: SettingsNavigationActions, destinations: AccountSettingsListNavigationActions = .init()) {
        self.init(navigation: navigation, destinations: destinations) { EmptyView() }
    }
}

@MainActor
public struct EditProfileView: View {
    @ObservedObject private var model: SettingsModel
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let navigation: SettingsNavigationActions

    public init(model: SettingsModel, navigation: SettingsNavigationActions) {
        self.model = model; self.navigation = navigation
    }

    public var body: some View {
        SettingsPage(model: model, screen: .profile, title: .editProfile, navigation: navigation,
                     save: save, canSave: model.canSaveProfile) {
            OnboardingCard {
                textInput(.displayName, value: $model.displayName, limit: ProfileValidation.displayNameLimit)
                textInput(.introduction, value: $model.introduction, limit: ProfileValidation.introductionLimit)
            }.disabled(model.isSaving)
            OnboardingCard {
                heading(.interests)
                if model.isLoadingInterests { SettingsProgress() }
                if let error = model.interestLoadError {
                    SettingsFailure(error: error, screen: .profile, discoveryOn: model.profile.discoveryOn,
                                    disabled: model.isBusy, fallback: .listError) {
                        Task { await model.loadInterests() }
                    }
                } else if model.shouldRetryInterestLoad {
                    if model.hasLoadedInterests {
                        Text(SettingsStrings.text(.emptyInterests)).foregroundStyle(.secondary)
                    }
                    Button(SettingsStrings.text(.retry)) { Task { await model.loadInterests() } }
                        .disabled(model.isBusy)
                }
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] :
                          [GridItem(.adaptive(minimum: 140))], alignment: .leading) {
                    ForEach(model.interests) { interest in
                        SelectionControl(label: interest.label(language: locale.identifier),
                                         selected: model.selectedInterestIDs.contains(interest.id)) {
                            model.toggleInterest(interest.id)
                        }
                        .background(model.selectedInterestIDs.contains(interest.id) ? Color.teal.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 16))
                        .disabled(model.isSaving || !ProfileValidation.canToggleInterest(interest.id, selected: model.selectedInterestIDs))
                    }
                }
                Text(String(format: SettingsStrings.text(.interestCounter), locale: locale,
                            model.selectedInterestIDs.count, ProfileValidation.interestLimit))
                    .font(.caption).foregroundStyle(.secondary)
                Text(String(format: SettingsStrings.text(.interestLimit), locale: locale, ProfileValidation.interestLimit))
                    .font(.caption).foregroundStyle(.secondary)
                selectionFeedback(.interests)
            }
            OnboardingCard {
                SettingsPurposes(model: model, screen: .profile)
                selectionFeedback(.purposes)
            }
            OnboardingCard {
                textInput(.contactDetail, value: $model.contactDetail, limit: ProfileValidation.contactDetailLimit)
                Text(SettingsStrings.text(.contactPrivate)).font(.caption).foregroundStyle(.secondary)
            }.disabled(model.isSaving)
            Button(SettingsStrings.text(.visibility), action: navigation.visibility).disabled(model.isSaving)
            if !model.removedPrerequisites.isEmpty || model.errors[.profile]?.code == .prerequisiteMissing {
                Text(SettingsStrings.text(model.profile.discoveryOn ? .discoveryRequired : .requiredInformation)).foregroundStyle(.red)
                Button(SettingsStrings.text(.discoveryMatching), action: navigation.discovery).disabled(model.isSaving)
            }
        }
        .task { if !model.hasLoadedInterests { await model.loadInterests() } }
    }

    private func save() {
        Task { if await model.saveProfile() { navigation.back() } }
    }

    @ViewBuilder
    private func textInput(_ field: ProfileField, value: Binding<String>, limit: Int) -> some View {
        let label = SettingsStrings.text(field == .contactDetail ? .optionalContact : field.settingsLabel)
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline).accessibilityAddTraits(.isHeader)
            if field == .introduction {
                TextField(label, text: value, axis: .vertical).lineLimit(4...10)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(label)
            } else {
                TextField(label, text: value)
                    .textContentType(field == .displayName ? .nickname : nil)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(label)
            }
            Text(SettingsStrings.counter(value.wrappedValue, limit: limit)).font(.caption).foregroundStyle(.secondary)
            if SettingsValidation.textCount(value.wrappedValue) > limit {
                Text(String(format: SettingsStrings.text(.tooLong), limit)).foregroundStyle(.red)
            } else if model.removedPrerequisites.contains(field) {
                Text(SettingsStrings.text(.discoveryRequired)).foregroundStyle(.red)
            } else if model.profile.discoveryOn && field != .contactDetail && SettingsValidation.textCount(value.wrappedValue) == 0 {
                Text(SettingsStrings.text(.requiredField)).foregroundStyle(.red)
            } else if SettingsErrorPresentation.affects(model.errors[.profile], field: field) {
                Text(SettingsStrings.text(.invalidField)).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func selectionFeedback(_ field: ProfileField) -> some View {
        if model.removedPrerequisites.contains(field) {
            Text(SettingsStrings.text(.discoveryRequired)).foregroundStyle(.red)
        } else if model.invalidProfileFields.contains(field) {
            Text(SettingsStrings.text(field == .purposes ? .purposeRequired : .selectionGuidance)).foregroundStyle(.red)
        } else if SettingsErrorPresentation.affects(model.errors[.profile], field: field) {
            Text(SettingsStrings.text(.invalidField)).foregroundStyle(.red)
        }
    }

    private func heading(_ key: SettingsString) -> some View {
        Text(SettingsStrings.text(key)).font(.headline).accessibilityAddTraits(.isHeader)
    }
}

@MainActor
public struct DiscoveryAndMatchingView: View {
    @ObservedObject private var model: SettingsModel
    private let navigation: SettingsNavigationActions

    public init(model: SettingsModel, navigation: SettingsNavigationActions) {
        self.model = model; self.navigation = navigation
    }

    public var body: some View {
        SettingsPage(model: model, screen: .discovery, title: .discoveryMatching, navigation: navigation) {
            OnboardingCard {
                Toggle(SettingsStrings.text(.discovery), isOn: Binding(
                    get: { model.profile.discoveryOn }, set: { enabled in
                        changeDiscovery(enabled)
                    }))
                    .disabled(model.isSaving || (!model.profile.discoveryOn && !model.canEnableDiscovery))
                    .accessibilityLabel(SettingsStrings.text(.discovery))
                Text(SettingsStrings.text(.discoveryOffExplanation)).font(.caption).foregroundStyle(.secondary)
                if model.showsDiscoveryExplanation && !model.profile.discoveryOn {
                    ForEach([SettingsString.promise, .background, .dailyReport, .alternatives,
                             .forceQuit, .firstUnlock, .oneSided], id: \.self) { key in
                        Text(SettingsStrings.text(key)).font(.callout)
                    }
                }
            }
            OnboardingCard {
                Text(SettingsStrings.text(.checklist)).font(.headline).accessibilityAddTraits(.isHeader)
                if !model.profile.prerequisites.canEnableDiscovery {
                    Text(SettingsStrings.text(.requiredInformation)).foregroundStyle(.secondary)
                }
                ForEach(DiscoveryPrerequisite.allCases, id: \.self) { prerequisite in
                    checklistRow(prerequisite)
                }
                if !model.profile.prerequisites.link {
                    Text(SettingsStrings.text(.linkRequired)).foregroundStyle(.secondary)
                }
            }
            OnboardingCard {
                Text(SettingsStrings.text(.bluetoothPurpose))
                Text(SettingsStrings.text(bluetoothLabel))
                if model.bluetooth.needsRecovery {
                    Button(SettingsStrings.text(.bluetoothRecovery), action: navigation.bluetoothRecovery)
                        .disabled(model.isSaving)
                } else if model.allowsDiscoveryActivation && model.bluetooth == .notRequested {
                    Button(SettingsStrings.text(.allowBluetooth)) {
                        requestBluetooth()
                    }.disabled(model.isSaving)
                }
            }
            OnboardingCard {
                SettingsPurposes(model: model, screen: .discovery)
                if model.matchingPurposes.isEmpty {
                    Text(SettingsStrings.text(.purposeRequired)).foregroundStyle(.red)
                } else if SettingsErrorPresentation.affects(model.errors[.discovery], field: .purposes) {
                    Text(SettingsStrings.text(.invalidField)).foregroundStyle(.red)
                }
            }
            OnboardingCard {
                Text(SettingsStrings.text(.threshold)).font(.headline).accessibilityAddTraits(.isHeader)
                Stepper(SettingsStrings.threshold(model.minimumSharedInterests), value: $model.minimumSharedInterests,
                        in: ProfileValidation.sharedInterestRange)
                    .disabled(model.isSaving)
                    .accessibilityLabel(SettingsStrings.text(.threshold))
                    .accessibilityValue(SettingsStrings.threshold(model.minimumSharedInterests))
                if !ProfileValidation.sharedInterestRange.contains(model.minimumSharedInterests) ||
                    SettingsErrorPresentation.affectsThreshold(model.errors[.discovery]) {
                    Text(SettingsStrings.text(.invalidField)).foregroundStyle(.red)
                }
                Text(SettingsStrings.text(.matchingExplanation)).foregroundStyle(.secondary)
            }
            if model.isSaving { SettingsProgress() }
            if let error = model.errors[.discovery] {
                SettingsFailure(error: error, screen: .discovery, discoveryOn: model.profile.discoveryOn,
                                disabled: !model.canRetry(.discovery), fallback: model.errorFallback(.discovery), retry: retry)
                SettingsAppliedChanges(model: model, screen: .discovery)
            }
            Button(SettingsStrings.text(.saveMatching)) {
                Task { await model.saveMatching() }
            }.buttonStyle(.borderedProminent).disabled(!model.canSaveMatching)
        }
    }

    private var bluetoothLabel: SettingsString {
        switch model.bluetooth {
        case .notRequested: .bluetoothNotRequested
        case .available: .bluetoothAvailable
        case .denied: .bluetoothDenied
        case .poweredOff: .bluetoothOff
        case .unavailable: .bluetoothUnavailable
        }
    }

    @ViewBuilder
    private func checklistRow(_ prerequisite: DiscoveryPrerequisite) -> some View {
        let met = model.profile.prerequisites.isMet(prerequisite)
        let label = SettingsStrings.labelStatus(SettingsStrings.text(prerequisite.settingsLabel), SettingsStrings.text(met ? .met : .missing))
        let error = model.errors[.discovery]
        let hasError = error?.code == .prerequisiteMissing && error?.fields.contains(prerequisite.rawValue) == true
        if (!met || hasError) && (prerequisite != .link || navigation.links != nil) {
            Button {
                if prerequisite == .link { navigation.links?() } else { navigation.editProfile() }
            } label: {
                Label(label, systemImage: "square").multilineTextAlignment(.leading)
            }.disabled(model.isSaving)
        } else {
            Label(label, systemImage: met ? "checkmark.square" : "square")
        }
        if hasError { Text(SettingsStrings.text(.requiredInformation)).foregroundStyle(.red) }
    }

    private func changeDiscovery(_ enabled: Bool) {
        Task {
            if await model.setDiscovery(enabled), !enabled { navigation.discoveryOff() }
        }
    }

    private func requestBluetooth() {
        Task {
            await model.requestBluetooth()
            if model.bluetooth.needsRecovery { navigation.bluetoothRecovery() }
        }
    }

    private func retry() {
        Task {
            let operation = model.failedOperations[.discovery]
            let succeeded = await model.retry(.discovery)
            if succeeded && operation == .discovery(false) { navigation.discoveryOff() }
            if operation == .bluetooth && model.bluetooth.needsRecovery { navigation.bluetoothRecovery() }
        }
    }

}

@MainActor
public struct VisibilitySettingsView: View {
    @ObservedObject private var model: SettingsModel
    private let navigation: SettingsNavigationActions

    public init(model: SettingsModel, navigation: SettingsNavigationActions) {
        self.model = model; self.navigation = navigation
    }

    public var body: some View {
        SettingsPage(model: model, screen: .visibility, title: .visibility, navigation: navigation) {
            OnboardingCard {
                ForEach(ProfileField.allCases, id: \.self) { field in
                    VStack(alignment: .leading, spacing: 8) {
                        let label = SettingsStrings.text(field == .interests ? .visibilityInterests : field.settingsLabel)
                        Text(label).font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(VisibilityLevel.allCases, id: \.self) { level in
                            SelectionControl(label: SettingsStrings.text(level.settingsLabel),
                                             selected: SettingsValidation.visibility(field, in: model.visibility) == level) {
                                model.visibility[field] = level
                            }.accessibilityLabel(SettingsStrings.fieldMessage(label, SettingsStrings.text(level.settingsLabel)))
                        }
                        if SettingsErrorPresentation.affects(model.errors[.visibility], field: field) {
                            Text(SettingsStrings.text(.invalidField)).foregroundStyle(.red)
                        }
                    }
                }
                if let links = navigation.links {
                    Button(SettingsStrings.text(.linkVisibility), action: links)
                }
            }.disabled(model.isSaving)
            OnboardingCard {
                ForEach([VisibilityLevel.everyoneEligible, .compatibleOnly, .private], id: \.self) { level in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SettingsStrings.text(level.settingsLabel)).font(.headline)
                        Text(SettingsStrings.text(explanation(level)))
                    }
                }
                Text(SettingsStrings.text(.appliesToPast))
            }
            if model.isSaving { SettingsProgress() }
            if let error = model.errors[.visibility] {
                SettingsFailure(error: error, screen: .visibility, discoveryOn: model.profile.discoveryOn,
                                disabled: !model.canRetry(.visibility)) { Task { await model.retry(.visibility) } }
                SettingsAppliedChanges(model: model, screen: .visibility)
            }
            Button(SettingsStrings.text(.saveVisibility)) { Task { await model.saveVisibility() } }
                .buttonStyle(.borderedProminent).disabled(model.isSaving)
        }
    }

    private func explanation(_ level: VisibilityLevel) -> SettingsString {
        switch level {
        case .everyoneEligible: .everyoneExplanation
        case .compatibleOnly: .compatibleExplanation
        case .private: .privateExplanation
        }
    }
}

@MainActor
private struct SettingsPurposes: View {
    @ObservedObject var model: SettingsModel
    let screen: SettingsScreen

    var body: some View {
        Text(SettingsStrings.text(.purposes)).font(.headline).accessibilityAddTraits(.isHeader)
        ForEach(ProfilePurpose.allCases, id: \.self) { purpose in
            SelectionControl(label: SettingsStrings.text(purpose == .discovery ? .discoveryPurpose : .collaborationPurpose),
                             selected: (screen == .profile ? model.selectedPurposes : model.matchingPurposes).contains(purpose)) {
                model.togglePurpose(purpose, screen: screen)
            }.disabled(model.isSaving)
        }
    }
}

@MainActor
private struct SettingsPage<Content: View>: View {
    @ObservedObject var model: SettingsModel
    let screen: SettingsScreen
    let title: SettingsString
    let navigation: SettingsNavigationActions
    var save: (@MainActor () -> Void)?
    var canSave = false
    @ViewBuilder let content: Content
    @SettingsViewState private var confirmsDiscard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Button(SettingsStrings.text(screen == .profile ? .cancel : .back), action: leave)
                        .disabled(model.isSaving)
                    Spacer()
                    if let save {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(SettingsStrings.text(.save), action: save).disabled(!canSave)
                            if model.isSaving { SettingsProgress() }
                            if let error = model.errors[screen] {
                                SettingsFailure(error: error, screen: screen, discoveryOn: model.profile.discoveryOn,
                                    disabled: !model.canRetry(screen), fallback: model.errorFallback(screen)) {
                                    Task { if await model.retry(screen) { navigation.back() } }
                                }
                                SettingsAppliedChanges(model: model, screen: screen)
                            }
                        }
                    }
                }
                Text(SettingsStrings.text(title)).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                content
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .background(Color(uiColor: .systemGroupedBackground)).tint(.teal)
        .navigationBarBackButtonHidden(true)
        .onDisappear { model.leave(screen) }
        .onChange(of: model.isSaving) { _, saving in
            if saving { UIAccessibility.post(notification: .announcement, argument: SettingsSaveFeedback.announcement(model: model, screen: screen)) }
        }
        .onChange(of: model.errors[screen]) { _, error in
            guard error != nil else { return }
            UIAccessibility.post(notification: .announcement,
                                 argument: SettingsSaveFeedback.announcement(model: model, screen: screen))
        }
        .confirmationDialog(SettingsStrings.text(.discardChanges), isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button(SettingsStrings.text(.discardChanges), role: .destructive) {
                model.discard(screen)
                navigation.back()
            }
            Button(SettingsStrings.text(.cancel), role: .cancel) {}
        }
    }

    private func leave() {
        let dirty: Bool
        switch screen {
        case .profile: dirty = model.hasProfileChanges
        case .discovery: dirty = model.hasMatchingChanges
        case .visibility: dirty = model.hasVisibilityChanges
        }
        if dirty { confirmsDiscard = true } else { model.leave(screen); navigation.back() }
    }
}

@MainActor
private struct SettingsProgress: View {
    var body: some View {
        ProgressView(SettingsStrings.text(.loading)).accessibilityLabel(SettingsStrings.text(.loading))
    }
}

@MainActor
private struct SettingsFailure: View {
    let error: ProfileActionError
    let screen: SettingsScreen
    let discoveryOn: Bool
    let disabled: Bool
    var fallback: SettingsString = .saveError
    let retry: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SettingsStrings.text(error.code == .unavailable ? fallback :
                SettingsErrorPresentation.message(error, screen: screen, discoveryOn: discoveryOn)))
                .foregroundStyle(.red)
            if error.code == .prerequisiteMissing && error.fields.contains("link") {
                Text(SettingsStrings.text(.linkRequired)).foregroundStyle(.red)
            }
            Button(SettingsStrings.text(.retry), action: retry).disabled(disabled)
        }
    }
}

@MainActor
struct SettingsAppliedChanges: View {
    @ObservedObject var model: SettingsModel
    let screen: SettingsScreen
    @Environment(\.locale) private var locale

    var body: some View {
        let messages = Self.messages(model: model, screen: screen, language: locale.identifier)
        if !messages.isEmpty {
            Text(SettingsStrings.text(.partialSave)).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in Text(message) }
        }
    }

    static func messages(model: SettingsModel, screen: SettingsScreen, language: String) -> [String] {
        (model.appliedChanges[screen] ?? []).map { change in
            let label: String
            let value: String
            switch change {
            case .threshold:
                label = SettingsStrings.text(.threshold)
                value = SettingsStrings.threshold(model.profile.minimumSharedInterests)
            case .field(let field):
                label = SettingsStrings.text(field.settingsLabel)
                if screen == .visibility {
                    value = SettingsStrings.text(SettingsValidation.visibility(field, in: model.profile.fieldVisibility).settingsLabel)
                } else {
                    switch field {
                    case .displayName: value = model.profile.displayName
                    case .introduction: value = model.profile.introduction
                    case .contactDetail: value = model.profile.contactDetail
                    case .interests:
                        value = SettingsStrings.joined(model.profile.interestIDs.sorted().map { id in
                            model.interests.first(where: { $0.id == id })?.label(language: language) ?? id
                        })
                    case .purposes:
                        value = SettingsStrings.joined(ProfilePurpose.allCases.filter { model.profile.purposes.contains($0) }.map {
                            SettingsStrings.text($0 == .discovery ? .discoveryPurpose : .collaborationPurpose)
                        })
                    }
                }
            }
            return String(format: SettingsStrings.text(.appliedChange), locale: Locale.current,
                          label, value.isEmpty ? SettingsStrings.text(.notSet) : value)
        }
    }
}

@MainActor
enum SettingsSaveFeedback {
    static func announcement(model: SettingsModel, screen: SettingsScreen) -> String? {
        if model.isSaving { return SettingsStrings.text(.loading) }
        guard let error = model.errors[screen] else { return nil }
        let message = SettingsStrings.text(error.code == .unavailable ? model.errorFallback(screen) :
            SettingsErrorPresentation.message(error, screen: screen, discoveryOn: model.profile.discoveryOn))
        let applied = SettingsAppliedChanges.messages(model: model, screen: screen, language: Locale.current.identifier)
        return ([message] + (applied.isEmpty ? [] : [SettingsStrings.text(.partialSave)] + applied)).joined(separator: "\n")
    }
}
