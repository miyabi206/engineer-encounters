import Foundation

enum LinkString: String, CaseIterable {
    case firstLink, myLinks, addLink, addTitle, editLink, edit, platformExplanation
    case identityWarning, linkRequired, noLinks, linkLimit, back, cancel, save
    case retry, loading, loadError, continueAction, github, qiita, zenn
    case otherPage, connectGitHub, repositories, select, noItems, originalURL, source
    case openOriginal, title, description, mainLanguage, tags, openingText, refresh
    case visibility, chooseVisibility, preview, replaceEdits, delete, deleteExplanation, verified
    case unverified, everyone, compatible, `private`, counter, labelValue, connecting
    case connected, connectionFailed, connectionCancelled, notAvailable, chooseSource, saveError, refreshError
    case deleteError, reorderError, invalidField, requiredTitle, tooLong, addTag, removeTag
    case replace, discard, lastLink, discoverySettings, nextPage, previousPage, page
    case moveUp, moveDown, connectedWithoutHandle, readerFailure
    case retryLinks, retryConnection, retryConnect, retryRepositories, retryPreview, retrySave, retryReorder, retryRefresh
}

enum LinkStrings {
    static func retryLabel(_ operation: LinkOperation) -> String {
        let key: LinkString
        switch operation {
        case .loadLinks: key = .retryLinks
        case .loadConnection: key = .retryConnection
        case .connect: key = .retryConnect
        case .repositories: key = .retryRepositories
        case .preview: key = .retryPreview
        case .save: key = .retrySave
        case .reorder: key = .retryReorder
        case .refresh: key = .retryRefresh
        case .delete: key = .delete
        }
        return text(key)
    }
    static func text(_ key: LinkString) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: "Links")
    }
    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: "Links")
    }
    static func table(language: String) throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: "Links", withExtension: "strings",
                                          subdirectory: nil, localization: language) else { return [:] }
        let data = try Data(contentsOf: url)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
    }
    static func counter(_ count: Int, limit: Int) -> String {
        String(format: text(.counter), locale: Locale.current, count, limit)
    }
    static func label(_ label: String, value: String) -> String {
        String(format: text(.labelValue), locale: Locale.current, label, value)
    }
    static func source(_ source: LinkSource) -> String {
        text(source == .github ? .github : source == .qiita ? .qiita : source == .zenn ? .zenn : .otherPage)
    }
    static func visibility(_ level: VisibilityLevel?) -> String {
        guard let level else { return text(.chooseVisibility) }
        switch level {
        case .everyoneEligible: return text(.everyone)
        case .compatibleOnly: return text(.compatible)
        case .private: return text(.private)
        }
    }
}
