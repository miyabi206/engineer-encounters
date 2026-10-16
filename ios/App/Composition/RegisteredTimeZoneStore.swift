import CryptoKit
import Foundation

@MainActor
final class RegisteredTimeZoneStore {
    private static let prefix = "encounter.timeZone.digest."
    private static let bindingKey = "encounter.timeZone.binding"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func key(for id: UUID) throws -> String {
        let salt = try InstallationStorageSalt.load(defaults: defaults)
        let digest = HMAC<SHA256>.authenticationCode(for: Data(id.uuidString.lowercased().utf8),
                                                    using: SymmetricKey(data: salt))
        return Self.prefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    func zone(for id: UUID) -> String? {
        guard synchronizeBinding(), let key = try? key(for: id) else { return nil }
        return defaults.string(forKey: key)
    }

    func record(_ zone: String, for id: UUID) {
        guard synchronizeBinding(), let key = try? key(for: id) else { return }
        defaults.set(zone, forKey: key)
    }

    func clear() {
        guard defaults.synchronize() else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) || key == Self.bindingKey {
            defaults.removeObject(forKey: key)
        }
    }

    private func synchronizeBinding() -> Bool {
        guard defaults.synchronize() else { return false }
        // Storage preparation binds the backend/account before setup. A different owner
        // must not reuse registrations made against the previous backend or account.
        let ownerData = defaults.data(forKey: BackendStorageBinding.ownerKey)
        let owner = ownerData.flatMap { try? JSONDecoder().decode(BackendStorageOwner.self, from: $0) }
        let previousOwner = defaults.data(forKey: Self.bindingKey).flatMap {
            try? JSONDecoder().decode(BackendStorageOwner.self, from: $0)
        }
        if previousOwner != owner {
            clear()
            defaults.set(ownerData, forKey: Self.bindingKey)
        }
        return true
    }
}
