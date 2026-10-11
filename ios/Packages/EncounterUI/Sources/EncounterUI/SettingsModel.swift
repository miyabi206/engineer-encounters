import Combine
import Foundation

public enum SettingsScreen: Hashable, Sendable { case profile, discovery, visibility }

/// Pure form rules. The interim threshold range is shared with onboarding in ProfileValidation.
public enum SettingsValidation {
    /// The contract counts Unicode code points after trimming, rather than grapheme clusters.
    public static func textCount(_ value: String) -> Int {
        ProfileValidation.trimmed(value).unicodeScalars.count
    }

    public static func validText(_ value: String, limit: Int, required: Bool) -> Bool {
        let count = textCount(value)
        return count <= limit && (!required || count > 0)
    }

    public static func invalidProfileFields(displayName: String, introduction: String, contactDetail: String,
                                            interests: Set<String>, purposes: Set<ProfilePurpose>,
                                            options: [InterestOption]) -> [ProfileField] {
        var fields: [ProfileField] = []
        if !validText(displayName, limit: ProfileValidation.displayNameLimit, required: true) { fields.append(.displayName) }
        if !validText(introduction, limit: ProfileValidation.introductionLimit, required: true) { fields.append(.introduction) }
        if !validText(contactDetail, limit: ProfileValidation.contactDetailLimit, required: false) { fields.append(.contactDetail) }
        if interests.isEmpty || interests.count > ProfileValidation.interestLimit ||
            !interests.isSubset(of: Set(options.map(\.id))) { fields.append(.interests) }
        if purposes.isEmpty { fields.append(.purposes) }
        return fields
    }

    public static func removedPrerequisites(profile: OwnProfileState, displayName: String,
                                             introduction: String, interests: Set<String>) -> [ProfileField] {
        guard profile.discoveryOn else { return [] }
        var fields: [ProfileField] = []
        if ProfileValidation.trimmed(displayName).isEmpty { fields.append(.displayName) }
        if ProfileValidation.trimmed(introduction).isEmpty { fields.append(.introduction) }
        if interests.isEmpty { fields.append(.interests) }
        return fields
    }

    public static func visibility(_ field: ProfileField, in values: [ProfileField: VisibilityLevel]) -> VisibilityLevel {
        values[field] ?? (field == .contactDetail ? .private : .everyoneEligible)
    }
}

/// One caller-owned model can be retained while S12 pushes S17, preserving the profile draft.
/// Writes are sequential; successful partial writes become the confirmed state before a retry.
@MainActor
public final class SettingsModel: ObservableObject {
    @Published public private(set) var profile: OwnProfileState
    @Published public var displayName: String
    @Published public var introduction: String
    @Published public var contactDetail: String
    @Published public var selectedInterestIDs: Set<String>
    @Published public var selectedPurposes: Set<ProfilePurpose>
    @Published public var matchingPurposes: Set<ProfilePurpose>
    @Published public var minimumSharedInterests: Int
    @Published public var visibility: [ProfileField: VisibilityLevel]
    @Published public private(set) var interests: [InterestOption]
    @Published public private(set) var hasLoadedInterests: Bool
    @Published public private(set) var isLoadingInterests = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var interestLoadError: ProfileActionError?
    @Published public private(set) var errors: [SettingsScreen: ProfileActionError] = [:]
    @Published public private(set) var bluetooth: BluetoothPermissionState
    public let showsDiscoveryExplanation: Bool
    public let allowsDiscoveryActivation: Bool
    private let actions: ProfileActions

    public init(profile: OwnProfileState, actions: ProfileActions, interests: [InterestOption]? = nil,
                bluetooth: BluetoothPermissionState = .notRequested,
                onboardingExplanationCompleted: Bool = false, allowsDiscoveryActivation: Bool = false) {
        self.profile = profile
        self.actions = actions
        displayName = profile.displayName
        introduction = profile.introduction
        contactDetail = profile.contactDetail
        selectedInterestIDs = profile.interestIDs
        selectedPurposes = profile.purposes
        matchingPurposes = profile.purposes
        minimumSharedInterests = profile.minimumSharedInterests
        visibility = profile.fieldVisibility
        self.interests = interests ?? []
        hasLoadedInterests = interests != nil
        self.bluetooth = bluetooth
        showsDiscoveryExplanation = !onboardingExplanationCompleted
        // Unit 3 cannot activate discovery; the composition layer can opt in after Unit 5.
        self.allowsDiscoveryActivation = allowsDiscoveryActivation
    }

    public var isBusy: Bool { isSaving || isLoadingInterests }
    public var invalidProfileFields: [ProfileField] {
        SettingsValidation.invalidProfileFields(displayName: displayName, introduction: introduction,
            contactDetail: contactDetail, interests: selectedInterestIDs, purposes: selectedPurposes, options: interests)
    }
    public var removedPrerequisites: [ProfileField] {
        SettingsValidation.removedPrerequisites(profile: profile, displayName: displayName,
            introduction: introduction, interests: selectedInterestIDs)
    }
    public var canSaveProfile: Bool {
        !isBusy && hasLoadedInterests && interestLoadError == nil && invalidProfileFields.isEmpty && removedPrerequisites.isEmpty
    }
    public var canSaveMatching: Bool {
        !isBusy && !matchingPurposes.isEmpty && ProfileValidation.sharedInterestRange.contains(minimumSharedInterests)
    }
    public var canEnableDiscovery: Bool {
        !isBusy && allowsDiscoveryActivation && profile.prerequisites.canEnableDiscovery && bluetooth.canEnableDiscovery
    }
    public var hasProfileChanges: Bool {
        displayName != profile.displayName || introduction != profile.introduction || contactDetail != profile.contactDetail ||
        selectedInterestIDs != profile.interestIDs || selectedPurposes != profile.purposes
    }
    public var hasMatchingChanges: Bool {
        matchingPurposes != profile.purposes || minimumSharedInterests != profile.minimumSharedInterests
    }
    public var hasVisibilityChanges: Bool {
        ProfileField.allCases.contains { SettingsValidation.visibility($0, in: visibility) !=
            SettingsValidation.visibility($0, in: profile.fieldVisibility) }
    }

    public func discard(_ screen: SettingsScreen) {
        guard !isBusy else { return }
        errors[screen] = nil
        switch screen {
        case .profile:
            displayName = profile.displayName; introduction = profile.introduction; contactDetail = profile.contactDetail
            selectedInterestIDs = profile.interestIDs; selectedPurposes = profile.purposes
        case .discovery:
            matchingPurposes = profile.purposes; minimumSharedInterests = profile.minimumSharedInterests
        case .visibility: visibility = profile.fieldVisibility
        }
    }

    public func toggleInterest(_ id: String) {
        guard !isBusy, interests.contains(where: { $0.id == id }),
              ProfileValidation.canToggleInterest(id, selected: selectedInterestIDs) else { return }
        if selectedInterestIDs.contains(id) { selectedInterestIDs.remove(id) }
        else { selectedInterestIDs.insert(id) }
        errors[.profile] = nil
    }

    public func togglePurpose(_ purpose: ProfilePurpose, screen: SettingsScreen) {
        guard !isBusy else { return }
        if screen == .profile {
            if selectedPurposes.contains(purpose) { selectedPurposes.remove(purpose) }
            else { selectedPurposes.insert(purpose) }
        } else if screen == .discovery {
            if matchingPurposes.contains(purpose) { matchingPurposes.remove(purpose) }
            else { matchingPurposes.insert(purpose) }
        }
        errors[screen] = nil
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
        } catch { interestLoadError = presentationError(error) }
    }

    /// Returns true only after every write succeeds, so S12 leaves only on confirmed success.
    public func saveProfile() async -> Bool {
        guard !isBusy else { return false }
        if !removedPrerequisites.isEmpty {
            errors[.profile] = ProfileActionError(code: .prerequisiteMissing, fields: removedPrerequisites.map(\.rawValue))
            return false
        }
        guard canSaveProfile else { return false }
        isSaving = true
        errors[.profile] = nil
        defer { isSaving = false }
        do {
            let name = ProfileValidation.trimmed(displayName)
            let intro = ProfileValidation.trimmed(introduction)
            let contact = ProfileValidation.trimmed(contactDetail)
            if name != profile.displayName || intro != profile.introduction || contact != profile.contactDetail {
                profile = try await actions.saveProfile(name, intro, contact)
            }
            if selectedInterestIDs != profile.interestIDs || selectedPurposes != profile.purposes {
                let matchingWasClean = !hasMatchingChanges
                profile = try await actions.saveInterestsAndPurposes(selectedInterestIDs, selectedPurposes)
                if matchingWasClean { matchingPurposes = profile.purposes }
            }
            displayName = profile.displayName; introduction = profile.introduction; contactDetail = profile.contactDetail
            selectedInterestIDs = profile.interestIDs; selectedPurposes = profile.purposes
            return true
        } catch is CancellationError {
            return false
        } catch {
            errors[.profile] = presentationError(error)
            return false
        }
    }

    public func saveMatching() async {
        guard canSaveMatching else { return }
        isSaving = true
        errors[.discovery] = nil
        defer { isSaving = false }
        do {
            if matchingPurposes != profile.purposes {
                let profilePurposesWereClean = selectedPurposes == profile.purposes
                profile = try await actions.saveInterestsAndPurposes(profile.interestIDs, matchingPurposes)
                if profilePurposesWereClean { selectedPurposes = profile.purposes }
            }
            if minimumSharedInterests != profile.minimumSharedInterests {
                profile = try await actions.setMinimumSharedInterests(minimumSharedInterests)
            }
            matchingPurposes = profile.purposes
            minimumSharedInterests = profile.minimumSharedInterests
        } catch is CancellationError {
        } catch { errors[.discovery] = presentationError(error) }
    }

    @discardableResult
    public func setDiscovery(_ enabled: Bool) async -> Bool {
        guard !isBusy, enabled != profile.discoveryOn, !enabled || canEnableDiscovery else { return false }
        isSaving = true
        errors[.discovery] = nil
        defer { isSaving = false }
        do {
            let saved = try await actions.setDiscovery(enabled)
            guard saved.discoveryOn == enabled else { throw ProfileActionError(code: .unavailable) }
            profile = saved
            return true
        } catch is CancellationError {
            return false
        } catch {
            errors[.discovery] = presentationError(error)
            return false
        }
    }

    public func requestBluetooth() async {
        guard !isBusy else { return }
        isSaving = true
        errors[.discovery] = nil
        defer { isSaving = false }
        do { bluetooth = try await actions.requestBluetooth() }
        catch is CancellationError {
        } catch { errors[.discovery] = presentationError(error) }
    }

    public func saveVisibility() async {
        guard !isBusy else { return }
        isSaving = true
        errors[.visibility] = nil
        defer { isSaving = false }
        for field in ProfileField.allCases {
            let level = SettingsValidation.visibility(field, in: visibility)
            guard level != SettingsValidation.visibility(field, in: profile.fieldVisibility) else { continue }
            do { profile = try await actions.setFieldVisibility(field, level) }
            catch is CancellationError { return }
            catch {
                let failure = presentationError(error)
                errors[.visibility] = ProfileActionError(code: failure.code,
                    fields: failure.fields.isEmpty || failure.fields.contains("field") || failure.fields.contains("level")
                        ? [field.rawValue] : failure.fields)
                return
            }
        }
        visibility = profile.fieldVisibility
    }

    private func presentationError(_ error: any Error) -> ProfileActionError {
        error as? ProfileActionError ?? ProfileActionError(code: .unavailable)
    }
}
