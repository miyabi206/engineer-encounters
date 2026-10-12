import EncounterBackend
import Foundation

/// Only a session ID and its advisory local expiry are retained. The key uses
/// the same installation-salted account/backend namespace as other bound storage.
@MainActor
final class PendingSessionStopStore {
    struct Marker: Codable, Equatable, Sendable {
        let sessionID: UUID
        let expiresAt: Date
    }
    static let prefix = "encounter.session.pendingStop."
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load(owner: BackendStorageOwner) throws -> Marker? {
        guard defaults.synchronize() else { throw BackendError.storageFailure }
        let key = Self.prefix + owner.namespace
        guard defaults.object(forKey: key) != nil else { return nil }
        guard let data = defaults.data(forKey: key),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else {
            defaults.removeObject(forKey: key)
            _ = defaults.synchronize()
            return nil
        }
        return marker
    }

    func save(_ marker: Marker, owner: BackendStorageOwner) throws {
        guard defaults.synchronize(), let data = try? JSONEncoder().encode(marker) else { throw BackendError.storageFailure }
        defaults.set(data, forKey: Self.prefix + owner.namespace)
        guard defaults.synchronize() else { throw BackendError.storageFailure }
    }

    func remove(_ marker: Marker, owner: BackendStorageOwner) {
        guard (try? load(owner: owner)) == marker else { return }
        defaults.removeObject(forKey: Self.prefix + owner.namespace)
        _ = defaults.synchronize()
    }

    func clear() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
        _ = defaults.synchronize()
    }
}
