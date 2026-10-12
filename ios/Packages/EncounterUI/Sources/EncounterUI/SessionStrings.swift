import Foundation

enum SessionString: String, CaseIterable {
    case session, active, timeRemaining, twoHours, bothInSession, oneInSession, stop, noEncounters
    case ended, startOffline, stopPending, done, start, retry, back, loading, startFailed, refreshFailed
    case revealedEncounters, qrExchange, showCode, scanCode, refreshCode, allowCamera, confirming
    case expired, alreadyUsed, validity, invalidatesPrevious, selfScan, qrNetwork, unreadable, confirmed
    case openSettings, cameraDenied, cameraRestricted, cameraUnavailable, qrImage, cameraPreview, codeMode
    case remainingFormat
}

enum SessionStrings {
    static func text(_ key: SessionString) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: "Sessions")
    }
    static func localized(_ key: SessionString, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key.rawValue, value: nil, table: "Sessions")
    }
    static func table(language: String) throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: "Sessions", withExtension: "strings", subdirectory: nil, localization: language) else { return [:] }
        return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String] ?? [:]
    }
    static func remaining(_ seconds: Int) -> String {
        String(format: text(.remainingFormat), locale: Locale.current, text(.timeRemaining), SessionCountdown.text(seconds: seconds))
    }
    static func error(_ error: QRActionError) -> SessionString {
        switch error {
        case .selfScan: .selfScan
        case .expired: .expired
        case .alreadyUsed: .alreadyUsed
        case .unknownCode, .replaced: .unreadable
        case .network: .qrNetwork
        case .cameraUnavailable: .cameraUnavailable
        }
    }
}
