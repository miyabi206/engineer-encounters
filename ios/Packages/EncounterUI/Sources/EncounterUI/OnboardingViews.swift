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
        case .permissions: DiscoveryPermissionsView(model: model)
        }
    }
}

@MainActor
public struct ProfileBasicsView: View {
    @ObservedObject private var model: OnboardingModel

    public init(model: OnboardingModel) { self.model = model }

    public var body: some View {
        OnboardingPage(title: .basicsTitle, isBusy: model.isBusy, back: model.back) {
            Text(OnboardingStrings.text(.basicsSubtitle))
            OnboardingCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(OnboardingStrings.text(.displayName)).font(.headline)
                    TextField(OnboardingStrings.text(.displayName), text: $model.displayName)
                        .textContentType(.nickname)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(OnboardingStrings.text(.displayName))
                    fieldFeedback(value: model.displayName, field: .displayName,
                                  limit: ProfileValidation.displayNameLimit)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(OnboardingStrings.text(.introduction)).font(.headline)
                    TextField(OnboardingStrings.text(.introduction), text: $model.introduction, axis: .vertical)
                        .lineLimit(4...10)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(OnboardingStrings.text(.introduction))
                    fieldFeedback(value: model.introduction, field: .introduction,
                                  limit: ProfileValidation.introductionLimit)
                }
            }
            .disabled(model.isBusy)
            if !model.canContinueBasics && !model.isBusy {
                Text(OnboardingStrings.text(.basicsGuidance)).foregroundStyle(.secondary)
            }
            if model.isSaving { OnboardingProgress() }
            if let error = model.actionError {
                OnboardingActionError(error: error, disabled: !model.canContinueBasics) {
                    Task { await model.saveBasics() }
                }
            }
            Button(OnboardingStrings.text(.continueAction)) {
                Task { await model.saveBasics() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canContinueBasics)
        }
    }

    @ViewBuilder
    private func fieldFeedback(value: String, field: ProfileField, limit: Int) -> some View {
        Text(OnboardingStrings.counter(value, limit: limit))
            .font(.caption)
            .foregroundStyle(.secondary)
        if ProfileValidation.characterCount(value) > limit {
            Text(String(format: OnboardingStrings.text(.tooLong), limit))
                .foregroundStyle(.red)
        } else if !value.isEmpty && ProfileValidation.trimmed(value).isEmpty {
            Text(OnboardingStrings.text(.requiredField)).foregroundStyle(.red)
        } else if model.actionError?.affects(field) == true {
            Text(OnboardingStrings.text(.invalidField)).foregroundStyle(.red)
        }
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
                Text(OnboardingStrings.text(.interests))
                    .font(.headline).accessibilityAddTraits(.isHeader)
                if model.isLoadingInterests { OnboardingProgress() }
                if let error = model.interestLoadError {
                    OnboardingActionError(error: error, disabled: model.isBusy, fallback: .listError) {
                        Task { await model.loadInterests() }
                    }
                } else if model.shouldRetryInterestLoad {
                    if model.hasLoadedInterests {
                        Text(OnboardingStrings.text(.emptyInterests)).foregroundStyle(.secondary)
                    }
                    Button(OnboardingStrings.text(.retry)) {
                        Task { await model.loadInterests() }
                    }.disabled(model.isBusy)
                }
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ?
                          [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 140))], alignment: .leading) {
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
                    .font(.caption).foregroundStyle(.secondary)
                Text(String(format: OnboardingStrings.text(.interestLimit), locale: locale, ProfileValidation.interestLimit)).font(.caption).foregroundStyle(.secondary)
            }
            OnboardingCard {
                Text(OnboardingStrings.text(.purposes))
                    .font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(ProfilePurpose.allCases, id: \.self) { purpose in
                    SelectionControl(label: OnboardingStrings.text(
                        purpose == .discovery ? .discoveryPurpose : .collaborationPurpose),
                                     selected: model.selectedPurposes.contains(purpose)) {
                        model.togglePurpose(purpose)
                    }.disabled(model.isBusy)
                }
            }
            if !model.canContinueInterests && !model.isBusy {
                Text(OnboardingStrings.text(.selectionGuidance)).foregroundStyle(.secondary)
            }
            if model.isSaving { OnboardingProgress() }
            if let error = model.actionError {
                OnboardingActionError(error: error, disabled: !model.canContinueInterests) {
                    Task { await model.saveSelections() }
                }
            }
            Button(OnboardingStrings.text(.continueAction)) {
                Task { await model.saveSelections() }
            }
            .buttonStyle(.borderedProminent)
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
    public init(model: OnboardingModel) { self.model = model }

    public var body: some View {
        OnboardingPage(title: .enableDiscovery, isBusy: model.isBusy, back: model.back) {
            OnboardingCard {
                ForEach([OnboardingString.promise, .background, .dailyReport, .alternatives,
                         .forceQuit, .firstUnlock, .oneSided], id: \.self) { key in
                    Text(OnboardingStrings.text(key))
                }
            }
            OnboardingCard {
                Text(OnboardingStrings.text(.checklist))
                    .font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(DiscoveryPrerequisite.allCases, id: \.self) { prerequisite in
                    checklistRow(prerequisite)
                }
                if !model.profile.prerequisites.link {
                    Text(OnboardingStrings.text(.linkRequired)).foregroundStyle(.secondary)
                    if model.canAddLink {
                        Button(OnboardingStrings.text(.addLink)) { model.edit(.link) }
                    }
                }
            }
            OnboardingCard {
                Text(OnboardingStrings.text(.bluetoothPurpose))
                Text(OnboardingStrings.text(bluetoothLabel))
                if model.bluetooth.needsRecovery {
                    Button(OnboardingStrings.text(.bluetoothRecovery)) { model.recoverBluetooth() }
                        .disabled(model.isBusy)
                }
                Button(OnboardingStrings.text(.allowBluetooth)) {
                    Task { await model.requestBluetooth() }
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || model.bluetooth == .available)
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
            Button(OnboardingStrings.text(.enableDiscovery)) {
                Task { await model.finish(discovery: true) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canEnableDiscovery)
            Button(OnboardingStrings.text(.notNow)) {
                Task { await model.finish(discovery: false) }
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)
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
        if !met && prerequisite != .link {
            Button { model.edit(prerequisite) } label: {
                Label(OnboardingStrings.labelStatus(label, status), systemImage: "square")
            }.disabled(model.isBusy)
        } else {
            Label(OnboardingStrings.labelStatus(label, status), systemImage: met ? "checkmark.square" : "square")
        }
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
        Button(action: action) {
            HStack {
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
                Text(label).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 8)
            .background(selected ? Color.teal.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
struct SelectionControl: View {
    let label: String
    let selected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .accessibilityHidden(true)
                Text(label).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
struct OnboardingPage<Content: View>: View {
    let title: OnboardingString
    let isBusy: Bool
    let back: @MainActor () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button(OnboardingStrings.text(.back), action: back).disabled(isBusy)
                Text(OnboardingStrings.text(title))
                    .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(.teal)
    }
}

@MainActor
struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.secondary.opacity(0.2)))
    }
}

@MainActor
struct OnboardingProgress: View {
    var body: some View {
        ProgressView(OnboardingStrings.text(.loading))
            .accessibilityLabel(OnboardingStrings.text(.loading))
    }
}

@MainActor
struct OnboardingActionError: View {
    let error: ProfileActionError
    let disabled: Bool
    var fallback: OnboardingString = .saveError
    let retry: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error.code == .unavailable ? OnboardingStrings.text(fallback) : OnboardingStrings.error(error))
                .foregroundStyle(.red)
            ForEach(ProfileField.allCases.filter { error.affects($0) }, id: \.self) { field in
                Text(OnboardingStrings.fieldMessage(OnboardingStrings.text(field.labelKey), OnboardingStrings.text(.invalidField)))
                    .foregroundStyle(.red)
            }
            if error.fields.contains("link") {
                Text(OnboardingStrings.text(.linkRequired)).foregroundStyle(.red)
            }
            Button(OnboardingStrings.text(.retry), action: retry).disabled(disabled)
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
