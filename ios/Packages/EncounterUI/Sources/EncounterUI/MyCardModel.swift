import Combine
import Foundation

public enum MyCardAudience: String, CaseIterable, Sendable {
    case everyoneEligible, compatibleOnly

    public func includes(_ visibility: VisibilityLevel?) -> Bool {
        visibility == .everyoneEligible || (self == .compatibleOnly && visibility == .compatibleOnly)
    }
}

public struct MyCardData: Equatable, Sendable {
    public var profile: OwnProfileState
    public var links: [OwnLinkState]
    public var interests: [InterestOption]

    public init(profile: OwnProfileState, links: [OwnLinkState], interests: [InterestOption] = []) {
        self.profile = profile; self.links = links; self.interests = interests
    }
}

/// An audience simulation from owner data, never an authorization decision for a real viewer.
public struct MyCardPreview: Equatable, Sendable {
    public let displayName: String?
    public let introduction: String?
    public let interestIDs: Set<String>
    public let purposes: Set<ProfilePurpose>
    public let contactDetail: String?
    public let links: [OwnLinkState]
    public var initial: String? { displayName?.first.map { String($0).uppercased() } }
    public var isEmpty: Bool {
        displayName == nil && introduction == nil && interestIDs.isEmpty && purposes.isEmpty &&
        contactDetail == nil && links.isEmpty
    }

    public init(data: MyCardData, audience: MyCardAudience) {
        let profile = data.profile
        func includes(_ field: ProfileField) -> Bool {
            audience.includes(SettingsValidation.visibility(field, in: profile.fieldVisibility))
        }
        func text(_ value: String, field: ProfileField) -> String? {
            includes(field) && !ProfileValidation.trimmed(value).isEmpty ? value : nil
        }
        displayName = text(profile.displayName, field: .displayName)
        introduction = text(profile.introduction, field: .introduction)
        interestIDs = includes(.interests) ? profile.interestIDs : []
        purposes = includes(.purposes) ? profile.purposes : []
        contactDetail = text(profile.contactDetail, field: .contactDetail)
        links = data.links.filter { audience.includes($0.visibility) }.sorted {
            $0.displayOrder == $1.displayOrder ? $0.id < $1.id : $0.displayOrder < $1.displayOrder
        }
    }
}

@MainActor
public struct MyCardActions {
    public var load: @MainActor () async throws -> MyCardData
    public var openOriginal: @MainActor (URL) async throws -> Void
    public init(load: @escaping @MainActor () async throws -> MyCardData,
                openOriginal: @escaping @MainActor (URL) async throws -> Void) {
        self.load = load; self.openOriginal = openOriginal
    }
}

@MainActor
public struct MyCardNavigationActions {
    public var editProfile: @MainActor () -> Void
    public var links: @MainActor () -> Void
    public var visibility: @MainActor () -> Void
    public init(editProfile: @escaping @MainActor () -> Void, links: @escaping @MainActor () -> Void,
                visibility: @escaping @MainActor () -> Void) {
        self.editProfile = editProfile; self.links = links; self.visibility = visibility
    }
}

@MainActor
public final class MyCardModel: ObservableObject {
    @Published public private(set) var data: MyCardData?
    @Published public var audience = MyCardAudience.everyoneEligible
    @Published public private(set) var isLoading = false
    @Published public private(set) var failed = false
    @Published public private(set) var failedURL: URL?
    public let navigation: MyCardNavigationActions
    private let actions: MyCardActions

    public init(data: MyCardData? = nil, actions: MyCardActions, navigation: MyCardNavigationActions) {
        self.data = data; self.actions = actions; self.navigation = navigation
    }
    public var preview: MyCardPreview? { data.map { MyCardPreview(data: $0, audience: audience) } }
    public var needsBasics: Bool {
        guard let profile = data?.profile else { return false }
        return !ProfileValidation.invalidBasics(displayName: profile.displayName,
                                               introduction: profile.introduction).isEmpty ||
            profile.interestIDs.isEmpty || profile.purposes.isEmpty
    }
    public func load() async {
        guard !isLoading else { return }
        isLoading = true; failed = false; data = nil; failedURL = nil
        defer { isLoading = false }
        do { data = try await actions.load() }
        catch { failed = true }
    }
    public func open(_ url: URL) async {
        failedURL = nil
        do { try await actions.openOriginal(url) }
        catch { failedURL = url }
    }
}
