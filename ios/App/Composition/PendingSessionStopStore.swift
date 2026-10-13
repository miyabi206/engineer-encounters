import EncounterBackend
import Foundation

/// Non-secret stop/cancellation intents use the installation-salted account/backend
/// namespace. A cancelled start retains only an opaque request ID until answered.
@MainActor
final class PendingSessionStopStore {
    struct Marker: Codable, Equatable, Sendable {
        let sessionID: UUID
        let expiresAt: Date
    }
    struct CancelledStart: Codable, Equatable, Sendable {
        let requestID: UUID
    }
    static let prefix = "encounter.session.pendingStop."
    static let cancelledStartPrefix = "encounter.session.cancelledStart."
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

    func loadCancelledStart(owner: BackendStorageOwner) throws -> CancelledStart? {
        guard defaults.synchronize() else { throw BackendError.storageFailure }
        let key = Self.cancelledStartPrefix + owner.namespace
        guard defaults.object(forKey: key) != nil else { return nil }
        guard let data = defaults.data(forKey: key),
              let marker = try? JSONDecoder().decode(CancelledStart.self, from: data) else {
            throw BackendError.storageFailure
        }
        return marker
    }

    func saveCancelledStart(_ marker: CancelledStart, owner: BackendStorageOwner) throws {
        guard defaults.synchronize() else { throw BackendError.storageFailure }
        defaults.set(try JSONEncoder().encode(marker), forKey: Self.cancelledStartPrefix + owner.namespace)
        guard defaults.synchronize() else { throw BackendError.storageFailure }
    }

    func removeCancelledStart(_ marker: CancelledStart, owner: BackendStorageOwner) throws {
        guard try loadCancelledStart(owner: owner) == marker else { return }
        defaults.removeObject(forKey: Self.cancelledStartPrefix + owner.namespace)
        guard defaults.synchronize() else { throw BackendError.storageFailure }
    }

    func clear() {
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(Self.prefix) || key.hasPrefix(Self.cancelledStartPrefix) {
            defaults.removeObject(forKey: key)
        }
        _ = defaults.synchronize()
    }
}
