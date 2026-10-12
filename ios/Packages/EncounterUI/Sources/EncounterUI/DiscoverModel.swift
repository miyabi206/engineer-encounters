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

/// Caller-owned, memory-only state shared by Discover routes. Every refresh drops protected
/// content before awaiting authorization. Epochs fence late results after sign-out/access loss.
@MainActor
public final class DiscoverModel: ObservableObject {
    @Published public private(set) var feed: [EncounterCard] = []
    @Published public private(set) var favorites: [EncounterCard] = []
    @Published public private(set) var savedLinks: [EncounterSavedLink] = []
    @Published public private(set) var card: EncounterCard?
    @Published public private(set) var feedState: DiscoverLoadState = .idle
    @Published public private(set) var detailState: DiscoverLoadState = .idle
    @Published public private(set) var favoritesState: DiscoverLoadState = .idle
    @Published public private(set) var discoveryOn: Bool
    @Published public private(set) var isAuthorized: Bool
    @Published public private(set) var isWriting = false
    @Published public private(set) var deletion: DiscoverDeletionState = .none
    @Published public private(set) var failedOperation: DiscoverOperation?
    public let actions: DiscoverActions
    private var epoch: UInt = 0

    public init(actions: DiscoverActions, discoveryOn: Bool, isAuthorized: Bool = true) {
        self.actions = actions; self.discoveryOn = discoveryOn; self.isAuthorized = isAuthorized
    }

    public var canRead: Bool { discoveryOn && isAuthorized }
    public var dayGroups: [EncounterDayGroup] { EncounterDayGroup.grouped(feed) }
    public var favoriteDayGroups: [EncounterDayGroup] { EncounterDayGroup.grouped(favorites) }

    /// Call for sign-out, failed authorization, account changes and visibility changes.
    /// Calling with the same values still invalidates every in-flight response and card.
    public func receiveAccess(discoveryOn: Bool, isAuthorized: Bool) {
        clearProtectedContent()
        self.discoveryOn = discoveryOn; self.isAuthorized = isAuthorized
    }

    public func clearProtectedContent() {
        epoch &+= 1
        feed = []; favorites = []; savedLinks = []; card = nil
        feedState = .idle; detailState = .idle; favoritesState = .idle
        isWriting = false; deletion = .none; failedOperation = nil
    }

    public func loadFeed() async {
        guard canRead, feedState != .loading else { return }
        clearProtectedContent()
        let token = epoch
        feedState = .loading
        do {
            let result = try await actions.loadFeed()
            guard current(token) else { return }
            feed = result; feedState = .loaded
        } catch {
            guard current(token) else { return }
            handleReadFailure(error)
            feedState = .failed
        }
    }

    public func loadCard(_ id: String) async {
        guard canRead, detailState != .loading else { return }
        clearProtectedContent()
        let token = epoch
        detailState = .loading
        do {
            let result = try await actions.loadCard(id)
            guard current(token) else { return }
            guard let result, result.id == id else {
                remove(id); detailState = .missing; return
            }
            card = result; detailState = .loaded
        } catch {
            guard current(token) else { return }
            if isNotFound(error) { remove(id); detailState = .missing }
            else { handleReadFailure(error); detailState = .failed }
        }
    }

    public func loadFavorites() async {
        guard canRead, favoritesState != .loading else { return }
        clearProtectedContent()
        let token = epoch
        favoritesState = .loading
        do {
            let people = try await actions.loadFavorites()
            guard current(token) else { return }
            let links = try await actions.loadSavedLinks()
            guard current(token) else { return }
            favorites = people.filter(\.favorite)
            savedLinks = links.filter { $0.link.saved }
            favoritesState = .loaded
        } catch {
            guard current(token) else { return }
            handleReadFailure(error)
            favoritesState = .failed
        }
    }

    public func setFavorite(_ id: String, favorite: Bool) async {
        await perform(.favorite(id, favorite))
    }

    public func setSaved(_ encounterID: String, linkID: String, saved: Bool) async {
        await perform(.save(encounterID, linkID, saved))
    }

    public func requestDeletion(_ id: String) {
        guard canRead, !isWriting, find(id) != nil else { return }
        deletion = .confirming(id)
    }

    public func cancelDeletion() {
        guard !isWriting else { return }
        if case .deleting = deletion { return }
        deletion = .none
    }

    /// Mark approval synchronously before SwiftUI dismisses its confirmation surface.
    /// Dismissal must not cancel a confirmed write before its async task starts.
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

    private func current(_ token: UInt) -> Bool { token == epoch && canRead }

    private func find(_ id: String) -> EncounterCard? {
        if card?.id == id { return card }
        return feed.first { $0.id == id } ?? favorites.first { $0.id == id }
    }

    private func perform(_ operation: DiscoverOperation) async {
        guard canRead, !isWriting else { return }
        let id: String
        switch operation {
        case let .favorite(value, _), let .save(value, _, _): id = value
        case .delete: return
        }
        // Saved-link-only S10 context need not include its owner's profile.
        guard find(id) != nil || savedLinks.contains(where: { $0.encounterID == id }) else { return }
        let beforeFeed = feed, beforeFavorites = favorites, beforeLinks = savedLinks, beforeCard = card
        let token = epoch
        isWriting = true; failedOperation = nil
        optimistic(operation)
        do {
            let result: EncounterCard?
            switch operation {
            case let .favorite(id, value): result = try await actions.setFavorite(id, value)
            case let .save(id, linkID, value):
                if value { result = try await actions.saveLink(id, linkID) }
                else { result = try await actions.unsaveLink(id, linkID) }
            case .delete: return
            }
            guard current(token) else { return }
            if let result, result.id == id { apply(result) }
            else { remove(id) }
            isWriting = false
        } catch {
            guard current(token) else { return }
            if isAuthorizationFailure(error) {
                receiveAccess(discoveryOn: discoveryOn, isAuthorized: false)
            } else if isNotFound(error) {
                remove(id); isWriting = false
            } else {
                feed = beforeFeed; favorites = beforeFavorites; savedLinks = beforeLinks; card = beforeCard
                failedOperation = operation; isWriting = false
            }
        }
    }

    private func optimistic(_ operation: DiscoverOperation) {
        switch operation {
        case let .favorite(id, value):
            guard var changed = find(id) else { return }
            changed.favorite = value
            apply(changed)
        case let .save(id, linkID, value):
            if var changed = find(id), let index = changed.links.firstIndex(where: { $0.id == linkID }) {
                changed.links[index].saved = value; apply(changed)
            } else {
                savedLinks.removeAll { $0.encounterID == id && $0.link.id == linkID && !value }
            }
        case .delete: break
        }
    }

    /// Replace whole authorized cards, also purging links that are now private.
    private func apply(_ value: EncounterCard) {
        if let index = feed.firstIndex(where: { $0.id == value.id }) { feed[index] = value }
        if card?.id == value.id { card = value }
        if let index = favorites.firstIndex(where: { $0.id == value.id }) {
            if value.favorite { favorites[index] = value } else { favorites.remove(at: index) }
        } else if value.favorite { favorites.append(value) }
        let fresh = value.links.filter(\.saved).map { EncounterSavedLink(encounterID: value.id, link: $0) }
        // Keep the caller's order for existing saved links; append only new references.
        savedLinks = savedLinks.compactMap { old in
            old.encounterID == value.id ? fresh.first { $0.id == old.id } : old
        }
        for item in fresh where !savedLinks.contains(where: { $0.id == item.id }) { savedLinks.append(item) }
    }

    private func remove(_ id: String) {
        feed.removeAll { $0.id == id }; favorites.removeAll { $0.id == id }
        savedLinks.removeAll { $0.encounterID == id }
        if card?.id == id { card = nil; detailState = .missing }
        deletion = .none
    }

    private func delete(_ id: String) async -> Bool {
        guard canRead, !isWriting, find(id) != nil else { return false }
        let token = epoch
        isWriting = true; failedOperation = nil; deletion = .deleting(id)
        do {
            try await actions.deleteEncounter(id)
            guard current(token) else { return false }
            remove(id); isWriting = false
            return true
        } catch {
            guard current(token) else { return false }
            if isAuthorizationFailure(error) {
                receiveAccess(discoveryOn: discoveryOn, isAuthorized: false)
            } else if isNotFound(error) {
                remove(id); isWriting = false; return true
            } else {
                deletion = .failed(id); failedOperation = .delete(id); isWriting = false
            }
            return false
        }
    }

    private func handleReadFailure(_ error: Error) {
        // A failed fresh response may never leave another screen's protected cache behind.
        clearProtectedContent()
        if isAuthorizationFailure(error) { isAuthorized = false }
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
