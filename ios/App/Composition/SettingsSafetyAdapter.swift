import Combine
import EncounterBackend
import EncounterUI
import Foundation
import UIKit

@MainActor
final class SafetySheetPresentation: Identifiable {
    let id = UUID()
    let model: SafetyReportModel
    init(_ model: SafetyReportModel) { self.model = model }
}

/// Account-bound actions. Pending safety state contains opaque references and reasons only.
@MainActor
final class SettingsSafetyAdapter: ObservableObject {
    @Published private(set) var sheet: SafetySheetPresentation?
    private let account: AccountModel
    private let links: LinkAdapter
    private let discover: DiscoverAdapter
    private var backend: SessionBackendServices?
    private var verifiedProfile: OwnProfileState?
    var suspendParticipation: @MainActor () -> Void = {}
    var deleteAccount: @MainActor (UUID, BackendCallFence) async throws -> Bool = { _, _ in throw ProfileActionError(code: .unavailable) }
    var checkAccount: @MainActor (UUID, BackendCallFence) async throws -> AccountSettingsAccountState = { _, _ in throw ProfileActionError(code: .unavailable) }

    init(account: AccountModel, links: LinkAdapter, discover: DiscoverAdapter) {
        self.account = account; self.links = links; self.discover = discover
    }
    func configure(_ backend: SessionBackendServices?) { self.backend = backend }
    func invalidate() { sheet = nil; backend = nil; verifiedProfile = nil }

    func myCardActions(openOriginal: @escaping @MainActor (URL) async throws -> Void = SettingsSafetyAdapter.open) -> MyCardActions {
        let epoch = account.sessionGeneration
        let fence = account.backendCallFence()
        let linkActions = links.actions()
        return .init(load: {
            try self.require(epoch, fence: fence)
            let profile = try await self.account.loadOwnProfile()
            let ownLinks = try await linkActions.loadLinks()
            let interests = try await self.call(epoch, fence: fence) { try await $0.ownAccount.listInterests() }
            try self.require(epoch, fence: fence)
            return MyCardData(profile: profile, links: ownLinks, interests: interests.map {
                .init(id: $0.interestID, labelJapanese: $0.labelJA, labelEnglish: $0.labelEN)
            })
        }, openOriginal: { url in
            try self.require(epoch, fence: fence)
            try await openOriginal(url)
        })
    }

    func reportSettingsActions() -> ReportSettingsActions {
        let epoch = account.sessionGeneration, fence = account.backendCallFence()
        return .init(load: {
            Self.present(try await self.call(epoch, fence: fence) { try await $0.report.getReportSettings() })
        }, saveTime: { time in
            guard time.isValid else { throw ProfileActionError(code: .invalidInput, fields: ["hour", "minute"]) }
            return Self.present(try await self.call(epoch, fence: fence) {
                try await $0.report.setReportTime(hour: Int32(time.hour), minute: Int32(time.minute))
            })
        }, setNotifications: { enabled in
            Self.present(try await self.call(epoch, fence: fence) { try await $0.report.setNotificationsEnabled(enabled: enabled) })
        }, requestPermission: {
            try self.require(epoch, fence: fence)
            return .unavailable
        })
    }

    func blockedActions() -> SafetyBlockedActions {
        let epoch = account.sessionGeneration, fence = account.backendCallFence()
        return .init(load: {
            let result = try await self.call(epoch, fence: fence) { try await $0.safety.listBlocks() }
            return SafetyBlockList(blocks: result.blocks.map {
                .init(id: $0.blockID.uuidString.lowercased(), placedDay: DiscoverAdapter.day($0.placedDay))
            }, truncated: result.truncated)
        }, unblock: { value in
            let id = try DiscoverAdapter.identifier(value, field: "block_id")
            do { _ = try await self.call(epoch, fence: fence) { try await $0.safety.unblock(blockID: id) } }
            catch let error as ProfileActionError where error.code == .notFound {
                self.discover.protectedContentDidChange(); throw error
            }
            self.discover.protectedContentDidChange()
        })
    }

    func reportActions(encounterID: String) -> SafetyReportActions {
        let epoch = account.sessionGeneration, fence = account.backendCallFence()
        return .init(report: { request in
            let id = try DiscoverAdapter.identifier(request.encounterID, field: "encounter_id")
            let link = try request.linkID.map { try DiscoverAdapter.identifier($0, field: "link_id") }
            do {
                _ = try await self.call(epoch, fence: fence) {
                    try await $0.safety.reportEncounterPerson(encounterID: id,
                        reason: EncounterReportReason(rawValue: request.reason.rawValue)!, linkID: link)
                }
            } catch let error as ProfileActionError where error.code == .notFound { }
            self.discover.protectedContentDidChange()
        }, block: { value in
            let id = try DiscoverAdapter.identifier(value, field: "encounter_id")
            do { _ = try await self.call(epoch, fence: fence) { try await $0.safety.blockEncounterPerson(encounterID: id) } }
            catch let error as ProfileActionError where error.code == .notFound { }
            self.discover.protectedContentDidChange()
        }, conceal: {
            guard fence.isCurrent(), self.account.sessionGeneration == epoch else { return }
            self.discover.conceal(encounterID)
        }, clearPendingHide: {
            guard fence.isCurrent(), self.account.sessionGeneration == epoch else { return }
            self.discover.clearPendingHide(encounterID)
        }, authorizeReopening: {
            try self.require(epoch, fence: fence)
            let authorized = await self.discover.authorizeReopening(encounterID)
            try self.require(epoch, fence: fence)
            return authorized
        })
    }

    func presentReport(_ encounterID: String, linkID: String?, completed: @escaping @MainActor () -> Void) {
        guard !account.deletionSuspended, sheet == nil,
              let card = discover.model?.card?.card, card.id == encounterID,
              linkID == nil || card.links.contains(where: { $0.id == linkID }) else { return }
        let epoch = account.sessionGeneration, fence = account.backendCallFence()
        let model = SafetyReportModel(encounterID: encounterID, link: linkID.map { .init(id: $0) },
            actions: reportActions(encounterID: encounterID), navigation: .init(completed: { [weak self] in
                guard let self, fence.isCurrent(), self.account.sessionGeneration == epoch else { return }
                self.sheet = nil; completed()
            }, reopenEncounter: { [weak self] in
                guard let self, fence.isCurrent(), self.account.sessionGeneration == epoch else { return }
                self.sheet = nil
            }))
        sheet = SafetySheetPresentation(model)
    }

    func accountActions() -> AccountSettingsActions {
        let epoch = account.sessionGeneration, fence = account.backendCallFence()
        return .init(load: { try await self.loadAccount(epoch, fence: fence) }, disconnectGitHub: {
            try self.require(epoch, fence: fence)
            do { try await self.links.disconnectGitHub() }
            catch let error as LinkActionError {
                if error.isLastLink { throw ProfileActionError(code: .prerequisiteMissing, fields: ["link"]) }
                throw Self.profileError(error)
            }
            self.discover.protectedContentDidChange()
            return try await self.loadAccount(epoch, fence: fence)
        }, signOut: {
            try self.require(epoch, fence: fence)
            do { try await self.account.signOut() }
            catch { throw AccountModel.presentationError(error) }
        }, deleteAccount: {
            try self.require(epoch, fence: fence, allowingDeletion: true)
            return try await self.deleteAccount(epoch, fence)
        }, reloadAccount: {
            // Stale actions must fail before even consulting a cached deletion answer.
            guard fence.isCurrent(), epoch == self.account.sessionGeneration else {
                throw ProfileActionError(code: .notAuthenticated)
            }
            return try await self.checkAccount(epoch, fence)
        }, resumeParticipation: {
            // Verification and resumption belong to the composition, independent of this screen.
        }, suspendParticipation: {
            guard fence.isCurrent(), epoch == self.account.sessionGeneration else { return }
            self.suspendParticipation()
        })
    }

    func performDeletion(_ epoch: UUID, fence: BackendCallFence) async throws -> Bool {
        let result = try await call(epoch, fence: fence, allowingDeletion: true) { try await $0.deletion.deleteOwnAccount() }
        if result.deleted { await account.completeAccountDeletion(generation: epoch) }
        return result.deleted
    }

    func verifyAccount(_ epoch: UUID, fence: BackendCallFence) async throws -> AccountSettingsAccountState {
        try require(epoch, fence: fence, allowingDeletion: true)
        do {
            let fresh = try await account.ownAccountOperation(allowingDeletion: true) { try await $0.getOwnProfile() }
            try require(epoch, fence: fence, allowingDeletion: true)
            let profile = AccountModel.present(fresh)
            verifiedProfile = profile
            return .present(accountData(profile: profile, ownLinks: links.links ?? []))
        } catch let error as ProfileActionError where error.code == .notFound {
            try require(epoch, fence: fence, allowingDeletion: true)
            await account.completeAccountDeletion(generation: epoch)
            return .deleted
        }
    }

    func publishVerifiedProfile() {
        if let profile = verifiedProfile { account.publishProfile(profile, stale: false) }
        verifiedProfile = nil
    }

    private func loadAccount(_ epoch: UUID, fence: BackendCallFence) async throws -> AccountSettingsData {
        try require(epoch, fence: fence)
        let linkActions = links.actions()
        let profile = try await account.loadOwnProfile()
        try require(epoch, fence: fence)
        _ = try await linkActions.loadConnection()
        let ownLinks = try await linkActions.loadLinks()
        try require(epoch, fence: fence)
        return accountData(profile: profile, ownLinks: ownLinks)
    }
    private func accountData(profile: OwnProfileState, ownLinks: [OwnLinkState]) -> AccountSettingsData {
        let handle: String?
        if case .connected(let value) = links.connection { handle = value } else { handle = nil }
        return .init(signIn: BuildKind.isDevelopment ? .temporary : .apple,
            githubConnected: links.connection.isConnected, githubHandle: handle, discoveryOn: profile.discoveryOn,
            linkCount: ownLinks.count, githubRepositoryCount: ownLinks.filter { $0.source == .github }.count)
    }

    private func require(_ epoch: UUID, fence: BackendCallFence, allowingDeletion: Bool = false) throws {
        guard fence.isCurrent(), account.sessionGeneration == epoch, account.state.isSignedIn,
              !account.sessionChangeInProgress, backend?.isCurrent == true else {
            throw ProfileActionError(code: .notAuthenticated)
        }
        guard allowingDeletion || !account.deletionSuspended else { throw CancellationError() }
    }
    private func call<Value>(_ epoch: UUID, fence: BackendCallFence, allowingDeletion: Bool = false,
                             _ operation: @MainActor (SessionBackendServices.Services) async throws -> Value) async throws -> Value {
        try require(epoch, fence: fence, allowingDeletion: allowingDeletion)
        guard let backend else { throw ProfileActionError(code: .unavailable) }
        do { return try await backend.call(outgoing: allowingDeletion, operation) }
        catch is CancellationError { throw CancellationError() }
        catch {
            let failure = error as? ProfileActionError ?? AccountModel.presentationError(error)
            if failure.code == .notAuthenticated, fence.isCurrent(), backend.isCurrent {
                await account.rejectDeadSession(generation: epoch)
            }
            throw failure
        }
    }
    static func profileError(_ error: LinkActionError) -> ProfileActionError {
        switch error.code {
        case .invalidInput: return .init(code: .invalidInput, fields: error.details)
        case .prerequisiteMissing: return .init(code: .prerequisiteMissing, fields: error.details)
        default:
            let codes: [String: ProfileActionError.Code] = ["not_authenticated": .notAuthenticated,
                "account_not_ready": .accountNotReady, "declaration_required": .declarationRequired,
                "not_found": .notFound, "rate_limited": .rateLimited]
            return .init(code: error.details.compactMap { codes[$0] }.first ?? .unavailable)
        }
    }
    static func present(_ value: ReportSettingsTransfer) -> ReportSettingsData {
        .init(time: .init(hour: value.reportHour, minute: value.reportMinute), timeZone: value.timeZone,
              notificationsEnabled: value.notificationsEnabled)
    }
    static func legalData(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> LegalData {
        func address(_ key: String) -> URL? {
            guard let text = info[key] as? String, !text.contains("$("), let url = URL(string: text), url.scheme == "https",
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            return url
        }
        let contact = (info["ModerationContact"] as? String).flatMap { $0.contains("$(") ? nil : $0 }
        return .init(terms: address("TermsURL"), privacy: address("PrivacyURL"), support: address("SupportURL"),
            moderationContact: contact, version: info["CFBundleShortVersionString"] as? String)
    }
    static func hasSupport(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> Bool {
        let data = legalData(info: info)
        return data.support != nil || data.contact != nil
    }
    static func legalActions() -> LegalActions {
        .init(open: open, contact: { contact in
            var url = URLComponents(); url.scheme = "mailto"; url.path = contact
            guard let address = url.url else { throw ProfileActionError(code: .invalidInput) }
            try await open(address)
        }, copy: { UIPasteboard.general.string = $0 })
    }
    static func open(_ url: URL) async throws {
        guard await UIApplication.shared.open(url) else { throw ProfileActionError(code: .unavailable) }
    }
}
