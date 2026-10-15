import EncounterBackend
import Foundation

/// A non-secret intent, keyed by the installation-salted backend/account namespace.
@MainActor
final class PendingAccountDeletionStore {
    static let prefix = "encounter.account.pendingDeletion."
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    func contains(owner: BackendStorageOwner) throws -> Bool {
        guard defaults.synchronize() else { throw BackendError.storageFailure }
        return defaults.object(forKey: Self.prefix + owner.namespace) != nil
    }

    func save(owner: BackendStorageOwner) throws {
        guard defaults.synchronize() else { throw BackendError.storageFailure }
        defaults.set(true, forKey: Self.prefix + owner.namespace)
        guard defaults.synchronize() else { throw BackendError.storageFailure }
    }

    func remove(owner: BackendStorageOwner) throws {
        guard defaults.synchronize() else { throw BackendError.storageFailure }
        defaults.removeObject(forKey: Self.prefix + owner.namespace)
        guard defaults.synchronize() else { throw BackendError.storageFailure }
    }

    func clear() throws {
        guard defaults.synchronize() else { throw BackendError.storageFailure }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
        guard defaults.synchronize() else { throw BackendError.storageFailure }
    }
}
