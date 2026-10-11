import Combine
import Foundation

@MainActor
public final class OnboardingModel: ObservableObject {
    @Published public private(set) var profile: OwnProfileState
    @Published public private(set) var step: OnboardingStep
    @Published public var displayName: String
    @Published public var introduction: String
    @Published public var selectedInterestIDs: Set<String>
    @Published public var selectedPurposes: Set<ProfilePurpose>
    @Published public private(set) var interests: [InterestOption]
    @Published public private(set) var bluetooth: BluetoothPermissionState
    @Published public private(set) var isSaving = false
    @Published public private(set) var isLoadingInterests = false
    @Published public private(set) var hasLoadedInterests: Bool
    @Published public private(set) var interestLoadError: ProfileActionError?
    @Published public private(set) var actionError: ProfileActionError?

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
        selectedInterestIDs = profile.interestIDs
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

    public var isBusy: Bool { isSaving || isLoadingInterests }
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

    public func back() {
        guard !isBusy else { return }
        actionError = nil
        switch step {
        case .basics: onExit()
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
        defer { isSaving = false }
        do {
            let saved = try await actions.saveProfile(ProfileValidation.trimmed(displayName),
                                                     ProfileValidation.trimmed(introduction), profile.contactDetail)
            try Task.checkCancellation()
            profile = saved
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
        defer { isSaving = false }
        do {
            let saved = try await actions.saveInterestsAndPurposes(selectedInterestIDs, selectedPurposes)
            try Task.checkCancellation()
            profile = saved
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
        defer { isSaving = false }
        do {
            bluetooth = try await actions.requestBluetooth()
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
        isSaving = true
        actionError = nil
        defer { isSaving = false }
        do {
            let saved = try await actions.setDiscovery(enabled)
            try Task.checkCancellation()
            guard saved.discoveryOn == enabled else {
                throw ProfileActionError(code: .unavailable)
            }
            profile = saved
            onFinish(enabled)
        } catch is CancellationError {
        } catch {
            actionError = Self.presentationError(error)
        }
    }

    private static func presentationError(_ error: any Error) -> ProfileActionError {
        error as? ProfileActionError ?? ProfileActionError(code: .unavailable)
    }
}
