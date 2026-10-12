import Combine
import Foundation

public enum OnboardingOperation: Equatable, Sendable {
    case basics, selections, bluetooth, finish(discovery: Bool)
}

@MainActor
public final class OnboardingModel: ObservableObject {
    @Published public private(set) var profile: OwnProfileState
    @Published public private(set) var step: OnboardingStep
    @Published public var displayName: String { didSet { if displayName != oldValue { actionError = nil } } }
    @Published public var introduction: String { didSet { if introduction != oldValue { actionError = nil } } }
    @Published public var selectedInterestIDs: Set<String> { didSet { if selectedInterestIDs != oldValue { actionError = nil } } }
    @Published public var selectedPurposes: Set<ProfilePurpose> { didSet { if selectedPurposes != oldValue { actionError = nil } } }
    @Published public private(set) var interests: [InterestOption]
    @Published public private(set) var bluetooth: BluetoothPermissionState
    @Published public private(set) var isSaving = false
    @Published public private(set) var isLoadingInterests = false
    @Published public private(set) var hasLoadedInterests: Bool
    @Published public private(set) var interestLoadError: ProfileActionError?
    @Published public private(set) var actionError: ProfileActionError?

    @Published public private(set) var hasCompleted = false
    @Published public private(set) var failedOperation: OnboardingOperation?

    private let actions: ProfileActions
    private let onExit: @MainActor () -> Void
    private let onFinish: @MainActor (Bool) -> Void
    private let onBluetoothRecovery: @MainActor () -> Void
    private let onAddLink: (@MainActor () -> Void)?

    public init(profile: OwnProfileState, interests: [InterestOption]? = nil,
                bluetooth: BluetoothPermissionState = .notRequested, actions: ProfileActions,
                onExit: @escaping @MainActor () -> Void,
                onFinish: @escaping @MainActor (Bool) -> Void,
                onBluetoothRecovery: @escaping @MainActor () -> Void,
                onAddLink: (@MainActor () -> Void)? = nil) {
        self.profile = profile
        step = OnboardingStep.unfinishedStep(profile: profile)
        displayName = profile.displayName
        introduction = profile.introduction
        selectedInterestIDs = interests.map { profile.interestIDs.intersection(Set($0.map(\.id))) } ?? profile.interestIDs
        selectedPurposes = profile.purposes
        self.interests = interests ?? []
        hasLoadedInterests = interests != nil
        self.bluetooth = bluetooth
        self.actions = actions
        self.onExit = onExit
        self.onFinish = onFinish
        self.onBluetoothRecovery = onBluetoothRecovery
        self.onAddLink = onAddLink
    }

    public var isBusy: Bool { isSaving || isLoadingInterests || hasCompleted }
    public var shouldRetryInterestLoad: Bool { !isLoadingInterests && (!hasLoadedInterests || interests.isEmpty) }
    public var canContinueBasics: Bool {
        !isBusy && ProfileValidation.invalidBasics(displayName: displayName, introduction: introduction).isEmpty
    }
    public var canContinueInterests: Bool {
        !isBusy && hasLoadedInterests && interestLoadError == nil &&
            ProfileValidation.validSelections(interestIDs: selectedInterestIDs,
                                               purposes: selectedPurposes, options: interests)
    }
    public var canEnableDiscovery: Bool {
        !isBusy && profile.prerequisites.canEnableDiscovery && bluetooth.canEnableDiscovery
    }
    public var canAddLink: Bool { onAddLink != nil && !isBusy }

    /// Refresh confirmed prerequisites after returning from a caller-owned editor.
    public func receive(profile fresh: OwnProfileState, bluetooth: BluetoothPermissionState? = nil) {
        if displayName == profile.displayName { displayName = fresh.displayName }
        if introduction == profile.introduction { introduction = fresh.introduction }
        if selectedInterestIDs == profile.interestIDs { selectedInterestIDs = fresh.interestIDs }
        if selectedPurposes == profile.purposes { selectedPurposes = fresh.purposes }
        profile = fresh
        if let bluetooth { self.bluetooth = bluetooth }
    }

    public func back() {
        guard !isBusy else { return }
        actionError = nil
        switch step {
        case .basics:
            hasCompleted = true
            onExit()
        case .interests: step = .basics
        case .permissions: step = .interests
        }
    }

    public func edit(_ prerequisite: DiscoveryPrerequisite) {
        guard !isBusy else { return }
        actionError = nil
        switch prerequisite {
        case .displayName, .introduction: step = .basics
        case .interest: step = .interests
        case .link: onAddLink?()
        }
    }

    public func toggleInterest(_ id: String) {
        guard !isBusy, interests.contains(where: { $0.id == id }),
              ProfileValidation.canToggleInterest(id, selected: selectedInterestIDs) else { return }
        if selectedInterestIDs.contains(id) { selectedInterestIDs.remove(id) }
        else { selectedInterestIDs.insert(id) }
        actionError = nil
    }

    public func togglePurpose(_ purpose: ProfilePurpose) {
        guard !isBusy else { return }
        if selectedPurposes.contains(purpose) { selectedPurposes.remove(purpose) }
        else { selectedPurposes.insert(purpose) }
        actionError = nil
    }

    public func loadInterests() async {
        guard !isBusy else { return }
        isLoadingInterests = true
        interestLoadError = nil
        defer { isLoadingInterests = false }
        do {
            let loaded = try await actions.loadInterests()
            try Task.checkCancellation()
            interests = loaded
            selectedInterestIDs.formIntersection(Set(loaded.map(\.id)))
            hasLoadedInterests = true
        } catch is CancellationError {
            // Cancellation leaves the form intact and permits another attempt.
        } catch {
            interestLoadError = Self.presentationError(error)
        }
    }

    public func saveBasics() async {
        guard canContinueBasics else { return }
        isSaving = true
        actionError = nil
        failedOperation = .basics
        defer { isSaving = false }
        do {
            let saved = try await actions.saveProfile(ProfileValidation.trimmed(displayName),
                                                     ProfileValidation.trimmed(introduction), profile.contactDetail)
            profile = saved
            failedOperation = nil
            step = .interests
        } catch is CancellationError {
        } catch {
            actionError = Self.presentationError(error)
        }
    }

    public func saveSelections() async {
        guard canContinueInterests else { return }
        isSaving = true
        actionError = nil
        failedOperation = .selections
        defer { isSaving = false }
        do {
            let ids = selectedInterestIDs
            let purposes = selectedPurposes
            if ids != profile.interestIDs { profile = try await actions.saveInterests(ids) }
            if purposes != profile.purposes { profile = try await actions.savePurposes(purposes) }
            failedOperation = nil
            step = .permissions
        } catch is CancellationError {
        } catch {
            actionError = Self.presentationError(error)
        }
    }

    public func requestBluetooth() async {
        guard !isBusy else { return }
        isSaving = true
        actionError = nil
        failedOperation = .bluetooth
        defer { isSaving = false }
        do {
            bluetooth = try await actions.requestBluetooth()
            failedOperation = nil
            if bluetooth.needsRecovery { onBluetoothRecovery() }
        } catch is CancellationError {
        } catch {
            actionError = Self.presentationError(error)
        }
    }

    public func recoverBluetooth() {
        guard !isBusy else { return }
        onBluetoothRecovery()
    }

    public func finish(discovery enabled: Bool) async {
        guard !isBusy, !enabled || canEnableDiscovery else { return }
        if !enabled && !profile.discoveryOn {
            hasCompleted = true
            failedOperation = nil
            actionError = nil
            onFinish(false)
            return
        }
        isSaving = true
        actionError = nil
        failedOperation = .finish(discovery: enabled)
        defer { isSaving = false }
        do {
            let saved = try await actions.setDiscovery(enabled)
            profile = saved
            guard saved.discoveryOn == enabled else {
                throw ProfileActionError(code: .unavailable)
            }
            hasCompleted = true
            failedOperation = nil
            onFinish(enabled)
        } catch is CancellationError {
        } catch {
            let failure = Self.presentationError(error)
            if failure.code == .prerequisiteMissing {
                for field in failure.fields {
                    switch field {
                    case "display_name": profile.prerequisites.displayName = false
                    case "introduction": profile.prerequisites.introduction = false
                    case "interest", "interests", "interest_ids": profile.prerequisites.interest = false
                    case "link": profile.prerequisites.link = false
                    default: break
                    }
                }
            }
            actionError = failure
        }
    }

    public func retry() async {
        switch failedOperation {
        case .basics: await saveBasics()
        case .selections: await saveSelections()
        case .bluetooth: await requestBluetooth()
        case .finish(let enabled): await finish(discovery: enabled)
        case nil: break
        }
    }

    var errorFallback: OnboardingString {
        failedOperation == .bluetooth ? .bluetoothUnavailable : .saveError
    }

    private static func presentationError(_ error: any Error) -> ProfileActionError {
        error as? ProfileActionError ?? ProfileActionError(code: .unavailable)
    }
}
