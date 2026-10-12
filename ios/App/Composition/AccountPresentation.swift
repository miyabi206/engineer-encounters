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
        profile = state
        return state
    }

    func profileActions(bluetoothState: (@MainActor () -> BluetoothPermissionState)? = nil,
                        requestBluetooth: @escaping @MainActor () async throws -> BluetoothPermissionState) -> ProfileActions {
        ProfileActions(
            loadInterests: {
                let interests = try await self.ownAccountOperation { try await $0.listInterests() }
                _ = try await self.loadOwnProfile()
                return interests.map { InterestOption(id: $0.interestID, labelJapanese: $0.labelJA, labelEnglish: $0.labelEN) }
            },
            saveProfile: { name, introduction, contact in
                try await self.writeProfile { try await $0.updateOwnProfile(displayName: name, introduction: introduction, contactDetail: contact) }
            },
            saveInterests: { ids in
                try await self.writeProfile { try await $0.setOwnInterests(ids.sorted()) }
            },
            savePurposes: { purposes in
                let values = purposes.sorted { $0.rawValue < $1.rawValue }.compactMap {
                    EncounterBackend.ProfilePurpose(rawValue: $0.rawValue)
                }
                return try await self.writeProfile { try await $0.setOwnPurposes(values) }
            },
            setDiscovery: { enabled in
                try await self.writeProfile { try await $0.setDiscovery(enabled: enabled) }
            },
            requestBluetooth: {
                guard self.state.isSignedIn else { throw ProfileActionError(code: .notAuthenticated) }
                do {
                    let bluetooth = try await requestBluetooth()
                    _ = try await self.loadOwnProfile()
                    return bluetoothState?() ?? bluetooth
                }
                catch is CancellationError { throw CancellationError() }
                catch let error as ProfileActionError { throw error }
                catch { throw Self.presentationError(error) }
            },
            setMinimumSharedInterests: { value in
                try await self.writeProfile { try await $0.setMinimumSharedInterests(value) }
            },
            setFieldVisibility: { field, level in
                guard let field = EncounterBackend.ProfileField(rawValue: field.rawValue),
                      let level = EncounterBackend.VisibilityLevel(rawValue: level.rawValue) else {
                    throw ProfileActionError(code: .invalidInput, fields: ["field", "level"])
                }
                return try await self.writeProfile { try await $0.setFieldVisibility(field: field, level: level) }
            })
    }

    private func writeProfile(_ write: @MainActor (OwnAccountService) async throws -> Void) async throws -> OwnProfileState {
        let fresh = try await ownAccountOperation { service in
            try await write(service)
            return try await service.getOwnProfile()
        }
        let state = Self.present(fresh)
        profile = state
        return state
    }

    private func ownAccountOperation<Value>(_ operation: @MainActor (OwnAccountService) async throws -> Value) async throws -> Value {
        guard case .signedIn(let user) = state, let service else { throw ProfileActionError(code: .notAuthenticated) }
        do {
            let result = try await operation(service)
            guard state == .signedIn(user) else { throw ProfileActionError(code: .notAuthenticated) }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as ProfileActionError { throw error }
        catch { throw Self.presentationError(error) }
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
