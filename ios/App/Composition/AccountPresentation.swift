import EncounterBackend
import EncounterUI
import Foundation

@MainActor
extension AccountModel {
    static func presentationError(_ error: any Error) -> ProfileActionError {
        switch error as? BackendError {
        case .notAuthenticated: .init(code: .notAuthenticated)
        case .accountNotReady: .init(code: .accountNotReady)
        case .declarationRequired: .init(code: .declarationRequired)
        case .invalidInput(let fields): .init(code: .invalidInput, fields: fields)
        case .prerequisiteMissing(let fields): .init(code: .prerequisiteMissing, fields: fields)
        case .rateLimited: .init(code: .rateLimited)
        case .notFound: .init(code: .notFound)
        default: .init(code: .unavailable)
        }
    }

    @discardableResult
    func loadOwnProfile() async throws -> OwnProfileState {
        let fresh = try await ownAccountOperation { try await $0.getOwnProfile() }
        let state = Self.present(fresh)
        publishProfile(state, stale: false)
        return state
    }

    func profileActions(bluetoothState: (@MainActor () -> BluetoothPermissionState)? = nil,
                        requestBluetooth: @escaping @MainActor () async throws -> BluetoothPermissionState) -> ProfileActions {
        let epoch = sessionGeneration
        let requireSession: @MainActor () throws -> Void = {
            guard self.hasCurrentSessionContext, !self.sessionCleanupPending, self.sessionGeneration == epoch,
                  self.state.isSignedIn else {
                throw ProfileActionError(code: .notAuthenticated)
            }
            guard self.canRefreshSession() else { throw Self.presentationError(BackendError.storageFailure) }
            guard case .signedIn = self.state else { throw ProfileActionError(code: .notAuthenticated) }
        }
        return ProfileActions(
            loadInterests: {
                try requireSession()
                let interests = try await self.ownAccountOperation { try await $0.listInterests() }
                if self.sessionGeneration == epoch { _ = try? await self.loadOwnProfile() }
                return interests.map { InterestOption(id: $0.interestID, labelJapanese: $0.labelJA, labelEnglish: $0.labelEN) }
            },
            saveProfile: { name, introduction, contact in
                try requireSession()
                return try await self.writeProfile({ try await $0.updateOwnProfile(displayName: name, introduction: introduction, contactDetail: contact) }) {
                    $0.displayName = ProfileValidation.trimmed(name)
                    $0.introduction = ProfileValidation.trimmed(introduction)
                    $0.contactDetail = ProfileValidation.trimmed(contact)
                    $0.prerequisites.displayName = !$0.displayName.isEmpty
                    $0.prerequisites.introduction = !$0.introduction.isEmpty
                }
            },
            saveInterests: { ids in
                try requireSession()
                return try await self.writeProfile({ try await $0.setOwnInterests(ids.sorted()) }) {
                    $0.interestIDs = ids
                    $0.prerequisites.interest = !ids.isEmpty
                }
            },
            savePurposes: { purposes in
                try requireSession()
                let values = purposes.sorted { $0.rawValue < $1.rawValue }.compactMap {
                    EncounterBackend.ProfilePurpose(rawValue: $0.rawValue)
                }
                return try await self.writeProfile({ try await $0.setOwnPurposes(values) }) { $0.purposes = purposes }
            },
            setDiscovery: { enabled in
                try requireSession()
                try await self.discoveryWillChange(enabled)
                let profile = try await self.writeProfile({ try await $0.setDiscovery(enabled: enabled) }) { $0.discoveryOn = enabled }
                if self.sessionGeneration == epoch { await self.discoveryDidChange(enabled) }
                return profile
            },
            requestBluetooth: {
                try requireSession()
                do {
                    let fence = self.backendCallFence()
                    let bluetooth = try await fence.call { try await requestBluetooth() }
                    guard self.sessionGeneration == epoch else { return bluetooth }
                    _ = try? await self.loadOwnProfile()
                    guard self.sessionGeneration == epoch else { return bluetooth }
                    return bluetoothState?() ?? bluetooth
                }
                catch is CancellationError { throw CancellationError() }
                catch {
                    let failure = error as? ProfileActionError ?? Self.presentationError(error)
                    if failure.code == .notAuthenticated { await self.rejectDeadSession(generation: epoch) }
                    throw failure
                }
            },
            setMinimumSharedInterests: { value in
                try requireSession()
                return try await self.writeProfile({ try await $0.setMinimumSharedInterests(value) }) { $0.minimumSharedInterests = value }
            },
            setFieldVisibility: { field, level in
                try requireSession()
                guard let field = EncounterBackend.ProfileField(rawValue: field.rawValue),
                      let level = EncounterBackend.VisibilityLevel(rawValue: level.rawValue) else {
                    throw ProfileActionError(code: .invalidInput, fields: ["field", "level"])
                }
                return try await self.writeProfile({ try await $0.setFieldVisibility(field: field, level: level) }) {
                    if let field = EncounterUI.ProfileField(rawValue: field.rawValue),
                       let level = EncounterUI.VisibilityLevel(rawValue: level.rawValue) { $0.fieldVisibility[field] = level }
                }
            })
    }

    private func writeProfile(_ write: @MainActor (OwnAccountService) async throws -> Void,
                              applying: (inout OwnProfileState) -> Void) async throws -> OwnProfileState {
        let epoch = sessionGeneration
        var accepted = profile ?? OwnProfileState()
        try await ownAccountOperation(write)
        protectedContentDidChange()
        applying(&accepted)
        // The mutation is committed. A later read cannot turn it into a failed write.
        do { return try await loadOwnProfile() }
        catch {
            if sessionGeneration == epoch, state.isSignedIn { publishProfile(accepted, stale: true) }
            return accepted
        }
    }

    func ownAccountOperation<Value>(allowingDeletion: Bool = false, _ operation: @MainActor (OwnAccountService) async throws -> Value) async throws -> Value {
        guard hasCurrentSessionContext, !sessionCleanupPending, state.isSignedIn, let service else {
            throw ProfileActionError(code: .notAuthenticated)
        }
        guard canRefreshSession() else { throw Self.presentationError(BackendError.storageFailure) }
        guard case .signedIn(let user) = state else { throw ProfileActionError(code: .notAuthenticated) }
        let epoch = sessionGeneration
        let fence = backendCallFence()
        do {
            let result: Value
            if allowingDeletion { result = try await fence.call { try await operation(service) } }
            else { result = try await protectedOperation { try await fence.call { try await operation(service) } } }
            guard hasCurrentSessionContext, !sessionCleanupPending, sessionGeneration == epoch, state == .signedIn(user) else {
                throw ProfileActionError(code: .notAuthenticated)
            }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure = error as? ProfileActionError ?? Self.presentationError(error)
            if failure.code == .notAuthenticated { await rejectDeadSession(generation: epoch) }
            throw failure
        }
    }

    static func present(_ profile: OwnProfile) -> OwnProfileState {
        let visibility = Dictionary(uniqueKeysWithValues: EncounterUI.ProfileField.allCases.compactMap { field -> (EncounterUI.ProfileField, EncounterUI.VisibilityLevel)? in
            guard let backendField = EncounterBackend.ProfileField(rawValue: field.rawValue),
                  let level = EncounterUI.VisibilityLevel(rawValue: profile.fieldVisibility[backendField].rawValue) else { return nil }
            return (field, level)
        })
        return OwnProfileState(displayName: profile.displayName, introduction: profile.introduction,
            contactDetail: profile.contactDetail, interestIDs: Set(profile.interests),
            purposes: Set(profile.purposes.compactMap { EncounterUI.ProfilePurpose(rawValue: $0.rawValue) }),
            minimumSharedInterests: profile.minimumSharedInterests, fieldVisibility: visibility,
            discoveryOn: profile.discoveryOn, linkCount: profile.linkCount,
            prerequisites: .init(displayName: profile.prerequisites.displayName,
                introduction: profile.prerequisites.introduction, interest: profile.prerequisites.interest, link: profile.prerequisites.link),
            declarationsRecorded: profile.declarationsRecorded, timeZone: profile.timeZone ?? "",
            moderationState: profile.moderationState?.rawValue ?? "active")
    }
}
