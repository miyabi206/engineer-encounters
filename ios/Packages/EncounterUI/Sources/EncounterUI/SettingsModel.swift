import Combine
import Foundation

public enum SettingsScreen: Hashable, Sendable { case profile, discovery, visibility }

/// Pure form rules. The interim threshold range is shared with onboarding in ProfileValidation.
public enum SettingsValidation {
    /// The contract counts Unicode code points after trimming, rather than grapheme clusters.
    public static func textCount(_ value: String) -> Int {
        ProfileValidation.characterCount(value)
    }

    public static func validText(_ value: String, limit: Int, required: Bool) -> Bool {
        ProfileValidation.validText(value, limit: limit, required: required)
    }

    public static func invalidProfileFields(displayName: String, introduction: String, contactDetail: String,
                                            interests: Set<String>, purposes: Set<ProfilePurpose>,
                                            options: [InterestOption], discoveryOn: Bool = true,
                                            hasLoadedInterests: Bool = true) -> [ProfileField] {
        var fields: [ProfileField] = []
        if !validText(displayName, limit: ProfileValidation.displayNameLimit, required: discoveryOn) { fields.append(.displayName) }
        if !validText(introduction, limit: ProfileValidation.introductionLimit, required: discoveryOn) { fields.append(.introduction) }
        if !validText(contactDetail, limit: ProfileValidation.contactDetailLimit, required: false) { fields.append(.contactDetail) }
        if (discoveryOn && interests.isEmpty) || interests.count > ProfileValidation.interestLimit ||
            (hasLoadedInterests && !interests.isSubset(of: Set(options.map(\.id)))) { fields.append(.interests) }
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

public enum SettingsOperation: Equatable, Sendable {
    case profile, matching, discovery(Bool), bluetooth, visibility
}

public enum SettingsAppliedChange: Equatable, Sendable {
    case field(ProfileField), threshold
}

/// Retain this caller-owned model across settings routes to preserve independent drafts.
/// Each response confirms a write immediately, including successful writes in cancelled tasks.
@MainActor
public final class SettingsModel: ObservableObject {
    @Published public private(set) var profile: OwnProfileState
    @Published public var displayName: String { didSet { if displayName != oldValue { edited(.profile) } } }
    @Published public var introduction: String { didSet { if introduction != oldValue { edited(.profile) } } }
    @Published public var contactDetail: String { didSet { if contactDetail != oldValue { edited(.profile) } } }
    @Published public var selectedInterestIDs: Set<String> { didSet { if selectedInterestIDs != oldValue { edited(.profile) } } }
    @Published public var selectedPurposes: Set<ProfilePurpose> { didSet { if selectedPurposes != oldValue { edited(.profile) } } }
    @Published public var matchingPurposes: Set<ProfilePurpose> { didSet { if matchingPurposes != oldValue { edited(.discovery) } } }
    @Published public var minimumSharedInterests: Int { didSet { if minimumSharedInterests != oldValue { edited(.discovery) } } }
    @Published public var visibility: [ProfileField: VisibilityLevel] { didSet { if visibility != oldValue { edited(.visibility) } } }
    @Published public private(set) var interests: [InterestOption]
    @Published public private(set) var hasLoadedInterests: Bool
    @Published public private(set) var isLoadingInterests = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var interestLoadError: ProfileActionError?
    @Published public private(set) var errors: [SettingsScreen: ProfileActionError] = [:]
    @Published public private(set) var bluetooth: BluetoothPermissionState
    @Published public private(set) var failedOperations: [SettingsScreen: SettingsOperation] = [:]
    @Published public private(set) var appliedChanges: [SettingsScreen: [SettingsAppliedChange]] = [:]
    public let showsDiscoveryExplanation: Bool
    public let allowsDiscoveryActivation: Bool
    private let actions: ProfileActions
    private var pendingInterestLoad = false
    private var isReceivingState = false
    private var dirtyProfileDraft: Set<ProfileField>?
    private var dirtyMatchingPurposes: Bool?
    private var dirtyThreshold: Bool?
    private var dirtyVisibilityDraft: Set<ProfileField>?

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
        self.allowsDiscoveryActivation = allowsDiscoveryActivation
    }

    public var isBusy: Bool { isSaving || isLoadingInterests }
    public var invalidProfileFields: [ProfileField] {
        // An unavailable catalogue cannot invalidate the confirmed interest set or block text edits.
        let validatesMembership = hasLoadedInterests && interestLoadError == nil &&
            (!interests.isEmpty || selectedInterestIDs != profile.interestIDs)
        return SettingsValidation.invalidProfileFields(displayName: displayName, introduction: introduction,
            contactDetail: contactDetail, interests: selectedInterestIDs, purposes: selectedPurposes, options: interests,
            discoveryOn: profile.discoveryOn, hasLoadedInterests: validatesMembership)
    }
    public var removedPrerequisites: [ProfileField] {
        SettingsValidation.removedPrerequisites(profile: profile, displayName: displayName,
            introduction: introduction, interests: selectedInterestIDs)
    }
    public var canSaveProfile: Bool { !isSaving && invalidProfileFields.isEmpty && removedPrerequisites.isEmpty }
    public var canSaveMatching: Bool {
        !isSaving && !matchingPurposes.isEmpty && ProfileValidation.sharedInterestRange.contains(minimumSharedInterests)
    }
    public var canEnableDiscovery: Bool {
        !isSaving && allowsDiscoveryActivation && profile.prerequisites.canEnableDiscovery && bluetooth.canEnableDiscovery
    }
    public var canRequestBluetooth: Bool { allowsDiscoveryActivation && !isSaving && bluetooth == .notRequested }
    public var shouldRetryInterestLoad: Bool { !isLoadingInterests && (!hasLoadedInterests || interests.isEmpty) }
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

    /// Call when the composition layer receives a fresh profile or rechecks Bluetooth.
    /// Only drafts that still equal the previous confirmed value follow the new state.
    public func receive(profile fresh: OwnProfileState, bluetooth: BluetoothPermissionState? = nil) {
        isReceivingState = true
        defer { isReceivingState = false }
        let old = profile
        if dirtyProfileDraft.map({ !$0.contains(.displayName) }) ?? (displayName == old.displayName) { displayName = fresh.displayName }
        if dirtyProfileDraft.map({ !$0.contains(.introduction) }) ?? (introduction == old.introduction) { introduction = fresh.introduction }
        if dirtyProfileDraft.map({ !$0.contains(.contactDetail) }) ?? (contactDetail == old.contactDetail) { contactDetail = fresh.contactDetail }
        if dirtyProfileDraft.map({ !$0.contains(.interests) }) ?? (selectedInterestIDs == old.interestIDs) { selectedInterestIDs = fresh.interestIDs }
        if dirtyProfileDraft.map({ !$0.contains(.purposes) }) ?? (selectedPurposes == old.purposes) { selectedPurposes = fresh.purposes }
        if dirtyMatchingPurposes.map({ !$0 }) ?? (matchingPurposes == old.purposes) { matchingPurposes = fresh.purposes }
        if dirtyThreshold.map({ !$0 }) ?? (minimumSharedInterests == old.minimumSharedInterests) { minimumSharedInterests = fresh.minimumSharedInterests }
        for field in ProfileField.allCases where dirtyVisibilityDraft.map({ !$0.contains(field) }) ??
            (SettingsValidation.visibility(field, in: visibility) == SettingsValidation.visibility(field, in: old.fieldVisibility)) {
            visibility[field] = SettingsValidation.visibility(field, in: fresh.fieldVisibility)
        }
        profile = fresh
        if let bluetooth { self.bluetooth = bluetooth }
    }

    public func receive(bluetooth: BluetoothPermissionState) { self.bluetooth = bluetooth }

    public func leave(_ screen: SettingsScreen) {
        errors[screen] = nil
        if screen == .profile { interestLoadError = nil }
    }

    public func discard(_ screen: SettingsScreen) {
        guard !isSaving else { return }
        leave(screen)
        failedOperations[screen] = nil
        appliedChanges[screen] = nil
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
        guard !isSaving, interests.contains(where: { $0.id == id }),
              ProfileValidation.canToggleInterest(id, selected: selectedInterestIDs) else { return }
        if selectedInterestIDs.contains(id) { selectedInterestIDs.remove(id) }
        else { selectedInterestIDs.insert(id) }
    }

    public func togglePurpose(_ purpose: ProfilePurpose, screen: SettingsScreen) {
        guard !isSaving else { return }
        if screen == .profile {
            if selectedPurposes.contains(purpose) { selectedPurposes.remove(purpose) }
            else { selectedPurposes.insert(purpose) }
        } else if screen == .discovery {
            if matchingPurposes.contains(purpose) { matchingPurposes.remove(purpose) }
            else { matchingPurposes.insert(purpose) }
        }
    }

    public func loadInterests() async {
        guard !isLoadingInterests else { return }
        guard !isSaving else { pendingInterestLoad = true; return }
        pendingInterestLoad = false
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

    /// Returns true only once the complete profile draft has been confirmed.
    public func saveProfile() async -> Bool {
        guard !isSaving else { return false }
        if !removedPrerequisites.isEmpty {
            failedOperations[.profile] = .profile
            errors[.profile] = ProfileActionError(code: .prerequisiteMissing, fields: removedPrerequisites.map(\.rawValue))
            return false
        }
        guard canSaveProfile else { return false }
        begin(.profile, operation: .profile)
        defer { endSaving() }
        let name = ProfileValidation.trimmed(displayName)
        let intro = ProfileValidation.trimmed(introduction)
        let contact = ProfileValidation.trimmed(contactDetail)
        let ids = selectedInterestIDs
        let purposes = selectedPurposes
        do {
            // Remove text first. Combined replacement calls can otherwise reveal a new field
            // before a requested removal in the next call has taken effect.
            let narrowedName = name.isEmpty ? "" : profile.displayName
            let narrowedIntro = intro.isEmpty ? "" : profile.introduction
            let narrowedContact = contact.isEmpty ? "" : profile.contactDetail
            try await writeText(narrowedName, narrowedIntro, narrowedContact)
            let commonIDs = profile.interestIDs.intersection(ids)
            let needsInterestReplacement = profile.discoveryOn && commonIDs.isEmpty && ids != profile.interestIDs
            let narrowedIDs = needsInterestReplacement ? profile.interestIDs : commonIDs
            // Empty purposes are valid on the server and suppress compatibility while a
            // disjoint interest replacement cannot pass through an empty interest set.
            let narrowedPurposes: Set<ProfilePurpose> = needsInterestReplacement ? [] : profile.purposes.intersection(purposes)
            try await writeSelections(narrowedIDs, narrowedPurposes, screen: .profile)
            try await writeText(name, intro, contact)
            try await writeSelections(ids, purposes, screen: .profile)
            displayName = profile.displayName; introduction = profile.introduction; contactDetail = profile.contactDetail
            selectedInterestIDs = profile.interestIDs; selectedPurposes = profile.purposes
            succeeded(.profile)
            return true
        } catch is CancellationError {
            cancelled(.profile)
            return false
        } catch {
            errors[.profile] = presentationError(error)
            return false
        }
    }

    public func saveMatching() async {
        guard canSaveMatching else { return }
        begin(.discovery, operation: .matching)
        defer { endSaving() }
        let purposes = matchingPurposes
        let threshold = minimumSharedInterests
        do {
            if threshold > profile.minimumSharedInterests { try await writeThreshold(threshold) }
            try await writeSelections(profile.interestIDs, profile.purposes.intersection(purposes), screen: .discovery)
            try await writeSelections(profile.interestIDs, purposes, screen: .discovery)
            try await writeThreshold(threshold)
            matchingPurposes = profile.purposes
            minimumSharedInterests = profile.minimumSharedInterests
            succeeded(.discovery)
        } catch is CancellationError { cancelled(.discovery) }
        catch { errors[.discovery] = presentationError(error) }
    }

    @discardableResult
    public func setDiscovery(_ enabled: Bool) async -> Bool {
        guard !isSaving, enabled != profile.discoveryOn, !enabled || canEnableDiscovery else { return false }
        begin(.discovery, operation: .discovery(enabled))
        defer { endSaving() }
        do {
            let saved = try await actions.setDiscovery(enabled)
            receive(profile: saved)
            guard saved.discoveryOn == enabled else { throw ProfileActionError(code: .unavailable) }
            succeeded(.discovery)
            return true
        } catch is CancellationError {
            cancelled(.discovery)
            return false
        } catch {
            let failure = presentationError(error)
            errors[.discovery] = failure
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
            return false
        }
    }

    public func requestBluetooth() async {
        guard canRequestBluetooth else { return }
        begin(.discovery, operation: .bluetooth)
        defer { endSaving() }
        do {
            bluetooth = try await actions.requestBluetooth()
            succeeded(.discovery)
        } catch is CancellationError { cancelled(.discovery) }
        catch { errors[.discovery] = presentationError(error) }
    }

    public func saveVisibility() async {
        guard !isSaving else { return }
        begin(.visibility, operation: .visibility)
        defer { endSaving() }
        let target = visibility
        let narrowing = ProfileField.allCases.filter {
            visibilityRank(SettingsValidation.visibility($0, in: target)) <
                visibilityRank(SettingsValidation.visibility($0, in: profile.fieldVisibility))
        }
        let fields = narrowing + ProfileField.allCases.filter { !narrowing.contains($0) }
        for field in fields {
            let level = SettingsValidation.visibility(field, in: target)
            guard level != SettingsValidation.visibility(field, in: profile.fieldVisibility) else { continue }
            do {
                let saved = try await actions.setFieldVisibility(field, level)
                receive(profile: saved)
                record(.field(field), screen: .visibility)
            } catch is CancellationError { cancelled(.visibility); return }
            catch {
                let failure = presentationError(error)
                errors[.visibility] = ProfileActionError(code: failure.code,
                    fields: failure.fields.isEmpty || failure.fields.contains("field") || failure.fields.contains("level")
                        ? [field.rawValue] : failure.fields)
                return
            }
        }
        visibility = profile.fieldVisibility
        succeeded(.visibility)
    }

    public func canRetry(_ screen: SettingsScreen) -> Bool {
        switch failedOperations[screen] {
        case .profile: canSaveProfile
        case .matching: canSaveMatching
        case .discovery(let enabled): !isSaving && (!enabled || canEnableDiscovery)
        case .bluetooth: canRequestBluetooth
        case .visibility: !isSaving
        case nil: false
        }
    }

    /// The view may use the result to leave S12 or show the discovery-off destination.
    @discardableResult
    public func retry(_ screen: SettingsScreen) async -> Bool {
        switch failedOperations[screen] {
        case .profile: return await saveProfile()
        case .matching: await saveMatching()
        case .discovery(let enabled): return await setDiscovery(enabled)
        case .bluetooth: await requestBluetooth()
        case .visibility: await saveVisibility()
        case nil: return false
        }
        return errors[screen] == nil && failedOperations[screen] == nil
    }

    func errorFallback(_ screen: SettingsScreen) -> SettingsString {
        failedOperations[screen] == .bluetooth ? .bluetoothUnavailable : .saveError
    }

    private func edited(_ screen: SettingsScreen) {
        if !isReceivingState { errors[screen] = nil }
    }

    private func begin(_ screen: SettingsScreen, operation: SettingsOperation) {
        if failedOperations[screen] != operation { appliedChanges[screen] = [] }
        failedOperations[screen] = operation
        errors[screen] = nil
        dirtyProfileDraft = []
        if displayName != profile.displayName { dirtyProfileDraft?.insert(.displayName) }
        if introduction != profile.introduction { dirtyProfileDraft?.insert(.introduction) }
        if contactDetail != profile.contactDetail { dirtyProfileDraft?.insert(.contactDetail) }
        if selectedInterestIDs != profile.interestIDs { dirtyProfileDraft?.insert(.interests) }
        if selectedPurposes != profile.purposes { dirtyProfileDraft?.insert(.purposes) }
        dirtyMatchingPurposes = matchingPurposes != profile.purposes
        dirtyThreshold = minimumSharedInterests != profile.minimumSharedInterests
        dirtyVisibilityDraft = Set(ProfileField.allCases.filter {
            SettingsValidation.visibility($0, in: visibility) != SettingsValidation.visibility($0, in: profile.fieldVisibility)
        })
        // Preserve the entire submitted draft across intermediate narrowing responses,
        // including values that were unchanged when the save began.
        switch operation {
        case .profile: dirtyProfileDraft = Set(ProfileField.allCases)
        case .matching: dirtyMatchingPurposes = true; dirtyThreshold = true
        case .visibility: dirtyVisibilityDraft = Set(ProfileField.allCases)
        case .discovery, .bluetooth: break
        }
        isSaving = true
    }

    private func succeeded(_ screen: SettingsScreen) {
        failedOperations[screen] = nil
        errors[screen] = nil
        appliedChanges[screen] = nil
    }

    private func cancelled(_ screen: SettingsScreen) {
        if !(appliedChanges[screen] ?? []).isEmpty { errors[screen] = .init(code: .unavailable) }
    }

    private func endSaving() {
        dirtyProfileDraft = nil
        dirtyMatchingPurposes = nil
        dirtyThreshold = nil
        dirtyVisibilityDraft = nil
        isSaving = false
        if pendingInterestLoad {
            pendingInterestLoad = false
            Task { await loadInterests() }
        }
    }

    private func record(_ change: SettingsAppliedChange, screen: SettingsScreen) {
        if !(appliedChanges[screen] ?? []).contains(change) { appliedChanges[screen, default: []].append(change) }
    }

    private func writeText(_ name: String, _ intro: String, _ contact: String) async throws {
        let old = profile
        guard name != old.displayName || intro != old.introduction || contact != old.contactDetail else { return }
        let saved = try await actions.saveProfile(name, intro, contact)
        receive(profile: saved)
        if old.displayName != saved.displayName { record(.field(.displayName), screen: .profile) }
        if old.introduction != saved.introduction { record(.field(.introduction), screen: .profile) }
        if old.contactDetail != saved.contactDetail { record(.field(.contactDetail), screen: .profile) }
    }

    private func writeSelections(_ ids: Set<String>, _ purposes: Set<ProfilePurpose>, screen: SettingsScreen) async throws {
        if ids != profile.interestIDs {
            let saved = try await actions.saveInterests(ids)
            receive(profile: saved)
            record(.field(.interests), screen: screen)
        }
        if purposes != profile.purposes {
            let saved = try await actions.savePurposes(purposes)
            receive(profile: saved)
            record(.field(.purposes), screen: screen)
        }
    }

    private func writeThreshold(_ value: Int) async throws {
        guard value != profile.minimumSharedInterests else { return }
        let saved = try await actions.setMinimumSharedInterests(value)
        receive(profile: saved)
        record(.threshold, screen: .discovery)
    }

    private func visibilityRank(_ level: VisibilityLevel) -> Int {
        switch level { case .private: 0; case .compatibleOnly: 1; case .everyoneEligible: 2 }
    }

    private func presentationError(_ error: any Error) -> ProfileActionError {
        error as? ProfileActionError ?? ProfileActionError(code: .unavailable)
    }
}
