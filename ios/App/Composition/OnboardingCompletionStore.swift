import CryptoKit
import Foundation
import EncounterBackend

/// Shared by all account-derived storage names. Never mint a replacement while preferences are unavailable.
@MainActor
enum InstallationStorageSalt {
    static let key = "encounter.onboarding.installationSalt"

    static func load(defaults: UserDefaults) throws -> Data {
        guard defaults.synchronize() else { throw BackendError.storageFailure }
        if let salt = defaults.data(forKey: key) {
            guard salt.count >= 32 else { throw BackendError.storageFailure }
            return salt
        }
        let salt = Data((UUID().uuidString + UUID().uuidString).utf8)
        defaults.set(salt, forKey: key)
        guard defaults.synchronize() else { throw BackendError.storageFailure }
        return salt
    }
}

@MainActor
final class OnboardingCompletionStore {
    private static let legacyPrefix = "encounter.onboarding.completed."
    private static let prefix = "encounter.onboarding.digest."
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard (try? InstallationStorageSalt.load(defaults: defaults)) != nil else { return }
        // Remove identifiers left by the earlier marker format; never migrate them into logs.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.legacyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func key(for id: UUID) throws -> String {
        let salt = try InstallationStorageSalt.load(defaults: defaults)
        let digest = HMAC<SHA256>.authenticationCode(for: Data(id.uuidString.lowercased().utf8),
                                                    using: SymmetricKey(data: salt))
        return Self.prefix + digest.map { String(format: "%02x", $0) }.joined()
    }
    func contains(_ id: UUID) -> Bool {
        guard let key = try? key(for: id) else { return false }
        return defaults.bool(forKey: key)
    }
    func finish(_ id: UUID) {
        guard let key = try? key(for: id) else { return }
        defaults.set(true, forKey: key)
    }
    func clear() {
        guard defaults.synchronize() else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) || key.hasPrefix(Self.legacyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
