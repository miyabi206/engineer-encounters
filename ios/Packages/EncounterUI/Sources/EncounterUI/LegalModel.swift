import Combine
import Foundation

public enum LegalEntry: String, CaseIterable, Sendable { case terms, privacy, support }

public struct LegalData: Equatable, Sendable {
    public var terms: URL?
    public var privacy: URL?
    public var support: URL?
    public var moderationContact: String?
    public var version: String?
    public init(terms: URL? = nil, privacy: URL? = nil, support: URL? = nil,
                moderationContact: String? = nil, version: String? = nil) {
        self.terms = terms; self.privacy = privacy; self.support = support
        self.moderationContact = moderationContact; self.version = version
    }
    public func url(for entry: LegalEntry) -> URL? {
        switch entry { case .terms: terms; case .privacy: privacy; case .support: support }
    }
    public var entries: [LegalEntry] { LegalEntry.allCases.filter { url(for: $0) != nil } }
    public var contact: String? {
        moderationContact.flatMap { ProfileValidation.trimmed($0).isEmpty ? nil : $0 }
    }
}

public enum LegalOperation: Equatable, Sendable { case open(URL), contact(String), copy(String) }

@MainActor
public struct LegalActions {
    public var open: @MainActor (URL) async throws -> Void
    public var contact: @MainActor (String) async throws -> Void
    public var copy: @MainActor (String) async throws -> Void
    public init(open: @escaping @MainActor (URL) async throws -> Void,
                contact: @escaping @MainActor (String) async throws -> Void,
                copy: @escaping @MainActor (String) async throws -> Void) {
        self.open = open; self.contact = contact; self.copy = copy
    }
}

@MainActor
public struct LegalNavigationActions {
    public var back: @MainActor () -> Void
    public init(back: @escaping @MainActor () -> Void) { self.back = back }
}

@MainActor
public final class LegalModel: ObservableObject {
    public let data: LegalData
    public let navigation: LegalNavigationActions
    @Published public private(set) var isBusy = false
    @Published public private(set) var failedOperation: LegalOperation?
    private let actions: LegalActions
    public init(data: LegalData, actions: LegalActions, navigation: LegalNavigationActions) {
        self.data = data; self.actions = actions; self.navigation = navigation
    }
    public func open(_ entry: LegalEntry) async {
        if let url = data.url(for: entry) { await perform(.open(url)) }
    }
    public func contact() async { if let address = data.contact { await perform(.contact(address)) } }
    public func copy() async { if let address = data.contact { await perform(.copy(address)) } }
    public func retry() async { if let operation = failedOperation { await perform(operation) } }
    public func back() { if !isBusy { navigation.back() } }
    private func perform(_ operation: LegalOperation) async {
        guard !isBusy else { return }
        isBusy = true; failedOperation = nil
        defer { isBusy = false }
        do {
            switch operation {
            case .open(let url): try await actions.open(url)
            case .contact(let address): try await actions.contact(address)
            case .copy(let address): try await actions.copy(address)
            }
        } catch { failedOperation = operation }
    }
}
