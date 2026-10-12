import Foundation

/// Exhaustive keys for the Settings table; Japanese is the package's default localization.
enum SettingsString: String, CaseIterable {
    case settings, editProfile, discoveryMatching, visibility, back, cancel, save, retry, loading, listError
    case displayName, introduction, interests, visibilityInterests, purposes, contactDetail, optionalContact
    case contactPrivate, discardChanges, discoveryRequired, discovery, requiredInformation, threshold, thresholdCount
    case matchingExplanation, saveMatching, linkVisibility, appliesToPast, saveVisibility
    case everyoneEligible, compatibleOnly, privateLevel, everyoneExplanation, compatibleExplanation, privateExplanation
    case discoveryPurpose, collaborationPurpose, selectionGuidance
    case labelStatus, fieldMessage, counter, interestCounter, interestLimit, requiredField, tooLong, invalidField, saveError, emptyInterests
    case checklist, link, linkRequired, met, missing, purposeRequired
    case authenticationError, accountError, declarationError, prerequisiteError, rateLimitError, notFoundError
    case discoveryOffExplanation, bluetoothPurpose, bluetoothNotRequested, bluetoothAvailable, bluetoothDenied
    case bluetoothOff, bluetoothUnavailable, bluetoothRecovery, allowBluetooth
    case promise, background, dailyReport, alternatives, forceQuit, firstUnlock, oneSided
    case partialSave, appliedChange, listItem, notSet
}

enum SettingsStrings {
    static func text(_ key: SettingsString) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: "Settings")
    }

    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: "Settings")
    }

    static func table(language: String) throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: "Settings", withExtension: "strings",
                                          subdirectory: nil, localization: language) else { return [:] }
        let data = try Data(contentsOf: url)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
    }

    static func labelStatus(_ label: String, _ status: String) -> String {
        String(format: text(.labelStatus), locale: Locale.current, label, status)
    }

    static func fieldMessage(_ label: String, _ message: String) -> String {
        String(format: text(.fieldMessage), locale: Locale.current, label, message)
    }

    static func counter(_ value: String, limit: Int) -> String {
        String(format: text(.counter), locale: Locale.current, SettingsValidation.textCount(value), limit)
    }

    static func joined(_ values: [String]) -> String {
        values.reduce("") { result, value in
            result.isEmpty ? value : String(format: text(.listItem), locale: Locale.current, result, value)
        }
    }

    static func threshold(_ count: Int) -> String {
        text(.thresholdCount).replacingOccurrences(of: "{count}", with: count.formatted())
    }
}

/// Only contractual field errors mark inputs; all other codes appear as a screen message.
enum SettingsErrorPresentation {
    static func message(_ error: ProfileActionError, screen: SettingsScreen, discoveryOn: Bool) -> SettingsString {
        switch error.code {
        case .notAuthenticated: .authenticationError
        case .accountNotReady: .accountError
        case .declarationRequired: .declarationError
        case .invalidInput: .invalidField
        case .prerequisiteMissing: screen == .profile && discoveryOn ? .discoveryRequired : .prerequisiteError
        case .rateLimited: .rateLimitError
        case .notFound: .notFoundError
        case .unavailable: .saveError
        }
    }

    static func affects(_ error: ProfileActionError?, field: ProfileField) -> Bool {
        guard let error, error.code == .invalidInput || error.code == .prerequisiteMissing else { return false }
        return error.affects(field)
    }

    static func affectsThreshold(_ error: ProfileActionError?) -> Bool {
        guard let error, error.code == .invalidInput else { return false }
        return error.fields.contains("minimum_shared_interests") || error.fields.contains("value")
    }
}

extension ProfileField {
    var settingsLabel: SettingsString {
        switch self {
        case .displayName: .displayName
        case .introduction: .introduction
        case .interests: .interests
        case .purposes: .purposes
        case .contactDetail: .contactDetail
        }
    }
}

extension DiscoveryPrerequisite {
    var settingsLabel: SettingsString {
        switch self {
        case .displayName: .displayName
        case .introduction: .introduction
        case .interest: .interests
        case .link: .link
        }
    }
}

extension VisibilityLevel {
    var settingsLabel: SettingsString {
        switch self {
        case .everyoneEligible: .everyoneEligible
        case .compatibleOnly: .compatibleOnly
        case .private: .privateLevel
        }
    }
}
