import CryptoKit
import Foundation

@MainActor
final class OnboardingCompletionStore {
    private static let legacyPrefix = "encounter.onboarding.completed."
    private static let prefix = "encounter.onboarding.digest."
    private static let saltKey = "encounter.onboarding.installationSalt"
    private let defaults: UserDefaults
    private let salt: Data

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let stored = defaults.data(forKey: Self.saltKey) { salt = stored }
        else {
            salt = Data((UUID().uuidString + UUID().uuidString).utf8)
            defaults.set(salt, forKey: Self.saltKey)
        }
        // Remove identifiers left by the earlier marker format; never migrate them into logs.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.legacyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func key(for id: UUID) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data(id.uuidString.lowercased().utf8),
                                                    using: SymmetricKey(data: salt))
        return Self.prefix + digest.map { String(format: "%02x", $0) }.joined()
    }
    func contains(_ id: UUID) -> Bool { defaults.bool(forKey: key(for: id)) }
    func finish(_ id: UUID) { defaults.set(true, forKey: key(for: id)) }
    func clear() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) || key.hasPrefix(Self.legacyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
