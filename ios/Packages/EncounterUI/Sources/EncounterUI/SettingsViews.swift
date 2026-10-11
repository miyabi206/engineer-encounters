import SwiftUI

// Resolve the property wrapper rather than the SDK's same-named compiler macro.
typealias SettingsViewState<Value> = State<Value>

/// Navigation belongs to the caller, including the additional rows and their build gates.
@MainActor
public struct SettingsListView<AdditionalRows: View>: View {
    private let navigation: SettingsNavigationActions
    private let additionalRows: AdditionalRows

    public init(navigation: SettingsNavigationActions, @ViewBuilder additionalRows: () -> AdditionalRows) {
        self.navigation = navigation
        self.additionalRows = additionalRows()
    }

    public var body: some View {
        List {
            row(.editProfile, action: navigation.editProfile)
            row(.discoveryMatching, action: navigation.discovery)
            row(.visibility, action: navigation.visibility)
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
    public init(navigation: SettingsNavigationActions) {
        self.init(navigation: navigation) { EmptyView() }
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
            }.disabled(model.isBusy)
            OnboardingCard {
                heading(.interests)
                if model.isLoadingInterests { SettingsProgress() }
                if let error = model.interestLoadError {
                    SettingsFailure(error: error, screen: .profile, discoveryOn: model.profile.discoveryOn,
                                    disabled: model.isBusy, fallback: .listError) {
                        Task { await model.loadInterests() }
                    }
                } else if model.hasLoadedInterests && model.interests.isEmpty {
                    Text(SettingsStrings.text(.emptyInterests)).foregroundStyle(.secondary)
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
                        .disabled(model.isBusy || !ProfileValidation.canToggleInterest(interest.id, selected: model.selectedInterestIDs))
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
            }.disabled(model.isBusy)
            Button(SettingsStrings.text(.visibility), action: navigation.visibility).disabled(model.isBusy)
            if !model.removedPrerequisites.isEmpty || model.errors[.profile]?.code == .prerequisiteMissing {
                Text(SettingsStrings.text(model.profile.discoveryOn ? .discoveryRequired : .requiredInformation)).foregroundStyle(.red)
                Button(SettingsStrings.text(.discoveryMatching), action: navigation.discovery).disabled(model.isBusy)
            }
            if model.isSaving { SettingsProgress() }
            if let error = model.errors[.profile] {
                SettingsFailure(error: error, screen: .profile, discoveryOn: model.profile.discoveryOn,
                                disabled: !model.canSaveProfile, retry: save)
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
            } else if field != .contactDetail && SettingsValidation.textCount(value.wrappedValue) == 0 {
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
    @SettingsViewState private var retryOperation: RetryOperation = .matching
    private let navigation: SettingsNavigationActions
    private enum RetryOperation { case matching, discovery(Bool), bluetooth }

    public init(model: SettingsModel, navigation: SettingsNavigationActions) {
        self.model = model; self.navigation = navigation
    }

    public var body: some View {
        SettingsPage(model: model, screen: .discovery, title: .discoveryMatching, navigation: navigation) {
            OnboardingCard {
                Toggle(SettingsStrings.text(.discovery), isOn: Binding(
                    get: { model.profile.discoveryOn }, set: { enabled in
                        retryOperation = .discovery(enabled)
                        changeDiscovery(enabled)
                    }))
                    .disabled(model.isBusy || (!model.profile.discoveryOn && !model.canEnableDiscovery))
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
                        .disabled(model.isBusy)
                } else if model.bluetooth == .notRequested {
                    Button(SettingsStrings.text(.allowBluetooth)) {
                        retryOperation = .bluetooth
                        requestBluetooth()
                    }.disabled(model.isBusy)
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
                    .disabled(model.isBusy)
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
                                disabled: retryDisabled, retry: retry)
            }
            Button(SettingsStrings.text(.saveMatching)) {
                retryOperation = .matching
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

    private var retryDisabled: Bool {
        switch retryOperation {
        case .matching: !model.canSaveMatching
        case .discovery(let enabled): model.isBusy || (enabled && !model.canEnableDiscovery)
        case .bluetooth: model.isBusy
        }
    }

    @ViewBuilder
    private func checklistRow(_ prerequisite: DiscoveryPrerequisite) -> some View {
        let met = model.profile.prerequisites.isMet(prerequisite)
        let label = SettingsStrings.text(prerequisite.settingsLabel) + " · " + SettingsStrings.text(met ? .met : .missing)
        let error = model.errors[.discovery]
        let hasError = error?.code == .prerequisiteMissing && error?.fields.contains(prerequisite.rawValue) == true
        if (!met || hasError) && (prerequisite != .link || navigation.links != nil) {
            Button {
                if prerequisite == .link { navigation.links?() } else { navigation.editProfile() }
            } label: {
                Label(label, systemImage: "square").multilineTextAlignment(.leading)
            }.disabled(model.isBusy)
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
        switch retryOperation {
        case .matching: Task { await model.saveMatching() }
        case .discovery(let enabled): changeDiscovery(enabled)
        case .bluetooth: requestBluetooth()
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
                            }.accessibilityLabel(label + ": " + SettingsStrings.text(level.settingsLabel))
                        }
                        if SettingsErrorPresentation.affects(model.errors[.visibility], field: field) {
                            Text(SettingsStrings.text(.invalidField)).foregroundStyle(.red)
                        }
                    }
                }
                if let links = navigation.links {
                    Button(SettingsStrings.text(.linkVisibility), action: links)
                }
            }.disabled(model.isBusy)
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
                                disabled: model.isBusy) { Task { await model.saveVisibility() } }
            }
            Button(SettingsStrings.text(.saveVisibility)) { Task { await model.saveVisibility() } }
                .buttonStyle(.borderedProminent).disabled(model.isBusy)
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
            }.disabled(model.isBusy)
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
                        .disabled(model.isBusy)
                    Spacer()
                    if let save {
                        Button(SettingsStrings.text(.save), action: save).disabled(!canSave)
                    }
                }
                Text(SettingsStrings.text(title)).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                content
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .background(Color(uiColor: .systemGroupedBackground)).tint(.teal)
        .navigationBarBackButtonHidden(true)
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
        if dirty { confirmsDiscard = true } else { navigation.back() }
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
