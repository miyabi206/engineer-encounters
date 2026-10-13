import Combine
import EncounterBackend
import EncounterUI
import Foundation

/// Installation-only preference. Account cleanup deliberately never owns this key.
@MainActor
final class InstallationSampleDismissalStore: SampleEncounterDismissalStore {
    static let key = "EngineerEncounters.SampleEncounter.Dismissed"
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    var isSampleEncounterDismissed: Bool { defaults.bool(forKey: Self.key) }
    func dismissSampleEncounter() { defaults.set(true, forKey: Self.key) }
}

/// The UI model is the only card cache, and is always memory-only.
@MainActor
final class DiscoverAdapter: ObservableObject {
    @Published private(set) var model: DiscoverModel?
    @Published private(set) var failure: ProfileActionError?
    var beforeFeedRead: @MainActor () async throws -> Void = {}
    var encounterWasDeleted: @MainActor (String) -> Void = { _ in }
    private var pendingHiddenIDs: Set<String> = []
    var interests: [InterestOption] = []
    private let account: AccountModel
    private var backend: SessionBackendServices?
    private var epoch: UUID?
    private var lastProfile: OwnProfileState?
    private var subscriptions: Set<AnyCancellable> = []

    init(account: AccountModel) {
        self.account = account
        account.$profile.sink { [weak self] in self?.receive(profile: $0) }.store(in: &subscriptions)
        account.$state.removeDuplicates().sink { [weak self] state in
            guard case .signedIn = state else { self?.clearAuthorization(); return }
        }.store(in: &subscriptions)
    }

    func configure(_ backend: SessionBackendServices?) {
        if epoch != account.sessionGeneration || self.backend?.owner != backend?.owner {
            invalidate()
        }
        self.backend = backend
        guard backend != nil else { clearAuthorization(); return }
        epoch = account.sessionGeneration
        receive(profile: account.profile)
    }

    func invalidate() {
        clearAuthorization()
        pendingHiddenIDs = []
        model = nil; backend = nil; epoch = nil; lastProfile = nil; interests = []; failure = nil
    }

    func clearAuthorization() {
        if let model { model.receiveAccess(discoveryOn: model.discoveryOn, isAuthorized: false) }
    }

    private func receive(profile: OwnProfileState?) {
        if model == nil {
            guard backend != nil, let profile else { return }
            // Initial access belongs to the first screen load. An access-restoration
            // task could otherwise reread a screen requested before that task runs.
            model = DiscoverModel(actions: actions(), discoveryOn: profile.discoveryOn,
                                  isAuthorized: backend?.isCurrent == true && !account.deletionSuspended && profile.moderationState == "active")
            lastProfile = profile
            return
        }
        guard let model else { return }
        if lastProfile != profile {
            // Changing prerequisites or authorization always drops old metadata before re-reading.
            model.receiveAccess(discoveryOn: false, isAuthorized: false)
        }
        lastProfile = profile
        model.receiveAccess(discoveryOn: profile?.discoveryOn ?? false,
                            isAuthorized: backend?.isCurrent == true && !account.deletionSuspended && profile?.moderationState == "active")
    }

    /// Later safety/deletion consumers call this after their acknowledged mutation.
    /// Refetch current authorization instead of guessing which other-person fields survived.
    func protectedContentDidChange() {
        model?.receiveAccess(discoveryOn: false, isAuthorized: false)
        receive(profile: account.profile)
    }

    func conceal(_ id: String) {
        pendingHiddenIDs.insert(id)
        protectedContentDidChange()
    }
    func clearPendingHide(_ id: String) { pendingHiddenIDs.remove(id) }
    func allowsNotification(for id: String) -> Bool { !pendingHiddenIDs.contains(id) }

    func authorizeReopening(_ id: String) async -> Bool {
        guard let model, let profile = account.profile, !account.deletionSuspended else { return false }
        model.receiveAccess(discoveryOn: false, isAuthorized: false)
        let reload = model.receiveAccess(discoveryOn: profile.discoveryOn,
            isAuthorized: backend?.isCurrent == true && profile.moderationState == "active")
        await reload?.value
        return model.card?.card.id == id
    }

    func foreground() async {
        guard let model, model.feedState != .idle else { return }
        await model.loadFeed()
    }

    func actions() -> DiscoverActions {
        let epoch = account.sessionGeneration
        let fence = account.backendCallFence()
        return DiscoverActions(loadFeed: {
            try self.require(epoch: epoch, fence: fence)
            try await self.beforeFeedRead()
            let result = try await self.call(epoch: epoch, fence: fence) { try await $0.encounter.getEncounterFeed() }
            return try self.present(result)
        }, loadCard: { id in
            try self.require(epoch: epoch, fence: fence)
            // A local pending hide is not a server deletion. Preserve the requested
            // detail so cancelling the report can recheck its authorization.
            if self.pendingHiddenIDs.contains(id) { throw CancellationError() }
            let id = try Self.identifier(id, field: "encounter_id")
            let result = try await self.call(epoch: epoch, fence: fence) { try await $0.encounter.getEncounterCard(encounterID: id) }
            return EncounterDetail(card: try self.present(result.card), favorite: result.favorite,
                                   savedLinkIDs: Set(result.savedLinkIDs.map { $0.uuidString.lowercased() }))
        }, setFavorite: { id, favorite in
            let id = try Self.identifier(id, field: "encounter_id")
            let result = try await self.call(epoch: epoch, fence: fence) { try await $0.encounter.setEncounterFavorite(encounterID: id, favorite: favorite) }
            return EncounterFavoriteResult(encounterID: result.encounterID.uuidString.lowercased(), favorite: result.favorite)
        }, saveLink: { id, link in
            try await self.setSaved(id, link: link, saved: true, epoch: epoch, fence: fence)
        }, unsaveLink: { id, link in
            try await self.setSaved(id, link: link, saved: false, epoch: epoch, fence: fence)
        },
        deleteEncounter: { [self] value in
            let id = try Self.identifier(value, field: "encounter_id")
            do { _ = try await self.call(epoch: epoch, fence: fence) { try await $0.encounter.deleteEncounter(encounterID: id) } }
            catch let error as ProfileActionError where error.code == .notFound { }
            // Navigation removes S07 synchronously; the task drops/reloads after DiscoverModel completes its write.
            self.encounterWasDeleted(value)
            Task { [weak self] in
                guard let self, fence.isCurrent(), self.account.sessionGeneration == epoch else { return }
                self.protectedContentDidChange()
            }
        }, loadFavorites: {
            let result = try await self.call(epoch: epoch, fence: fence) { try await $0.encounter.listEncounterFavorites() }
            return try self.present(result)
        }, loadSavedLinks: {
            let result = try await self.call(epoch: epoch, fence: fence) { try await $0.encounter.listSavedLinks() }
            return EncounterSavedLinkList(links: try result.links.filter { !self.pendingHiddenIDs.contains($0.encounterID.uuidString.lowercased()) }.map {
                EncounterSavedLink(encounterID: $0.encounterID.uuidString.lowercased(), day: Self.day($0.day),
                    kind: EncounterUI.EncounterKind(rawValue: $0.kind.rawValue)!, link: try Self.present($0.link))
            }, truncated: result.truncated)
        })
    }

    private func setSaved(_ id: String, link: String, saved: Bool, epoch: UUID, fence: BackendCallFence) async throws -> EncounterSavedResult {
        let id = try Self.identifier(id, field: "encounter_id")
        let link = try Self.identifier(link, field: "link_id")
        let result = try await call(epoch: epoch, fence: fence) {
            if saved { return try await $0.encounter.saveLink(encounterID: id, linkID: link) }
            return try await $0.encounter.unsaveLink(encounterID: id, linkID: link)
        }
        return EncounterSavedResult(encounterID: result.encounterID.uuidString.lowercased(),
                                    linkID: result.linkID.uuidString.lowercased(), saved: result.saved)
    }

    private func require(epoch: UUID, fence: BackendCallFence) throws {
        guard fence.isCurrent(), account.sessionGeneration == epoch, case .signedIn = account.state,
              !account.sessionChangeInProgress, let backend, backend.isCurrent else {
            throw ProfileActionError(code: .notAuthenticated)
        }
        guard !account.deletionSuspended else { throw CancellationError() }
    }

    private func call<Value>(epoch: UUID, fence: BackendCallFence, _ operation: @MainActor (SessionBackendServices.Services) async throws -> Value) async throws -> Value {
        try require(epoch: epoch, fence: fence)
        guard let backend else { throw ProfileActionError(code: .notAuthenticated) }
        do {
            let result = try await backend.call(operation)
            failure = nil
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            let value = AccountModel.presentationError(error)
            if self.backend === backend, account.sessionGeneration == epoch, backend.isCurrent {
                failure = value
                // DiscoverModel consumes authorization errors, clearing its cache and
                // permitting a fresh Retry without retaining the rejected response.
                if value.code == .prerequisiteMissing, value.fields.contains("discovery") {
                    model?.receiveAccess(discoveryOn: false, isAuthorized: true)
                }
                if value.code == .notAuthenticated { await account.rejectDeadSession(generation: epoch) }
            }
            throw value
        }
    }

    private func present(_ value: EncounterFeedTransfer) throws -> EncounterCardList {
        EncounterCardList(cards: try value.cards.filter { !pendingHiddenIDs.contains($0.card.encounterID.uuidString.lowercased()) }.map {
            EncounterFeedCard(card: try present($0.card), favorite: $0.favorite,
                              sharedInterestIDs: $0.sharedInterestIDs.map(Set.init))
        }, truncated: value.truncated)
    }

    func present(_ value: CardTransfer) throws -> EncounterCard {
        EncounterCard(id: value.encounterID.uuidString.lowercased(), kind: EncounterUI.EncounterKind(rawValue: value.kind.rawValue)!,
            day: Self.day(value.day), displayName: value.displayName, introduction: value.introduction,
            interests: (value.interests ?? []).map { id in
                interests.first { $0.id == id } ?? InterestOption(id: id, labelJapanese: id, labelEnglish: id)
            }, purposes: Set((value.purposes ?? []).compactMap { EncounterUI.ProfilePurpose(rawValue: $0.rawValue) }),
            contactDetail: value.contactDetail, links: try (value.links ?? []).map(Self.present), isShell: value.shell == true)
    }

    static func day(_ value: WireDay) -> EncounterDay {
        let fields = value.rawValue.split(separator: "-").map { Int($0)! }
        return EncounterDay(year: fields[0], month: fields[1], day: fields[2])
    }

    private static func present(_ value: VisibleLinkTransfer) throws -> EncounterLinkCard {
        guard let url = URL(string: value.url), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw ProfileActionError(code: .unavailable) }
        return EncounterLinkCard(id: value.linkID.uuidString.lowercased(), source: value.source,
            title: value.title, description: value.description, tags: value.tags, mainLanguage: value.mainLanguage,
            openingText: value.openingText, url: url, verified: value.verificationState == .verified)
    }

    static func identifier(_ value: String, field: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw ProfileActionError(code: .invalidInput, fields: [field]) }
        return id
    }
}
