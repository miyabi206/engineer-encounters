import Foundation

/// Every key referenced by these screens, also used to verify both string tables.
enum OnboardingString: String, CaseIterable {
    case age, agreement, terms, privacy, back, retry, loading, continueAction
    case basicsTitle, basicsSubtitle, displayName, introduction, contactDetail, basicsGuidance
    case interestsTitle, interests, purposes, discoveryPurpose, collaborationPurpose, selectionGuidance
    case enableDiscovery, allowBluetooth, notNow, promise, background, dailyReport, alternatives
    case forceQuit, firstUnlock, bluetoothPurpose, oneSided
    case counter, interestCounter, requiredField, tooLong, invalidField, saveError
    case signInError, listError, emptyInterests, interestLimit
    case checklist, link, linkRequired, addLink, met, missing
    case bluetoothNotRequested, bluetoothAvailable, bluetoothDenied, bluetoothOff, bluetoothUnavailable
    case bluetoothRecovery, authenticationError, accountError, declarationError, prerequisiteError
    case rateLimitError, notFoundError, discoveryOff
}

enum OnboardingStrings {
    static func text(_ key: OnboardingString) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: "Onboarding")
    }

    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: "Onboarding")
    }

    static func table(language: String) throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: "Onboarding", withExtension: "strings",
                                          subdirectory: nil, localization: language) else { return [:] }
        let data = try Data(contentsOf: url)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
    }

    static func counter(_ value: String, limit: Int) -> String {
        String(format: text(.counter), locale: Locale.current,
               ProfileValidation.characterCount(value), limit)
    }

    static func error(_ error: ProfileActionError) -> String {
        switch error.code {
        case .notAuthenticated: text(.authenticationError)
        case .accountNotReady: text(.accountError)
        case .declarationRequired: text(.declarationError)
        case .invalidInput: text(.invalidField)
        case .prerequisiteMissing: text(.prerequisiteError)
        case .rateLimited: text(.rateLimitError)
        case .notFound: text(.notFoundError)
        case .unavailable: text(.saveError)
        }
    }
}
