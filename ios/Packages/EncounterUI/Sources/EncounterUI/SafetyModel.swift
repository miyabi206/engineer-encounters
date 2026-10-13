import Combine
import Foundation

public struct SafetyBlock: Identifiable, Equatable, Sendable {
    public let id: String
    public let placedDay: EncounterDay
    public init(id: String, placedDay: EncounterDay) { self.id = id; self.placedDay = placedDay }
}

public struct SafetyBlockList: Equatable, Sendable {
    public var blocks: [SafetyBlock]
    public var truncated: Bool
    public init(blocks: [SafetyBlock], truncated: Bool = false) { self.blocks = blocks; self.truncated = truncated }
}

@MainActor
public struct SafetyBlockedActions {
    public var load: @MainActor () async throws -> SafetyBlockList
    public var unblock: @MainActor (String) async throws -> Void
    public init(load: @escaping @MainActor () async throws -> SafetyBlockList,
                unblock: @escaping @MainActor (String) async throws -> Void) {
        self.load = load; self.unblock = unblock
    }
}

@MainActor
public struct SafetyBlockedNavigationActions {
    public var back: @MainActor () -> Void
    public init(back: @escaping @MainActor () -> Void) { self.back = back }
}

@MainActor
public final class SafetyBlockedModel: ObservableObject {
    @Published public private(set) var list: SafetyBlockList?
    @Published public private(set) var isBusy = false
    @Published public private(set) var error: ProfileActionError?
    @Published public private(set) var failedBlockID: String?
    public let navigation: SafetyBlockedNavigationActions
    private let actions: SafetyBlockedActions
    public init(list: SafetyBlockList? = nil, actions: SafetyBlockedActions, navigation: SafetyBlockedNavigationActions) {
        self.list = list; self.actions = actions; self.navigation = navigation
    }
    public func load() async {
        guard !isBusy else { return }
        isBusy = true; error = nil; failedBlockID = nil; list = nil
        defer { isBusy = false }
        do { list = try await actions.load() }
        catch { self.error = errorValue(error) }
    }
    /// Invoke only after the caller/view confirms this opaque block reference.
    public func unblock(_ id: String) async {
        guard !isBusy, list?.blocks.contains(where: { $0.id == id }) == true else { return }
        isBusy = true; error = nil; failedBlockID = id
        defer { isBusy = false }
        do {
            try await actions.unblock(id)
            list?.blocks.removeAll { $0.id == id }; failedBlockID = nil
        } catch {
            let failure = errorValue(error)
            if failure.code == .notFound {
                list?.blocks.removeAll { $0.id == id }; failedBlockID = nil
            } else { self.error = failure }
        }
    }
    public func retry() async {
        if let id = failedBlockID { await unblock(id) } else { await load() }
    }
    public func back() { if !isBusy { navigation.back() } }
    private func errorValue(_ error: any Error) -> ProfileActionError {
        error as? ProfileActionError ?? .init(code: .unavailable)
    }
}

public enum SafetyReportReason: String, CaseIterable, Sendable {
    case spam, harassment, impersonation, other
}

/// Only an authorized S07 link's opaque ID is retained, never its protected card.
public struct SafetyReportLinkContext: Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct SafetyReportRequest: Equatable, Sendable {
    public let encounterID: String
    public let reason: SafetyReportReason
    public let linkID: String?
    public init?(encounterID: String, reason: SafetyReportReason, link: SafetyReportLinkContext?) {
        guard reason != .impersonation || link != nil else { return nil }
        self.encounterID = encounterID; self.reason = reason
        linkID = reason == .impersonation ? link?.id : nil
    }
}

public enum SafetySubmission: Equatable, Sendable {
    case report(SafetyReportRequest), block(String)
}

/// Pending concealment survives failures. Only explicit cancellation clears it;
/// reopening still requires the caller's fresh authorization response.
public enum SafetyReportState: Equatable, Sendable {
    case idle, submitting(SafetySubmission), failed(SafetySubmission), accepted(SafetySubmission)
    public var isBusy: Bool { if case .submitting = self { return true }; return false }
    public var isHidden: Bool { self != .idle }
    public var isPending: Bool {
        switch self { case .submitting, .failed: true; case .idle, .accepted: false }
    }
    public var retry: SafetySubmission? { if case .failed(let request) = self { return request }; return nil }
    public mutating func begin(_ submission: SafetySubmission) -> Bool {
        if case .accepted(.report(let report)) = self {
            guard submission == .block(report.encounterID) else { return false }
        } else {
            guard self == .idle || retry != nil else { return false }
        }
        self = .submitting(submission); return true
    }
    public mutating func accept() {
        if case .submitting(let request) = self { self = .accepted(request) }
    }
    public mutating func fail() {
        if case .submitting(let request) = self { self = .failed(request) }
    }
    public mutating func cancel() -> Bool {
        guard !isBusy else { return false }
        if case .accepted = self { return false }
        self = .idle; return true
    }
}

@MainActor
public struct SafetyReportActions {
    public var report: @MainActor (SafetyReportRequest) async throws -> Void
    public var block: @MainActor (String) async throws -> Void
    public var conceal: @MainActor () -> Void
    public var clearPendingHide: @MainActor () -> Void
    public var authorizeReopening: @MainActor () async throws -> Bool
    public init(report: @escaping @MainActor (SafetyReportRequest) async throws -> Void,
                block: @escaping @MainActor (String) async throws -> Void,
                conceal: @escaping @MainActor () -> Void,
                clearPendingHide: @escaping @MainActor () -> Void,
                authorizeReopening: @escaping @MainActor () async throws -> Bool) {
        self.report = report; self.block = block; self.conceal = conceal
        self.clearPendingHide = clearPendingHide; self.authorizeReopening = authorizeReopening
    }
}

@MainActor
public struct SafetyReportNavigationActions {
    /// The caller chooses S10 or S06 from the original encounter route.
    public var completed: @MainActor () -> Void
    public var reopenEncounter: @MainActor () -> Void
    public init(completed: @escaping @MainActor () -> Void, reopenEncounter: @escaping @MainActor () -> Void) {
        self.completed = completed; self.reopenEncounter = reopenEncounter
    }
}

@MainActor
public final class SafetyReportModel: ObservableObject {
    @Published public var reason: SafetyReportReason?
    @Published public private(set) var state = SafetyReportState.idle
    /// Retain the acceptance receipt even while a follow-up block is pending or fails.
    @Published public private(set) var acceptedReport: SafetyReportRequest?
    @Published public private(set) var error: ProfileActionError?
    @Published public private(set) var isReopening = false
    public let encounterID: String
    public let link: SafetyReportLinkContext?
    private let actions: SafetyReportActions
    private let navigation: SafetyReportNavigationActions
    public init(encounterID: String, link: SafetyReportLinkContext? = nil,
                actions: SafetyReportActions, navigation: SafetyReportNavigationActions) {
        self.encounterID = encounterID; self.link = link; self.actions = actions; self.navigation = navigation
        if link != nil { reason = .impersonation }
    }
    public var isBusy: Bool { state.isBusy || isReopening }
    public var isPendingHide: Bool { acceptedReport == nil && state.isPending }
    public var isBlockUnavailable: Bool {
        if case .failed(.block) = state { return error?.code == .notFound }
        return false
    }
    public var canBlock: Bool {
        guard !isBusy else { return false }
        if case .accepted(.report) = state { return true }
        return state == .idle
    }
    public var canSubmit: Bool {
        state == .idle && !isReopening && reason.map {
            SafetyReportRequest(encounterID: encounterID, reason: $0, link: link) != nil
        } == true
    }
    public func submit() async {
        guard canSubmit, let reason,
              let request = SafetyReportRequest(encounterID: encounterID, reason: reason, link: link) else { return }
        await perform(.report(request))
    }
    public func block() async { if canBlock { await perform(.block(encounterID)) } }
    public func retry() async {
        if !isBlockUnavailable, let submission = state.retry { await perform(submission) }
    }
    private func perform(_ submission: SafetySubmission) async {
        guard !isReopening, state.begin(submission) else { return }
        error = nil
        actions.conceal()
        do {
            switch submission {
            case .report(let request): try await actions.report(request)
            case .block(let id): try await actions.block(id)
            }
            state.accept()
            switch submission {
            case .report(let request): acceptedReport = request
            case .block: navigation.completed()
            }
        } catch {
            state.fail(); self.error = error as? ProfileActionError ?? .init(code: .unavailable)
        }
    }
    public func done() {
        guard !isBusy, acceptedReport != nil else { return }
        navigation.completed()
    }
    public func cancel() async {
        guard !isBusy else { return }
        if acceptedReport != nil { done(); return }
        if state == .idle { navigation.reopenEncounter(); return }
        guard state.cancel() else { navigation.completed(); return }
        actions.clearPendingHide(); error = nil; isReopening = true
        defer { isReopening = false }
        do {
            if try await actions.authorizeReopening() { navigation.reopenEncounter() }
            else { navigation.completed() }
        } catch { navigation.completed() }
    }
}
