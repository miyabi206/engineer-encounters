import SwiftUI

// Resolve the property wrapper rather than the SDK's same-named compiler macro.
typealias OnboardingViewState<Value> = State<Value>

@MainActor
public struct OnboardingView: View {
    @ObservedObject private var model: OnboardingModel

    public init(model: OnboardingModel) { self.model = model }

    public var body: some View {
        switch model.step {
        case .basics: ProfileBasicsView(model: model)
        case .interests: InterestsAndPurposesView(model: model)
        case .firstLink: FirstLinkView(model: model)
        case .permissions: DiscoveryPermissionsView(model: model)
        }
    }
}

@MainActor
public struct ProfileBasicsView: View {
    @ObservedObject private var model: OnboardingModel

    public init(model: OnboardingModel) { self.model = model }

    public var body: some View {
        OnboardingPage(title: .basicsTitle, subtitle: .basicsSubtitle, isBusy: model.isBusy, back: model.back) {
            OnboardingCard {
                EncounterField(OnboardingStrings.text(.displayName), text: $model.displayName,
                    counter: OnboardingStrings.counter(model.displayName, limit: ProfileValidation.displayNameLimit),
                    error: fieldError(value: model.displayName, field: .displayName, limit: ProfileValidation.displayNameLimit),
                    textContentType: .nickname)
                EncounterField(OnboardingStrings.text(.introduction), text: $model.introduction, multiline: true,
                    counter: OnboardingStrings.counter(model.introduction, limit: ProfileValidation.introductionLimit),
                    error: fieldError(value: model.introduction, field: .introduction, limit: ProfileValidation.introductionLimit))
            }
            .disabled(model.isBusy)
            if !model.canContinueBasics && !model.isBusy {
                Text(OnboardingStrings.text(.basicsGuidance)).foregroundStyle(EncounterPalette.inkSecondary)
            }
            if model.isSaving { OnboardingProgress() }
            if let error = model.actionError {
                OnboardingActionError(error: error, disabled: !model.canContinueBasics) {
                    Task { await model.saveBasics() }
                }
            }
        } bottomBar: {
            Button(OnboardingStrings.text(.continueAction)) {
                Task { await model.saveBasics() }
            }
            .buttonStyle(EncounterButtonStyle(.primary))
            .disabled(!model.canContinueBasics)
        }
    }

    private func fieldError(value: String, field: ProfileField, limit: Int) -> String? {
        if ProfileValidation.characterCount(value) > limit {
            String(format: OnboardingStrings.text(.tooLong), limit)
        } else if !value.isEmpty && ProfileValidation.trimmed(value).isEmpty {
            OnboardingStrings.text(.requiredField)
        } else if model.actionError?.affects(field) == true {
            OnboardingStrings.text(.invalidField)
        } else { nil }
    }
}

@MainActor
public struct InterestsAndPurposesView: View {
    @ObservedObject private var model: OnboardingModel
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(model: OnboardingModel) { self.model = model }

    public var body: some View {
        OnboardingPage(title: .interestsTitle, isBusy: model.isBusy, back: model.back) {
            OnboardingCard {
                EncounterSectionHeader(OnboardingStrings.text(.interests))
                if model.isLoadingInterests { OnboardingProgress() }
                if let error = model.interestLoadError {
                    OnboardingActionError(error: error, disabled: model.isBusy, fallback: .listError) {
                        Task { await model.loadInterests() }
                    }
                } else if model.shouldRetryInterestLoad {
                    if model.hasLoadedInterests {
                        Text(OnboardingStrings.text(.emptyInterests)).foregroundStyle(EncounterPalette.inkSecondary)
                    }
                    Button(OnboardingStrings.text(.retry)) {
                        Task { await model.loadInterests() }
                    }.buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false)).disabled(model.isBusy)
                }
                EncounterFlowLayout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                    ForEach(model.interests) { interest in
                        InterestChip(label: interest.label(language: locale.identifier),
                                     selected: model.selectedInterestIDs.contains(interest.id)) {
                            model.toggleInterest(interest.id)
                        }
                        .disabled(model.isBusy || !ProfileValidation.canToggleInterest(
                            interest.id, selected: model.selectedInterestIDs))
                    }
                }
                Text(String(format: OnboardingStrings.text(.interestCounter), locale: locale,
                            model.selectedInterestIDs.count, ProfileValidation.interestLimit))
                    .font(.footnote).foregroundStyle(EncounterPalette.inkSecondary)
                Text(String(format: OnboardingStrings.text(.interestLimit), locale: locale, ProfileValidation.interestLimit))
                    .font(.footnote).foregroundStyle(EncounterPalette.inkSecondary)
            }
            OnboardingCard {
                EncounterSectionHeader(OnboardingStrings.text(.purposes))
                ForEach(ProfilePurpose.allCases, id: \.self) { purpose in
                    SelectionControl(label: OnboardingStrings.text(
                        purpose == .discovery ? .discoveryPurpose : .collaborationPurpose),
                                     selected: model.selectedPurposes.contains(purpose)) {
                        model.togglePurpose(purpose)
                    }.disabled(model.isBusy)
                }
            }
            if !model.canContinueInterests && !model.isBusy {
                Text(OnboardingStrings.text(.selectionGuidance)).foregroundStyle(EncounterPalette.inkSecondary)
            }
            if model.isSaving { OnboardingProgress() }
            if let error = model.actionError {
                OnboardingActionError(error: error, disabled: !model.canContinueInterests) {
                    Task { await model.saveSelections() }
                }
            }
        } bottomBar: {
            Button(OnboardingStrings.text(.continueAction)) {
                Task { await model.saveSelections() }
            }
            .buttonStyle(EncounterButtonStyle(.primary))
            .disabled(!model.canContinueInterests)
        }
        .task {
            if !model.hasLoadedInterests { await model.loadInterests() }
        }
    }
}

@MainActor
public struct DiscoveryPermissionsView: View {
    @ObservedObject private var model: OnboardingModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var checklistTarget = 44.0
    public init(model: OnboardingModel) { self.model = model }

    public var body: some View {
        OnboardingPage(title: .enableDiscovery, isBusy: model.isBusy, back: model.back) {
            EncounterMark(signals: true).frame(maxWidth: .infinity)
            OnboardingCard {
                ForEach([OnboardingString.promise, .background, .dailyReport, .alternatives,
                         .forceQuit, .firstUnlock, .oneSided], id: \.self) { key in
                    EncounterIconRow(symbol: explanationSymbol(key), title: OnboardingStrings.text(key),
                        showsChevron: false, showsDivider: key != .oneSided)
                }
            }
            OnboardingCard {
                EncounterSectionHeader(OnboardingStrings.text(.checklist))
                ForEach(DiscoveryPrerequisite.allCases, id: \.self) { prerequisite in
                    checklistRow(prerequisite)
                }
                if !model.profile.prerequisites.link {
                    Text(OnboardingStrings.text(.linkRequired)).foregroundStyle(EncounterPalette.inkSecondary)
                    if model.canAddLink {
                        Button(OnboardingStrings.text(.addLink)) { model.edit(.link) }
                            .buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false))
                    }
                }
            }
            OnboardingCard {
                let layout = dynamicTypeSize.isAccessibilitySize ?
                    AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) :
                    AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                layout {
                    HStack(alignment: .top, spacing: 12) {
                        EncounterSymbolTile(symbol: "dot.radiowaves.left.and.right")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(OnboardingStrings.text(.bluetoothPurpose))
                            Text(OnboardingStrings.text(bluetoothLabel)).font(.footnote)
                                .foregroundStyle(EncounterPalette.inkSecondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(OnboardingStrings.text(.allowBluetooth)) {
                        Task { await model.requestBluetooth() }
                    }
                    .buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false))
                    .disabled(model.isBusy || model.bluetooth == .available)
                }
                if model.bluetooth.needsRecovery {
                    Button(OnboardingStrings.text(.bluetoothRecovery)) { model.recoverBluetooth() }
                        .buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false))
                        .disabled(model.isBusy)
                }
            }
            if !model.profile.discoveryOn { Text(OnboardingStrings.text(.discoveryOff)) }
            if model.isSaving { OnboardingProgress() }
            if let error = model.actionError {
                OnboardingActionError(error: error, disabled: model.isBusy ||
                    (model.failedOperation == .finish(discovery: true) && !model.canEnableDiscovery),
                    fallback: model.errorFallback) {
                    Task { await model.retry() }
                }
            }
        } bottomBar: {
            VStack(spacing: 8) {
                Button(OnboardingStrings.text(.enableDiscovery)) {
                    Task { await model.finish(discovery: true) }
                }
                .buttonStyle(EncounterButtonStyle(.primary))
                .disabled(!model.canEnableDiscovery)
                Button(OnboardingStrings.text(.notNow)) {
                    Task { await model.finish(discovery: false) }
                }
                .buttonStyle(EncounterButtonStyle(.tertiary))
                .disabled(model.isBusy)
            }
        }
    }

    private func explanationSymbol(_ key: OnboardingString) -> String {
        switch key {
        case .promise: "iphone"
        case .background: "clock"
        case .dailyReport: "chart.bar"
        case .alternatives: "qrcode"
        case .forceQuit: "exclamationmark.circle"
        case .firstUnlock: "lock.open"
        default: "person.2"
        }
    }

    private var bluetoothLabel: OnboardingString {
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
        let label = OnboardingStrings.text(prerequisite.labelKey)
        let status = OnboardingStrings.text(met ? .met : .missing)
        if !met && (prerequisite != .link || model.linkModel != nil) {
            Button { model.edit(prerequisite) } label: {
                prerequisiteContent(label: label, status: status, met: met, actionable: true)
            }.buttonStyle(.plain).disabled(model.isBusy)
        } else {
            prerequisiteContent(label: label, status: status, met: met, actionable: false)
        }
    }

    private func prerequisiteContent(label: String, status: String, met: Bool, actionable: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? EncounterPalette.accent : EncounterPalette.inkSecondary).accessibilityHidden(true)
            Text(OnboardingStrings.labelStatus(label, status)).frame(maxWidth: .infinity, alignment: .leading)
            if actionable { Image(systemName: "chevron.right").foregroundStyle(EncounterPalette.inkSecondary).accessibilityHidden(true) }
        }.frame(minHeight: max(44, checklistTarget)).foregroundStyle(EncounterPalette.ink)
            .contentShape(Rectangle())
    }
}

extension DiscoveryPrerequisite {
    var labelKey: OnboardingString {
        switch self {
        case .displayName: .displayName
        case .introduction: .introduction
        case .interest: .interests
        case .link: .link
        }
    }
}

@MainActor
private struct InterestChip: View {
    let label: String
    let selected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        EncounterChip(label: label, selected: selected, action: action)
    }
}

@MainActor
struct SelectionControl: View {
    let label: String
    let selected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        EncounterCheckRow(label: label, selected: selected, action: action)
    }
}

@MainActor
struct OnboardingPage<Content: View>: View {
    let title: OnboardingString
    let isBusy: Bool
    let back: @MainActor () -> Void
    let content: Content
    private let subtitle: OnboardingString?
    private let bottomBar: AnyView?

    init(title: OnboardingString, isBusy: Bool, back: @escaping @MainActor () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.isBusy = isBusy; self.back = back; self.content = content()
        subtitle = nil; bottomBar = nil
    }

    init<BottomBar: View>(title: OnboardingString, subtitle: OnboardingString? = nil,
         isBusy: Bool, back: @escaping @MainActor () -> Void,
         @ViewBuilder content: () -> Content, @ViewBuilder bottomBar: () -> BottomBar) {
        self.title = title; self.subtitle = subtitle; self.isBusy = isBusy; self.back = back
        self.content = content(); self.bottomBar = AnyView(bottomBar())
    }

    var body: some View {
        if let bottomBar {
            EncounterScreen(title: OnboardingStrings.text(title), subtitle: subtitle.map(OnboardingStrings.text),
                alignment: .centered, backLabel: OnboardingStrings.text(.back), backDisabled: isBusy, onBack: back) {
                    content
            } bottomBar: {
                bottomBar
            }
        } else {
            EncounterScreen(title: OnboardingStrings.text(title), alignment: .centered,
                backLabel: OnboardingStrings.text(.back), backDisabled: isBusy, onBack: back) {
                    content
            }
        }
    }
}

@MainActor
struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        EncounterSurfaceCard { content }
    }
}

@MainActor
struct OnboardingProgress: View {
    var body: some View {
        EncounterProgress(OnboardingStrings.text(.loading))
    }
}

@MainActor
struct OnboardingActionError: View {
    let error: ProfileActionError
    let disabled: Bool
    var fallback: OnboardingString = .saveError
    let retry: @MainActor () -> Void

    var body: some View {
        EncounterInlineError(message: error.code == .unavailable ? OnboardingStrings.text(fallback) : OnboardingStrings.error(error),
            retryLabel: OnboardingStrings.text(.retry), disabled: disabled, retry: retry) {
            ForEach(ProfileField.allCases.filter { error.affects($0) }, id: \.self) { field in
                Text(OnboardingStrings.fieldMessage(OnboardingStrings.text(field.labelKey), OnboardingStrings.text(.invalidField)))
                    .foregroundStyle(EncounterPalette.destructive)
            }
            if error.fields.contains("link") {
                Text(OnboardingStrings.text(.linkRequired)).foregroundStyle(EncounterPalette.destructive)
            }
        }
    }
}

extension ProfileField {
    var labelKey: OnboardingString {
        switch self {
        case .displayName: .displayName
        case .introduction: .introduction
        case .interests: .interests
        case .purposes: .purposes
        case .contactDetail: .contactDetail
        }
    }
}
