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
    @Published private(set) var needsAuthorizationRetry = false
    var interests: [InterestOption] = [] {
        didSet {
            guard interests != oldValue, !interests.isEmpty, let model, backend?.isCurrent == true else { return }
            let reloadFeed = model.feedState == .loaded
            let reloadFavorites = model.favoritesState == .loaded
            let cardID = model.card?.card.id
            // Re-authorize requested resources with the catalogue's labels. No wire/card cache is persisted.
            Task { [weak self, weak model] in
                guard let self, let model, self.model === model, self.backend?.isCurrent == true else { return }
                if reloadFeed { await model.loadFeed() }
                if reloadFavorites { await model.loadFavorites() }
                if let id = cardID { await model.loadCard(id) }
            }
        }
    }
    private var catalogueLoad: (id: UUID, task: Task<[InterestOption], any Error>)?
    private let account: AccountModel
    private var backend: SessionBackendServices?
    private var epoch: UUID?
    private var lastProfile: OwnProfileState?
    private var modelSubscription: AnyCancellable?
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
        catalogueLoad?.task.cancel(); catalogueLoad = nil
        clearAuthorization()
        needsAuthorizationRetry = false
        pendingHiddenIDs = []
        modelSubscription = nil
        model = nil; backend = nil; epoch = nil; lastProfile = nil; interests = []; failure = nil
    }

    func clearAuthorization() {
        if let model { model.receiveAccess(discoveryOn: model.discoveryOn, isAuthorized: false) }
    }

    func rejectAuthorization() {
        clearAuthorization()
        needsAuthorizationRetry = true
    }

    func retryAuthorization() async {
        guard needsAuthorizationRetry, backend?.isCurrent == true, !account.deletionSuspended else { return }
        let epoch = account.sessionGeneration, fence = account.backendCallFence()
        let backend = self.backend
        do {
            _ = try await account.loadOwnProfile()
            guard fence.isCurrent(), epoch == account.sessionGeneration, self.backend === backend, backend?.isCurrent == true else { return }
            needsAuthorizationRetry = false
            receive(profile: account.profile)
        } catch {
            guard fence.isCurrent(), epoch == account.sessionGeneration, self.backend === backend else { return }
            failure = error as? ProfileActionError ?? .init(code: .unavailable)
        }
    }

    private func loadCatalogue(epoch: UUID, fence: BackendCallFence) async throws {
        try require(epoch: epoch, fence: fence)
        guard interests.isEmpty else { return }
        if let catalogueLoad {
            _ = try? await catalogueLoad.task.value
            try require(epoch: epoch, fence: fence)
            return
        }
        let id = UUID()
        let task = Task {
            try self.require(epoch: epoch, fence: fence)
            let result = try await self.account.ownAccountOperation { try await $0.listInterests() }
            try self.require(epoch: epoch, fence: fence)
            return result.map { InterestOption(id: $0.interestID, labelJapanese: $0.labelJA, labelEnglish: $0.labelEN) }
        }
        catalogueLoad = (id, task)
        defer { if catalogueLoad?.id == id { catalogueLoad = nil } }
        let loaded = try? await task.value
        try require(epoch: epoch, fence: fence)
        if let loaded { interests = loaded }
    }

    private func receive(profile: OwnProfileState?) {
        if model == nil {
            guard backend != nil, let profile else { return }
            // Initial access belongs to the first screen load. An access-restoration
            // task could otherwise reread a screen requested before that task runs.
            model = DiscoverModel(actions: actions(), discoveryOn: profile.discoveryOn,
                                  isAuthorized: backend?.isCurrent == true && !account.deletionSuspended && profile.moderationState == "active")
            modelSubscription = model?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
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
            try await self.loadCatalogue(epoch: epoch, fence: fence)
            try await self.beforeFeedRead()
            let result = try await self.call(epoch: epoch, fence: fence) { try await $0.encounter.getEncounterFeed() }
            return try self.present(result)
        }, loadCard: { id in
            try self.require(epoch: epoch, fence: fence)
            // A local pending hide is not a server deletion. Preserve the requested
            // detail so cancelling the report can recheck its authorization.
            if self.pendingHiddenIDs.contains(id) { throw CancellationError() }
            try await self.loadCatalogue(epoch: epoch, fence: fence)
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
            try await self.loadCatalogue(epoch: epoch, fence: fence)
            let result = try await self.call(epoch: epoch, fence: fence) { try await $0.encounter.listEncounterFavorites() }
            return try self.present(result)
        }, loadSavedLinks: {
            let result = try await self.call(epoch: epoch, fence: fence) { try await $0.encounter.listSavedLinks() }
            return EncounterSavedLinkList(links: result.links.filter { !self.pendingHiddenIDs.contains($0.encounterID.uuidString.lowercased()) }.compactMap { value in
                guard let link = Self.present(value.link) else { return nil }
                return EncounterSavedLink(encounterID: value.encounterID.uuidString.lowercased(), day: Self.day(value.day),
                    kind: EncounterUI.EncounterKind(rawValue: value.kind.rawValue)!, link: link)
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
        var rejected = false
        do {
            let result = try await backend.call {
                do { return try await operation($0) }
                catch { rejected = error as? BackendError == .notAuthenticated; throw error }
            }
            failure = nil
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            let value = AccountModel.presentationError(error)
            if rejected, value.code == .notAuthenticated { await account.rejectDeadSession(generation: epoch) }
            if self.backend === backend, account.sessionGeneration == epoch, backend.isCurrent {
                failure = value
                // DiscoverModel consumes authorization errors, clearing its cache and
                // permitting a fresh Retry without retaining the rejected response.
                if value.code == .prerequisiteMissing, value.fields.contains("discovery") {
                    model?.receiveAccess(discoveryOn: false, isAuthorized: true)
                }
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
            interests: (value.interests ?? []).compactMap { id in interests.first { $0.id == id } }, purposes: Set((value.purposes ?? []).compactMap { EncounterUI.ProfilePurpose(rawValue: $0.rawValue) }),
            contactDetail: value.contactDetail, links: (value.links ?? []).compactMap(Self.present), isShell: value.shell == true)
    }

    static func day(_ value: WireDay) -> EncounterDay {
        let fields = value.rawValue.split(separator: "-").map { Int($0)! }
        return EncounterDay(year: fields[0], month: fields[1], day: fields[2])
    }

    private static func present(_ value: VisibleLinkTransfer) -> EncounterLinkCard? {
        guard let url = URL(string: value.url), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return EncounterLinkCard(id: value.linkID.uuidString.lowercased(), source: value.source,
            title: value.title, description: value.description, tags: value.tags, mainLanguage: value.mainLanguage,
            openingText: value.openingText, url: url, verified: value.verificationState == .verified)
    }

    static func identifier(_ value: String, field: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw ProfileActionError(code: .invalidInput, fields: [field]) }
        return id
    }
}
