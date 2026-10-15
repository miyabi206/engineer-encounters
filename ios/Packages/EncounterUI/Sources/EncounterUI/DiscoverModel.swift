import Combine
import Foundation

public enum DiscoverLoadState: Equatable, Sendable { case idle, loading, loaded, failed, missing }
public enum DiscoverBluetoothStatus: Equatable, Sendable {
    case available, poweredOff, denied, unavailable, checking, failed
}
public enum DiscoverFavoritesSegment: String, CaseIterable, Sendable { case encounters, savedLinks }
public enum DiscoverDeletionState: Equatable, Sendable {
    case none, confirming(String), deleting(String), failed(String)
}
public enum DiscoverOperation: Equatable, Sendable {
    case favorite(String, Bool), save(String, String, Bool), delete(String)
}

/// Caller-owned, memory-only state. Refreshes preserve authorized content; each resource
/// has its own fence, and an access epoch invalidates all responses on authorization loss.
@MainActor
public final class DiscoverModel: ObservableObject {
    @Published public private(set) var feed: [EncounterFeedCard] = []
    @Published public private(set) var favorites: [EncounterFeedCard] = []
    @Published public private(set) var savedLinks: [EncounterSavedLink] = []
    @Published public private(set) var card: EncounterDetail?
    @Published public private(set) var feedState: DiscoverLoadState = .idle
    @Published public private(set) var detailState: DiscoverLoadState = .idle
    @Published public private(set) var favoritesState: DiscoverLoadState = .idle
    @Published public private(set) var savedLinksState: DiscoverLoadState = .idle
    @Published public private(set) var feedTruncated = false
    @Published public private(set) var favoritesTruncated = false
    @Published public private(set) var savedLinksTruncated = false
    @Published public private(set) var discoveryOn: Bool
    @Published public private(set) var isAuthorized: Bool
    @Published public private(set) var isWriting = false
    @Published public private(set) var deletion: DiscoverDeletionState = .none
    @Published public private(set) var failedOperation: DiscoverOperation?
    @Published public private(set) var failedCardReloadIDs: Set<String> = []
    public let actions: DiscoverActions
    private var epoch: UInt = 0
    private var feedEpoch: UInt = 0
    private var favoritesEpoch: UInt = 0
    private var savedEpoch: UInt = 0
    private var detailEpoch: UInt = 0
    private var feedContentEpoch: UInt = 0
    private var favoritesContentEpoch: UInt = 0
    private var savedContentEpoch: UInt = 0
    private var detailContentEpoch: UInt = 0
    private var removalEpoch: UInt = 0
    private var removedAt: [String: UInt] = [:]
    private var canRetryAuthorization = false
    private var requestedFeed = false
    private var requestedFavorites = false
    private var requestedSavedLinks = false
    private var requestedCardID: String?
    // Keep positions only, never a previously authorized card, while access is rechecked.
    private struct ConcealedCard {
        let feedIndex: Int?
        let favoritesIndex: Int?
        let savedIndex: Int?
        var request = UUID()
    }
    private var concealedCards: [String: ConcealedCard] = [:]

    public init(actions: DiscoverActions, discoveryOn: Bool, isAuthorized: Bool = true) {
        self.actions = actions; self.discoveryOn = discoveryOn; self.isAuthorized = isAuthorized
    }

    public var canRead: Bool { discoveryOn && isAuthorized }
    private var canLoad: Bool { discoveryOn && (isAuthorized || canRetryAuthorization) }
    public var dayGroups: [EncounterDayGroup] { EncounterDayGroup.grouped(feed) }
    public var favoriteDayGroups: [EncounterDayGroup] { EncounterDayGroup.grouped(favorites) }

    /// Composition calls this on sign-out or an authorization/participation change.
    /// Returning access reloads requested screens, including an open detail, without a tap.
    @discardableResult
    public func receiveAccess(discoveryOn: Bool, isAuthorized: Bool) -> Task<Void, Never>? {
        let wasReadable = canRead
        if !discoveryOn || !isAuthorized { clearProtectedContent() }
        self.discoveryOn = discoveryOn; self.isAuthorized = isAuthorized
        canRetryAuthorization = false
        if !wasReadable && canRead {
            let token = epoch
            return Task {
                guard self.current(token) else { return }
                async let feed: Void = self.reloadFeedIfRequested(token)
                async let favorites: Void = self.reloadFavoritesIfRequested(token)
                async let saved: Void = self.reloadSavedIfRequested(token)
                async let card: Void = self.reloadCardIfRequested(token)
                _ = await (feed, favorites, saved, card)
            }
        }
        return nil
    }

    private func reloadFeedIfRequested(_ token: UInt) async {
        guard current(token), requestedFeed else { return }
        await loadFeed()
    }
    private func reloadFavoritesIfRequested(_ token: UInt) async {
        guard current(token), requestedFavorites else { return }
        await loadFavorites()
    }
    private func reloadSavedIfRequested(_ token: UInt) async {
        guard current(token), requestedSavedLinks else { return }
        await loadSavedLinks()
    }
    private func reloadCardIfRequested(_ token: UInt) async {
        guard current(token), let id = requestedCardID else { return }
        await loadCard(id)
    }

    public func clearProtectedContent() {
        epoch &+= 1
        feedEpoch &+= 1; favoritesEpoch &+= 1; savedEpoch &+= 1; detailEpoch &+= 1
        feed = []; favorites = []; savedLinks = []; card = nil
        feedState = .idle; detailState = .idle; favoritesState = .idle; savedLinksState = .idle
        feedTruncated = false; favoritesTruncated = false; savedLinksTruncated = false
        removedAt = [:]
        concealedCards = [:]; failedCardReloadIDs = []
        isWriting = false; deletion = .none; failedOperation = nil
    }

    public func loadFeed() async {
        requestedFeed = true
        guard canLoad else { return }
        feedEpoch &+= 1
        let token = epoch, resource = feedEpoch, removals = removalEpoch
        feedState = .loading
        do {
            let result = try await actions.loadFeed()
            guard current(token), resource == feedEpoch else { return }
            authorizeRead()
            feedContentEpoch &+= 1
            feed = mergeReauthorized(result.cards, into: feed, removals: removals, id: { $0.id })
            feedTruncated = result.truncated; feedState = .loaded
        } catch {
            guard current(token), resource == feedEpoch else { return }
            if let failure = error as? ProfileActionError,
               failure.code == .prerequisiteMissing, failure.fields.contains("discovery") {
                receiveAccess(discoveryOn: false, isAuthorized: isAuthorized)
            } else {
                handleReadFailure(error); feedState = .failed
            }
        }
    }

    public func loadCard(_ id: String) async {
        requestedCardID = id
        guard canLoad else { return }
        if concealedCards[id] != nil { await reloadConcealedCard(id); return }
        detailEpoch &+= 1
        let token = epoch, resource = detailEpoch, removals = removalEpoch
        detailState = .loading
        do {
            let result = try await actions.loadCard(id)
            guard current(token), resource == detailEpoch, (removedAt[id] ?? 0) <= removals else { return }
            authorizeRead()
            guard let result, result.card.id == id else {
                remove(id); card = nil; detailState = .missing; return
            }
            detailContentEpoch &+= 1
            card = result; detailState = .loaded
        } catch {
            guard current(token), resource == detailEpoch, (removedAt[id] ?? 0) <= removals else { return }
            if isNotFound(error) { remove(id); card = nil; detailState = .missing }
            else { handleReadFailure(error); detailState = .failed }
        }
    }

    public func loadFavorites() async {
        requestedFavorites = true
        guard canLoad else { return }
        favoritesEpoch &+= 1
        let token = epoch, resource = favoritesEpoch, removals = removalEpoch
        favoritesState = .loading
        do {
            let result = try await actions.loadFavorites()
            guard current(token), resource == favoritesEpoch else { return }
            authorizeRead()
            favoritesContentEpoch &+= 1
            favorites = mergeReauthorized(result.cards, into: favorites, removals: removals, id: { $0.id })
            favoritesTruncated = result.truncated; favoritesState = .loaded
        } catch {
            guard current(token), resource == favoritesEpoch else { return }
            handleReadFailure(error); favoritesState = .failed
        }
    }

    public func loadSavedLinks() async {
        requestedSavedLinks = true
        guard canLoad else { return }
        savedEpoch &+= 1
        let token = epoch, resource = savedEpoch, removals = removalEpoch
        savedLinksState = .loading
        do {
            let result = try await actions.loadSavedLinks()
            guard current(token), resource == savedEpoch else { return }
            authorizeRead()
            savedContentEpoch &+= 1
            savedLinks = mergeReauthorized(result.links, into: savedLinks, removals: removals, id: { $0.encounterID })
            savedLinksTruncated = result.truncated; savedLinksState = .loaded
        } catch {
            guard current(token), resource == savedEpoch else { return }
            handleReadFailure(error); savedLinksState = .failed
        }
    }

    public func setFavorite(_ id: String, favorite: Bool) async {
        await perform(.favorite(id, favorite))
    }

    public func setSaved(_ encounterID: String, linkID: String, saved: Bool) async {
        await perform(.save(encounterID, linkID, saved))
    }

    public func requestDeletion(_ id: String) {
        guard actions.deleteEncounter != nil, canRead, !isWriting, find(id) != nil else { return }
        deletion = .confirming(id)
    }

    public func cancelDeletion() {
        guard !isWriting else { return }
        if case .deleting = deletion { return }
        deletion = .none
    }

    /// Mark approval before SwiftUI dismisses its confirmation surface.
    public func approveDeletion() {
        guard canRead, !isWriting, case let .confirming(id) = deletion else { return }
        deletion = .deleting(id)
    }

    @discardableResult
    public func confirmDeletion() async -> Bool {
        switch deletion {
        case let .confirming(id):
            approveDeletion()
            return await delete(id)
        case let .deleting(id): return await delete(id)
        default: return false
        }
    }

    @discardableResult
    public func retryOperation() async -> Bool {
        guard let operation = failedOperation else { return false }
        if case let .delete(id) = operation { return await delete(id) }
        await perform(operation)
        return failedOperation == nil && canRead
    }

    private func current(_ token: UInt) -> Bool { token == epoch && canLoad }
    private func authorizeRead() { isAuthorized = true; canRetryAuthorization = false }

    /// A list requested before a card's fresh authorization cannot replace that card,
    /// including by omission. Later list requests remain authoritative for their IDs.
    private func mergeReauthorized<Value>(_ incoming: [Value], into existing: [Value], removals: UInt,
                                         id: (Value) -> String) -> [Value] {
        let preserved = existing.enumerated().filter {
            (removedAt[id($0.element)] ?? 0) > removals && concealedCards[id($0.element)] == nil
        }
        var result = Array(incoming.filter {
            (removedAt[id($0)] ?? 0) <= removals && concealedCards[id($0)] == nil
        }.prefix(max(0, 200 - preserved.count)))
        for entry in preserved {
            result.insert(entry.element, at: min(entry.offset, result.count))
        }
        return result
    }

    private func currentWrite(_ token: UInt, id: String, removals: UInt) -> Bool {
        guard current(token) else { return false }
        guard (removedAt[id] ?? 0) <= removals else {
            isWriting = false; failedOperation = nil
            return false
        }
        return true
    }

    private func find(_ id: String) -> EncounterCard? {
        if card?.card.id == id { return card?.card }
        return feed.first { $0.id == id }?.card ?? favorites.first { $0.id == id }?.card
    }

    private func perform(_ operation: DiscoverOperation) async {
        guard canRead, !isWriting else { return }
        let id: String
        switch operation {
        case let .favorite(value, _), let .save(value, _, _): id = value
        case .delete: return
        }
        guard find(id) != nil || savedLinks.contains(where: { $0.encounterID == id }) else { return }
        let beforeFeed = feed, beforeFavorites = favorites, beforeLinks = savedLinks, beforeCard = card
        let token = epoch, removals = removalEpoch
        let feedToken = feedContentEpoch, favoritesToken = favoritesContentEpoch
        let savedToken = savedContentEpoch, detailToken = detailContentEpoch
        isWriting = true; failedOperation = nil
        update(operation)
        do {
            let removesRetention: Bool
            switch operation {
            case let .favorite(id, value):
                let result = try await actions.setFavorite(id, value)
                guard currentWrite(token, id: id, removals: removals) else { return }
                guard result.encounterID == id else { throw DiscoverActionError.unavailable }
                update(.favorite(result.encounterID, result.favorite))
                removesRetention = !result.favorite
            case let .save(id, linkID, value):
                let result: EncounterSavedResult
                if value { result = try await actions.saveLink(id, linkID) }
                else { result = try await actions.unsaveLink(id, linkID) }
                guard currentWrite(token, id: id, removals: removals) else { return }
                guard result.encounterID == id, result.linkID == linkID else { throw DiscoverActionError.unavailable }
                update(.save(result.encounterID, result.linkID, result.saved))
                removesRetention = !result.saved
            case .delete: return
            }
            if removesRetention {
                concealedCards[id] = ConcealedCard(feedIndex: beforeFeed.firstIndex { $0.id == id },
                    favoritesIndex: beforeFavorites.firstIndex { $0.id == id },
                    savedIndex: beforeLinks.firstIndex { $0.encounterID == id })
                fenceCardCopies(id)
                await reloadConcealedCard(id)
                guard current(token) else { return }
            }
            isWriting = false
        } catch {
            guard currentWrite(token, id: id, removals: removals) else { return }
            if isAuthorizationFailure(error) {
                loseAuthorization()
            } else if isNotFound(error) {
                remove(id); isWriting = false
            } else {
                // A failed write cannot restore snapshots over newer reads.
                if feedContentEpoch == feedToken { feed = beforeFeed }
                if favoritesContentEpoch == favoritesToken { favorites = beforeFavorites }
                if savedContentEpoch == savedToken { savedLinks = beforeLinks }
                if detailContentEpoch == detailToken { card = beforeCard }
                failedOperation = operation; isWriting = false
            }
        }
    }

    /// Retry the read, never the already successful retention-removal write.
    public func retryCardReloads() async {
        for id in failedCardReloadIDs.sorted() { await reloadConcealedCard(id) }
    }

    private func fenceCardCopies(_ id: String) {
        removalEpoch &+= 1; removedAt[id] = removalEpoch
        feedContentEpoch &+= 1; favoritesContentEpoch &+= 1; savedContentEpoch &+= 1
        feed.removeAll { $0.id == id }; favorites.removeAll { $0.id == id }
        savedLinks.removeAll { $0.encounterID == id }
        if card?.card.id == id { card = nil; detailContentEpoch &+= 1 }
        if requestedCardID == id { detailEpoch &+= 1; detailState = .loading }
    }

    private func reloadConcealedCard(_ id: String) async {
        guard canLoad, var context = concealedCards[id] else { return }
        context.request = UUID(); concealedCards[id] = context
        let token = epoch
        failedCardReloadIDs.remove(id)
        if requestedCardID == id { detailState = .loading }
        do {
            let result = try await actions.loadCard(id)
            guard current(token), concealedCards[id]?.request == context.request else { return }
            authorizeRead()
            guard let result, result.card.id == id else { remove(id); return }
            // Fence list reads started during concealment too; none may restore old fields.
            fenceCardCopies(id)
            concealedCards[id] = nil
            let entry = EncounterFeedCard(card: result.card, favorite: result.favorite)
            if let index = context.feedIndex, feed.count < 200 {
                feed.insert(entry, at: min(index, feed.count))
            }
            if result.favorite, let index = context.favoritesIndex, favorites.count < 200 {
                favorites.insert(entry, at: min(index, favorites.count))
            }
            if let index = context.savedIndex {
                let links = result.card.links.filter { result.savedLinkIDs.contains($0.id) }.map {
                    EncounterSavedLink(encounterID: id, day: result.card.day, kind: result.card.kind, link: $0)
                }
                savedLinks.insert(contentsOf: links.prefix(max(0, 200 - savedLinks.count)),
                                  at: min(index, savedLinks.count))
            }
            if requestedCardID == id {
                detailContentEpoch &+= 1; card = result; detailState = .loaded
            }
        } catch {
            guard current(token), concealedCards[id]?.request == context.request else { return }
            if isNotFound(error) { remove(id) }
            else if isAuthorizationFailure(error) { loseAuthorization() }
            else {
                failedCardReloadIDs.insert(id)
                if requestedCardID == id { detailState = .failed }
            }
        }
    }

    /// Flag-only results change only the named encounter or reference, never visible metadata.
    private func update(_ operation: DiscoverOperation) {
        switch operation {
        case let .favorite(id, value):
            let source = feed.first { $0.id == id } ?? favorites.first { $0.id == id }
                ?? find(id).map { EncounterFeedCard(card: $0, favorite: value) }
            if card?.card.id == id { card?.favorite = value }
            if let index = feed.firstIndex(where: { $0.id == id }) { feed[index].favorite = value }
            if let index = favorites.firstIndex(where: { $0.id == id }) {
                if value { favorites[index].favorite = value } else { favorites.remove(at: index) }
            } else if favoritesState == .loaded, favorites.count < 200, value, var source {
                source.favorite = value; favorites.append(source)
            }
        case let .save(id, linkID, value):
            if card?.card.id == id, card?.card.links.contains(where: { $0.id == linkID }) == true {
                if value { card?.savedLinkIDs.insert(linkID) }
                else { card?.savedLinkIDs.remove(linkID) }
            }
            let key = EncounterSavedLink.ID(encounterID: id, linkID: linkID)
            if !value { savedLinks.removeAll { $0.id == key } }
            else if savedLinksState == .loaded, savedLinks.count < 200, !savedLinks.contains(where: { $0.id == key }),
                    let owner = find(id), let link = owner.links.first(where: { $0.id == linkID }) {
                savedLinks.append(EncounterSavedLink(encounterID: id, day: owner.day, kind: owner.kind, link: link))
            }
        case .delete: break
        }
    }

    private func remove(_ id: String) {
        // Only the removed encounter is fenced; unrelated loads still finish normally.
        feedContentEpoch &+= 1; favoritesContentEpoch &+= 1; savedContentEpoch &+= 1; detailContentEpoch &+= 1
        removalEpoch &+= 1
        removedAt[id] = removalEpoch
        concealedCards[id] = nil; failedCardReloadIDs.remove(id)
        feed.removeAll { $0.id == id }; favorites.removeAll { $0.id == id }
        savedLinks.removeAll { $0.encounterID == id }
        if requestedCardID == id {
            detailEpoch &+= 1
            card = nil; detailState = .missing; requestedCardID = nil
        } else if card?.card.id == id { card = nil }
        deletion = .none
    }

    private func delete(_ id: String) async -> Bool {
        guard let deleteEncounter = actions.deleteEncounter, canRead, !isWriting, find(id) != nil else { return false }
        let token = epoch, removals = removalEpoch
        isWriting = true; failedOperation = nil; deletion = .deleting(id)
        do {
            try await deleteEncounter(id)
            guard currentWrite(token, id: id, removals: removals) else { return false }
            remove(id); isWriting = false
            return true
        } catch {
            guard currentWrite(token, id: id, removals: removals) else { return false }
            if isAuthorizationFailure(error) { loseAuthorization() }
            else if isNotFound(error) { remove(id); isWriting = false; return true }
            else { deletion = .failed(id); failedOperation = .delete(id); isWriting = false }
            return false
        }
    }

    private func handleReadFailure(_ error: Error) {
        if isAuthorizationFailure(error) { loseAuthorization() }
    }

    private func loseAuthorization() {
        clearProtectedContent()
        isAuthorized = false
        // A Retry may recheck authorization; explicit sign-out never permits this.
        canRetryAuthorization = true
    }

    private func isAuthorizationFailure(_ error: Error) -> Bool {
        if let error = error as? DiscoverActionError { return error == .authorizationFailed }
        if let error = error as? ProfileActionError {
            return [.notAuthenticated, .accountNotReady, .declarationRequired].contains(error.code)
        }
        return false
    }

    private func isNotFound(_ error: Error) -> Bool {
        (error as? DiscoverActionError) == .notFound || (error as? ProfileActionError)?.code == .notFound
    }
}
