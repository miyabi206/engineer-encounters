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
        EncounterScreen {
            EncounterSurfaceCard {
                let entries = AccountSettingsListComposition.entries(destinations: destinations)
                ForEach(entries, id: \.self) { entry in
                    let divider = entry != entries.last
                    switch entry {
                    case .discovery: row(.discoveryMatching, symbol: "person.2.fill", divider: divider, action: navigation.discovery)
                    case .visibility: row(.visibility, symbol: "globe", divider: divider, action: navigation.visibility)
                    case .dailyReport: row(.dailyReportTitle, symbol: "chart.bar.fill", divider: divider, action: destinations.dailyReport)
                    case .blockedUsers: row(.blockedUsers, symbol: "nosign", divider: divider, action: destinations.blockedUsers)
                    case .account: row(.account, symbol: "person.fill", divider: divider, action: destinations.account)
                    case .legal: row(.legal, symbol: "questionmark.circle", divider: divider, action: destinations.legal)
                    case .diagnostics:
                        if let diagnostics = destinations.diagnostics {
                            row(.diagnostics, symbol: "stethoscope", divider: divider, action: diagnostics)
                        }
                    }
                }
            }
            additionalRows
        }
        .navigationTitle(SettingsStrings.text(.settings))
        .navigationBarTitleDisplayMode(.large)
    }

    private func row(_ title: SettingsString, symbol: String, divider: Bool,
                     action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            EncounterIconRow(symbol: symbol, title: SettingsStrings.text(title), showsDivider: divider)
                .font(.headline)
        }
        .buttonStyle(EncounterPlainButtonStyle())
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
    @ScaledMetric(relativeTo: .body) private var inputHeight = 52.0
    @ScaledMetric(relativeTo: .body) private var introductionHeight = 120.0

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
                        Text(SettingsStrings.text(.emptyInterests)).foregroundStyle(EncounterPalette.inkSecondary)
                    }
                    Button(SettingsStrings.text(.retry)) { Task { await model.loadInterests() } }
                        .buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false)).disabled(model.isBusy)
                }
                EncounterFlowLayout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                    ForEach(model.interests) { interest in
                        EncounterChip(label: interest.label(language: locale.identifier),
                                      selected: model.selectedInterestIDs.contains(interest.id)) {
                            model.toggleInterest(interest.id)
                        }
                        .disabled(model.isSaving || !ProfileValidation.canToggleInterest(interest.id, selected: model.selectedInterestIDs))
                    }
                }
                Text(String(format: SettingsStrings.text(.interestCounter), locale: locale,
                            model.selectedInterestIDs.count, ProfileValidation.interestLimit))
                    .font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                Text(String(format: SettingsStrings.text(.interestLimit), locale: locale, ProfileValidation.interestLimit))
                    .font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                selectionFeedback(.interests)
            }
            OnboardingCard {
                SettingsPurposes(model: model, screen: .profile)
                selectionFeedback(.purposes)
            }
            OnboardingCard {
                textInput(.contactDetail, value: $model.contactDetail, limit: ProfileValidation.contactDetailLimit)
                Text(SettingsStrings.text(.contactPrivate)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
            }.disabled(model.isSaving)
            EncounterSurfaceCard {
                Button(action: navigation.visibility) {
                    EncounterIconRow(symbol: "eye", title: SettingsStrings.text(.visibility))
                }.buttonStyle(EncounterPlainButtonStyle()).disabled(model.isSaving)
            }
            if !model.removedPrerequisites.isEmpty || model.errors[.profile]?.code == .prerequisiteMissing {
                Text(SettingsStrings.text(model.profile.discoveryOn ? .discoveryRequired : .requiredInformation)).foregroundStyle(EncounterPalette.destructive)
                Button(SettingsStrings.text(.discoveryMatching), action: navigation.discovery)
                    .buttonStyle(EncounterButtonStyle(.secondary)).disabled(model.isSaving)
            }
        }
        .task { if !model.hasLoadedInterests { await model.loadInterests() } }
    }

    private func save() {
        Task { if await model.saveProfile() { navigation.back() } }
    }

    // Compose the shared field appearance while retaining the existing heading accessibility trait.
    @ViewBuilder
    private func textInput(_ field: ProfileField, value: Binding<String>, limit: Int) -> some View {
        let label = SettingsStrings.text(field == .contactDetail ? .optionalContact : field.settingsLabel)
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline).accessibilityAddTraits(.isHeader)
            if field == .introduction {
                TextField(label, text: value, axis: .vertical).lineLimit(4...10)
                    .textFieldStyle(.plain).accessibilityLabel(label)
                    .padding(16).frame(minHeight: introductionHeight, alignment: .topLeading)
                    .background(EncounterPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(EncounterPalette.controlOutline, lineWidth: 1))
            } else {
                TextField(label, text: value)
                    .textContentType(field == .displayName ? .nickname : nil)
                    .textFieldStyle(.plain).accessibilityLabel(label)
                    .padding(16).frame(minHeight: max(44, inputHeight))
                    .background(EncounterPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(EncounterPalette.controlOutline, lineWidth: 1))
            }
            Text(SettingsStrings.counter(value.wrappedValue, limit: limit)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
            if SettingsValidation.textCount(value.wrappedValue) > limit {
                Text(String(format: SettingsStrings.text(.tooLong), limit)).foregroundStyle(EncounterPalette.destructive)
            } else if model.removedPrerequisites.contains(field) {
                Text(SettingsStrings.text(.discoveryRequired)).foregroundStyle(EncounterPalette.destructive)
            } else if model.profile.discoveryOn && field != .contactDetail && SettingsValidation.textCount(value.wrappedValue) == 0 {
                Text(SettingsStrings.text(.requiredField)).foregroundStyle(EncounterPalette.destructive)
            } else if SettingsErrorPresentation.affects(model.errors[.profile], field: field) {
                Text(SettingsStrings.text(.invalidField)).foregroundStyle(EncounterPalette.destructive)
            }
        }
    }

    @ViewBuilder
    private func selectionFeedback(_ field: ProfileField) -> some View {
        if model.removedPrerequisites.contains(field) {
            Text(SettingsStrings.text(.discoveryRequired)).foregroundStyle(EncounterPalette.destructive)
        } else if model.invalidProfileFields.contains(field) {
            Text(SettingsStrings.text(field == .purposes ? .purposeRequired : .selectionGuidance)).foregroundStyle(EncounterPalette.destructive)
        } else if SettingsErrorPresentation.affects(model.errors[.profile], field: field) {
            Text(SettingsStrings.text(.invalidField)).foregroundStyle(EncounterPalette.destructive)
        }
    }

    private func heading(_ key: SettingsString) -> some View {
        Text(SettingsStrings.text(key)).font(.headline).accessibilityAddTraits(.isHeader)
    }
}

@MainActor
public struct DiscoveryAndMatchingView: View {
    @ObservedObject private var model: SettingsModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var checklistTarget = 44.0
    private let navigation: SettingsNavigationActions

    public init(model: SettingsModel, navigation: SettingsNavigationActions) {
        self.model = model; self.navigation = navigation
    }

    public var body: some View {
        SettingsPage(model: model, screen: .discovery, title: .discoveryMatching, navigation: navigation, retry: retry) {
            OnboardingCard {
                Toggle(SettingsStrings.text(.discovery), isOn: Binding(
                    get: { model.profile.discoveryOn }, set: { enabled in
                        changeDiscovery(enabled)
                    }))
                    .disabled(model.isSaving || (!model.profile.discoveryOn && !model.canEnableDiscovery))
                    .accessibilityLabel(SettingsStrings.text(.discovery))
                    .tint(EncounterPalette.accent).font(.headline)
                Text(SettingsStrings.text(.discoveryOffExplanation)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                if model.showsDiscoveryExplanation && !model.profile.discoveryOn {
                    ForEach([SettingsString.promise, .background, .dailyReport, .alternatives,
                             .forceQuit, .firstUnlock, .oneSided], id: \.self) { key in
                        EncounterIconRow(symbol: explanationSymbol(key), title: SettingsStrings.text(key),
                                         showsChevron: false, showsDivider: key != .oneSided)
                            .font(.callout)
                    }
                }
            }
            OnboardingCard {
                Text(SettingsStrings.text(.checklist)).font(.headline).accessibilityAddTraits(.isHeader)
                if !model.profile.prerequisites.canEnableDiscovery {
                    Text(SettingsStrings.text(.requiredInformation)).foregroundStyle(EncounterPalette.inkSecondary)
                }
                ForEach(DiscoveryPrerequisite.allCases, id: \.self) { prerequisite in
                    checklistRow(prerequisite)
                }
                if !model.profile.prerequisites.link {
                    Text(SettingsStrings.text(.linkRequired)).foregroundStyle(EncounterPalette.inkSecondary)
                }
            }
            OnboardingCard {
                EncounterSymbolTile(symbol: "dot.radiowaves.left.and.right")
                Text(SettingsStrings.text(.bluetoothPurpose))
                Text(SettingsStrings.text(bluetoothLabel)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                if model.bluetooth.needsRecovery {
                    Button(SettingsStrings.text(.bluetoothRecovery), action: navigation.bluetoothRecovery)
                        .buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false)).disabled(model.isSaving)
                } else if model.allowsDiscoveryActivation && model.bluetooth == .notRequested {
                    Button(SettingsStrings.text(.allowBluetooth)) {
                        requestBluetooth()
                    }.buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false)).disabled(model.isSaving)
                }
            }
            OnboardingCard {
                SettingsPurposes(model: model, screen: .discovery)
                if model.matchingPurposes.isEmpty {
                    Text(SettingsStrings.text(.purposeRequired)).foregroundStyle(EncounterPalette.destructive)
                } else if SettingsErrorPresentation.affects(model.errors[.discovery], field: .purposes) {
                    Text(SettingsStrings.text(.invalidField)).foregroundStyle(EncounterPalette.destructive)
                }
            }
            OnboardingCard {
                Text(SettingsStrings.text(.threshold)).font(.headline).accessibilityAddTraits(.isHeader)
                let layout = dynamicTypeSize.isAccessibilitySize ?
                    AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) :
                    AnyLayout(HStackLayout(spacing: 16))
                layout {
                    EncounterStepper(SettingsStrings.text(.threshold), value: $model.minimumSharedInterests,
                        in: ProfileValidation.sharedInterestRange,
                        decreaseLabel: SettingsStrings.threshold(model.minimumSharedInterests - 1),
                        increaseLabel: SettingsStrings.threshold(model.minimumSharedInterests + 1))
                        .disabled(model.isSaving)
                        .accessibilityLabel(SettingsStrings.text(.threshold))
                        .accessibilityValue(SettingsStrings.threshold(model.minimumSharedInterests))
                    Text(SettingsStrings.threshold(model.minimumSharedInterests))
                }
                if !ProfileValidation.sharedInterestRange.contains(model.minimumSharedInterests) ||
                    SettingsErrorPresentation.affectsThreshold(model.errors[.discovery]) {
                    Text(SettingsStrings.text(.invalidField)).foregroundStyle(EncounterPalette.destructive)
                }
            }
            Text(SettingsStrings.text(.matchingExplanation)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
            Button(SettingsStrings.text(.saveMatching)) {
                Task { await model.saveMatching() }
            }.buttonStyle(EncounterButtonStyle(.primary)).disabled(!model.canSaveMatching)
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
                checklistContent(label: label, met: met, actionable: true)
            }.buttonStyle(EncounterPlainButtonStyle()).disabled(model.isSaving)
        } else {
            checklistContent(label: label, met: met, actionable: false)
        }
        if hasError { Text(SettingsStrings.text(.requiredInformation)).foregroundStyle(EncounterPalette.destructive) }
    }

    private func checklistContent(label: String, met: Bool, actionable: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? EncounterPalette.accent : EncounterPalette.inkSecondary).accessibilityHidden(true)
            Text(label).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if actionable {
                Image(systemName: "chevron.right").foregroundStyle(EncounterPalette.inkSecondary).accessibilityHidden(true)
            }
        }.frame(minHeight: max(44, checklistTarget)).contentShape(Rectangle())
    }

    private func explanationSymbol(_ key: SettingsString) -> String {
        switch key {
        case .promise: "iphone"
        case .background: "clock"
        case .dailyReport: "chart.bar.fill"
        case .alternatives: "qrcode"
        case .forceQuit: "exclamationmark.circle"
        case .firstUnlock: "lock.open"
        default: "person.2.fill"
        }
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
            ForEach(ProfileField.allCases, id: \.self) { field in
                OnboardingCard {
                    let label = SettingsStrings.text(field == .interests ? .visibilityInterests : field.settingsLabel)
                    Text(label).font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(VisibilityLevel.allCases, id: \.self) { level in
                        EncounterRadioRow(label: SettingsStrings.text(level.settingsLabel),
                                         selected: SettingsValidation.visibility(field, in: model.visibility) == level) {
                            model.visibility[field] = level
                        }.accessibilityLabel(SettingsStrings.fieldMessage(label, SettingsStrings.text(level.settingsLabel)))
                    }
                    if SettingsErrorPresentation.affects(model.errors[.visibility], field: field) {
                        Text(SettingsStrings.text(.invalidField)).foregroundStyle(EncounterPalette.destructive)
                    }
                }.disabled(model.isSaving)
            }
            if let links = navigation.links {
                EncounterSurfaceCard {
                    Button(action: links) {
                        EncounterIconRow(symbol: "link", title: SettingsStrings.text(.linkVisibility))
                    }.buttonStyle(EncounterPlainButtonStyle())
                }.disabled(model.isSaving)
            }
            OnboardingCard {
                ForEach([VisibilityLevel.everyoneEligible, .compatibleOnly, .private], id: \.self) { level in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SettingsStrings.text(level.settingsLabel)).font(.headline)
                        Text(SettingsStrings.text(explanation(level)))
                    }
                }
                Text(SettingsStrings.text(.appliesToPast))
            }
            Button(SettingsStrings.text(.saveVisibility)) { Task { await model.saveVisibility() } }
                .buttonStyle(EncounterButtonStyle(.primary)).disabled(model.isSaving)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Text(SettingsStrings.text(.purposes)).font(.headline).accessibilityAddTraits(.isHeader)
        EncounterFlowLayout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
            ForEach(ProfilePurpose.allCases, id: \.self) { purpose in
                EncounterChip(label: SettingsStrings.text(purpose == .discovery ? .discoveryPurpose : .collaborationPurpose),
                              selected: (screen == .profile ? model.selectedPurposes : model.matchingPurposes).contains(purpose)) {
                    model.togglePurpose(purpose, screen: screen)
                }.disabled(model.isSaving)
            }
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
    var retry: (@MainActor () -> Void)? = nil
    @ViewBuilder let content: Content
    @SettingsViewState private var confirmsDiscard = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        EncounterScreen {
            let headerLayout = dynamicTypeSize.isAccessibilitySize ?
                AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            headerLayout {
                if screen == .profile {
                    Button(SettingsStrings.text(.cancel), action: leave)
                        .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false)).disabled(model.isSaving)
                } else {
                    EncounterBackButton(label: SettingsStrings.text(.back), action: leave).disabled(model.isSaving)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if let save {
                    Button(action: save) { Text(SettingsStrings.text(.save)).bold() }
                        .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false)).disabled(!canSave)
                }
            }
            Text(SettingsStrings.text(title)).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            if save != nil || screen != .profile {
                if model.isSaving { SettingsProgress() }
                if let error = model.errors[screen] {
                    SettingsFailure(error: error, screen: screen, discoveryOn: model.profile.discoveryOn,
                        disabled: !model.canRetry(screen), fallback: screen == .visibility ? .saveError : model.errorFallback(screen)) {
                        if let retry { retry() }
                        else if screen == .visibility { Task { await model.retry(.visibility) } }
                        else { Task { if await model.retry(screen) { navigation.back() } } }
                    }
                    SettingsAppliedChanges(model: model, screen: screen)
                }
            }
            content
        }
        .navigationBarTitleDisplayMode(.inline)
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
        EncounterProgress(SettingsStrings.text(.loading))
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
        EncounterInlineError(message: SettingsStrings.text(error.code == .unavailable ? fallback :
            SettingsErrorPresentation.message(error, screen: screen, discoveryOn: discoveryOn)),
            retryLabel: SettingsStrings.text(.retry), disabled: disabled, retry: retry) {
            if error.code == .prerequisiteMissing && error.fields.contains("link") {
                Text(SettingsStrings.text(.linkRequired)).foregroundStyle(EncounterPalette.destructive)
            }
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
            EncounterSurfaceCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill").foregroundStyle(EncounterPalette.accent).accessibilityHidden(true)
                    Text(SettingsStrings.text(.partialSave)).font(.headline).accessibilityAddTraits(.isHeader)
                }
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in Text(message) }
            }
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
