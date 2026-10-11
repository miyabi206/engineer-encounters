import Foundation

public enum ProfilePurpose: String, CaseIterable, Hashable, Sendable {
    case discovery, collaboration
}

public enum VisibilityLevel: String, CaseIterable, Sendable {
    case everyoneEligible = "everyone_eligible"
    case compatibleOnly = "compatible_only"
    case `private`
}

public enum ProfileField: String, CaseIterable, Hashable, Sendable {
    case displayName = "display_name"
    case introduction
    case interests
    case purposes
    case contactDetail = "contact_detail"
}

public struct InterestOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let labelJapanese: String
    public let labelEnglish: String

    public init(id: String, labelJapanese: String, labelEnglish: String) {
        self.id = id
        self.labelJapanese = labelJapanese
        self.labelEnglish = labelEnglish
    }

    public func label(language: String) -> String {
        language.hasPrefix("ja") ? labelJapanese : labelEnglish
    }
}

public enum DiscoveryPrerequisite: String, CaseIterable, Sendable {
    case displayName = "display_name"
    case introduction, interest, link
}

public struct ProfilePrerequisites: Equatable, Sendable {
    public var displayName: Bool
    public var introduction: Bool
    public var interest: Bool
    public var link: Bool

    public init(displayName: Bool = false, introduction: Bool = false,
                interest: Bool = false, link: Bool = false) {
        self.displayName = displayName
        self.introduction = introduction
        self.interest = interest
        self.link = link
    }

    public func isMet(_ prerequisite: DiscoveryPrerequisite) -> Bool {
        switch prerequisite {
        case .displayName: displayName
        case .introduction: introduction
        case .interest: interest
        case .link: link
        }
    }

    public var missing: [DiscoveryPrerequisite] {
        DiscoveryPrerequisite.allCases.filter { !isMet($0) }
    }

    public var canEnableDiscovery: Bool { missing.isEmpty }
}

public struct OwnProfileState: Equatable, Sendable {
    public var displayName: String
    public var introduction: String
    public var contactDetail: String
    public var interestIDs: Set<String>
    public var purposes: Set<ProfilePurpose>
    public var minimumSharedInterests: Int
    public var fieldVisibility: [ProfileField: VisibilityLevel]
    public var discoveryOn: Bool
    public var linkCount: Int
    public var prerequisites: ProfilePrerequisites
    public var declarationsRecorded: Bool
    public var timeZone: String
    public var moderationState: String

    public init(displayName: String = "", introduction: String = "", contactDetail: String = "",
                interestIDs: Set<String> = [], purposes: Set<ProfilePurpose> = [],
                minimumSharedInterests: Int = 1,
                fieldVisibility: [ProfileField: VisibilityLevel] = [
                    .displayName: .everyoneEligible, .introduction: .everyoneEligible,
                    .interests: .everyoneEligible, .purposes: .everyoneEligible, .contactDetail: .private
                ], discoveryOn: Bool = false, linkCount: Int = 0,
                prerequisites: ProfilePrerequisites = .init(), declarationsRecorded: Bool = false,
                timeZone: String = "", moderationState: String = "active") {
        self.displayName = displayName
        self.introduction = introduction
        self.contactDetail = contactDetail
        self.interestIDs = interestIDs
        self.purposes = purposes
        self.minimumSharedInterests = minimumSharedInterests
        self.fieldVisibility = fieldVisibility
        self.discoveryOn = discoveryOn
        self.linkCount = linkCount
        self.prerequisites = prerequisites
        self.declarationsRecorded = declarationsRecorded
        self.timeZone = timeZone
        self.moderationState = moderationState
    }
}

/// Field names are preserved verbatim so callers can map the contract's error details.
/// Views render only known labels and never display arbitrary server error text.
public struct ProfileActionError: Error, Equatable, Sendable {
    public enum Code: String, Sendable {
        case notAuthenticated = "not_authenticated"
        case accountNotReady = "account_not_ready"
        case declarationRequired = "declaration_required"
        case invalidInput = "invalid_input"
        case prerequisiteMissing = "prerequisite_missing"
        case rateLimited = "rate_limited"
        case notFound = "not_found"
        case unavailable
    }

    public let code: Code
    public let fields: [String]

    public init(code: Code, fields: [String] = []) {
        self.code = code
        self.fields = fields
    }

    public func affects(_ field: ProfileField) -> Bool {
        fields.contains(field.rawValue) || (field == .interests &&
            fields.contains { $0 == "interest" || $0 == "interest_ids" })
    }
}

public struct SignInDeclarations: Equatable, Sendable {
    public var isAdult: Bool
    public var acceptsTermsAndPrivacy: Bool
    public init(isAdult: Bool = false, acceptsTermsAndPrivacy: Bool = false) {
        self.isAdult = isAdult
        self.acceptsTermsAndPrivacy = acceptsTermsAndPrivacy
    }
    public var canSignIn: Bool { isAdult && acceptsTermsAndPrivacy }
}

public enum ProfileValidation {
    public static let displayNameLimit = 30
    public static let introductionLimit = 200
    public static let contactDetailLimit = 100
    public static let interestLimit = 10
    public static let sharedInterestRange = 1...10

    public static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func characterCount(_ value: String) -> Int { value.count }

    public static func validRequiredText(_ value: String, limit: Int) -> Bool {
        !trimmed(value).isEmpty && characterCount(value) <= limit
    }

    public static func invalidBasics(displayName: String, introduction: String) -> [ProfileField] {
        var fields: [ProfileField] = []
        if !validRequiredText(displayName, limit: displayNameLimit) { fields.append(.displayName) }
        if !validRequiredText(introduction, limit: introductionLimit) { fields.append(.introduction) }
        return fields
    }

    public static func validSelections(interestIDs: Set<String>, purposes: Set<ProfilePurpose>,
                                       options: [InterestOption]) -> Bool {
        !interestIDs.isEmpty && interestIDs.count <= interestLimit && !purposes.isEmpty &&
            interestIDs.isSubset(of: Set(options.map(\.id)))
    }

    /// Removing an already selected interest is always possible, including at the limit.
    public static func canToggleInterest(_ id: String, selected: Set<String>) -> Bool {
        selected.contains(id) || selected.count < interestLimit
    }
}

public enum OnboardingStep: Sendable {
    case basics, interests, permissions

    public static func unfinishedStep(profile: OwnProfileState) -> Self {
        if !ProfileValidation.invalidBasics(displayName: profile.displayName,
                                            introduction: profile.introduction).isEmpty {
            return .basics
        }
        if profile.interestIDs.isEmpty || profile.interestIDs.count > ProfileValidation.interestLimit ||
            profile.purposes.isEmpty { return .interests }
        // S04 and link editing belong to Unit 5. Missing links remain visible on S05.
        return .permissions
    }
}

public enum BluetoothPermissionState: Sendable {
    case notRequested, available, denied, poweredOff, unavailable
    public var canEnableDiscovery: Bool { self == .available }
    public var needsRecovery: Bool { self == .denied || self == .poweredOff || self == .unavailable }
}

/// The composition layer implements these actions. This package does no I/O.
@MainActor
public struct ProfileActions {
    public var loadInterests: @MainActor () async throws -> [InterestOption]
    public var saveProfile: @MainActor (String, String, String) async throws -> OwnProfileState
    public var saveInterestsAndPurposes: @MainActor (Set<String>, Set<ProfilePurpose>) async throws -> OwnProfileState
    public var setDiscovery: @MainActor (Bool) async throws -> OwnProfileState
    public var requestBluetooth: @MainActor () async throws -> BluetoothPermissionState
    public var setMinimumSharedInterests: @MainActor (Int) async throws -> OwnProfileState
    public var setFieldVisibility: @MainActor (ProfileField, VisibilityLevel) async throws -> OwnProfileState

    public init(loadInterests: @escaping @MainActor () async throws -> [InterestOption],
                saveProfile: @escaping @MainActor (String, String, String) async throws -> OwnProfileState,
                saveInterestsAndPurposes: @escaping @MainActor (Set<String>, Set<ProfilePurpose>) async throws -> OwnProfileState,
                setDiscovery: @escaping @MainActor (Bool) async throws -> OwnProfileState,
                requestBluetooth: @escaping @MainActor () async throws -> BluetoothPermissionState,
                setMinimumSharedInterests: @escaping @MainActor (Int) async throws -> OwnProfileState,
                setFieldVisibility: @escaping @MainActor (ProfileField, VisibilityLevel) async throws -> OwnProfileState) {
        self.loadInterests = loadInterests
        self.saveProfile = saveProfile
        self.saveInterestsAndPurposes = saveInterestsAndPurposes
        self.setDiscovery = setDiscovery
        self.requestBluetooth = requestBluetooth
        self.setMinimumSharedInterests = setMinimumSharedInterests
        self.setFieldVisibility = setFieldVisibility
    }
}

/// Optional link routes stay absent until the Unit 5 composition layer supplies them.
@MainActor
public struct SettingsNavigationActions {
    public var back: @MainActor () -> Void
    public var editProfile: @MainActor () -> Void
    public var discovery: @MainActor () -> Void
    public var visibility: @MainActor () -> Void
    public var links: (@MainActor () -> Void)?
    public var bluetoothRecovery: @MainActor () -> Void
    public var discoveryOff: @MainActor () -> Void

    public init(back: @escaping @MainActor () -> Void, editProfile: @escaping @MainActor () -> Void,
                discovery: @escaping @MainActor () -> Void, visibility: @escaping @MainActor () -> Void,
                links: (@MainActor () -> Void)? = nil,
                bluetoothRecovery: @escaping @MainActor () -> Void = {},
                discoveryOff: @escaping @MainActor () -> Void = {}) {
        self.back = back; self.editProfile = editProfile; self.discovery = discovery
        self.visibility = visibility; self.links = links
        self.bluetoothRecovery = bluetoothRecovery; self.discoveryOff = discoveryOff
    }
}

/// Interim vocabulary, replaceable in one place or by the caller's loadInterests action.
public enum InterimProfileInterests {
    public static var options: [InterestOption] {
        [option("ios", .interestIOS), option("android", .interestAndroid), option("web", .interestWeb),
         option("backend", .interestBackend), option("design", .interestDesign), option("oss", .interestOSS)]
    }

    private static func option(_ id: String, _ key: SettingsString) -> InterestOption {
        InterestOption(id: id,
                       labelJapanese: SettingsStrings.localized(key.rawValue, language: "ja") ?? key.rawValue,
                       labelEnglish: SettingsStrings.localized(key.rawValue, language: "en") ?? key.rawValue)
    }
}
