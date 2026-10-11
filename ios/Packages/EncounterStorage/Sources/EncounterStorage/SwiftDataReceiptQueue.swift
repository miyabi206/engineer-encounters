import Foundation
import SwiftData
import EncounterDomain

@Model
final class StoredReceipt {
    @Attribute(.unique) var identity: UUID
    var sequence: Int64
    var expiry: Date
    var payload: Data

    init(receipt: EncounterReceipt, sequence: Int64, payload: Data) {
        identity = receipt.id
        self.sequence = sequence
        expiry = receipt.expiresAt
        self.payload = payload
    }
}

@Model
final class TerminalReceiptIdentity {
    @Attribute(.unique) var identity: UUID
    var expiry: Date

    init(identity: UUID, expiry: Date) {
        self.identity = identity
        self.expiry = expiry
    }
}

/// Reports storage failures without including receipt or token material.
public enum ReceiptStorageError: Error, Equatable, Sendable {
    case unavailable
    case corruptedReceipt
    case encodingFailed
    case saveFailed
    case sequenceExhausted
    case queueFull
}

/// Internal fault seam; hooks run synchronously on the queue's model executor.
struct ReceiptQueueWriteHooks: Sendable {
    var beforeSave: @Sendable () throws -> Void = {}
    var afterSaveProtection: @Sendable () throws -> Void = {}
}

/// Serializes saved receipt writes and retains only identity/expiry after termination.
/// Expired rows are deleted by removeExpired and enqueue. Tombstones are also
/// bounded by capacity, evicting the earliest expiry first. Unseen acknowledgements live for 48 hours.
/// One process must open only one queue instance per store directory.
public actor SwiftDataReceiptQueue: ModelActor, ReceiptQueue {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor
    private let directory: URL?
    private let storeURL: URL?
    private let now: @Sendable () -> Date
    private let receiptLimit: Int
    private let tombstoneLimit: Int
    private var writeHooks = ReceiptQueueWriteHooks()

    // Only the detached factories call this initializer, so SwiftData binds the
    // context and its serial executor to a background queue rather than the main queue.
    private init(directory: URL?, now: @escaping @Sendable () -> Date,
                 receiptLimit: Int, tombstoneLimit: Int) throws {
        let schema = Schema([StoredReceipt.self, TerminalReceiptIdentity.self])
        let storeURL = directory?.appendingPathComponent("receipts.store")
        let container: ModelContainer
        do {
            let configuration: ModelConfiguration
            if let directory, let storeURL {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.validateLocation(directory: directory, storeURL: storeURL)
                var location = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try location.setResourceValues(values)
                try Self.protectFiles(directory: directory, storeURL: storeURL)
                configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            } else {
                configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                                   groupContainer: .none, cloudKitDatabase: .none)
            }
            container = try ModelContainer(for: schema, configurations: [configuration])
            if let directory, let storeURL {
                try Self.protectFiles(directory: directory, storeURL: storeURL)
            }
        } catch {
            throw ReceiptStorageError.unavailable
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.directory = directory
        self.storeURL = storeURL
        self.now = now
        self.receiptLimit = max(0, min(receiptLimit, 4096))
        self.tombstoneLimit = max(0, min(tombstoneLimit, 4096))
    }

    /// Creates an isolated ephemeral store off the main thread.
    public static func inMemory(now: @escaping @Sendable () -> Date = { Date() },
                                receiptLimit: Int = 4096, tombstoneLimit: Int = 4096) async throws -> SwiftDataReceiptQueue {
        try await Task.detached {
            try SwiftDataReceiptQueue(directory: nil, now: now,
                                      receiptLimit: receiptLimit, tombstoneLimit: tombstoneLimit)
        }.value
    }

    /// Opens a protected, backup-excluded local store off the main thread.
    public static func fileBacked(directory: URL? = nil,
                                  now: @escaping @Sendable () -> Date = { Date() },
                                  receiptLimit: Int = 4096, tombstoneLimit: Int = 4096) async throws -> SwiftDataReceiptQueue {
        try await Task.detached {
            do {
                let location: URL
                if let directory {
                    location = directory
                } else {
                    location = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true)
                        .appendingPathComponent("EncounterStorage", isDirectory: true)
                }
                return try SwiftDataReceiptQueue(directory: location, now: now,
                                                 receiptLimit: receiptLimit, tombstoneLimit: tombstoneLimit)
            } catch {
                throw ReceiptStorageError.unavailable
            }
        }.value
    }

    public nonisolated func enqueue(_ receipt: EncounterReceipt) async throws {
        try await onModelExecutor { try $0.enqueueIsolated(receipt) }
    }

    public nonisolated func update(_ receipt: EncounterReceipt) async throws {
        try await onModelExecutor { try $0.updateIsolated(receipt) }
    }

    public nonisolated func pending() async throws -> [EncounterReceipt] {
        try await onModelExecutor { try $0.pendingIsolated() }
    }

    public nonisolated func acknowledge(_ identity: UUID) async throws {
        try await onModelExecutor { try $0.acknowledgeIsolated(identity) }
    }

    public nonisolated func removeExpired(asOf time: Date) async throws {
        try await onModelExecutor { try $0.removeExpiredIsolated(asOf: time) }
    }

    public nonisolated func removeAll() async throws {
        try await onModelExecutor { try $0.removeAllIsolated() }
    }

    // Enter from the cooperative pool even when called by MainActor. This also
    // prevents synchronous executor switching from doing storage work on the caller's main thread.
    private nonisolated func onModelExecutor<T: Sendable>(
        _ operation: @escaping @Sendable (isolated SwiftDataReceiptQueue) throws -> T
    ) async throws -> T {
        try await Task.detached {
            try await operation(self)
        }.value
    }

    private func enqueueIsolated(_ receipt: EncounterReceipt) throws {
        try removeExpiredIsolated(asOf: now())
        guard try stored(receipt.id) == nil, try terminal(receipt.id) == nil else { return }
        guard try fetch(FetchDescriptor<StoredReceipt>()).count < receiptLimit else {
            throw ReceiptStorageError.queueFull
        }
        var descriptor = FetchDescriptor<StoredReceipt>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        descriptor.fetchLimit = 1
        let last = try fetch(descriptor).first?.sequence ?? -1
        guard last < Int64.max else { throw ReceiptStorageError.sequenceExhausted }
        let payload = try encode(receipt)
        try write {
            modelContext.insert(StoredReceipt(receipt: receipt, sequence: last + 1, payload: payload))
        }
    }

    private func updateIsolated(_ receipt: EncounterReceipt) throws {
        guard let row = try stored(receipt.id), row.expiry > now() else {
            throw ReceiptQueueError.missingIdentity(receipt.id)
        }
        let original = try decode(row)
        guard original.start == receipt.start, original.protocolVersion == receipt.protocolVersion,
              original.role == receipt.role, original.exchangeNonce == receipt.exchangeNonce,
              original.priorExchangeNonce == receipt.priorExchangeNonce else {
            throw ReceiptQueueError.changedInitialEvidence(receipt.id)
        }
        let payload = try encode(receipt)
        try write { row.payload = payload }
    }

    private func pendingIsolated() throws -> [EncounterReceipt] {
        let time = now()
        let rows = try fetch(FetchDescriptor<StoredReceipt>(predicate: #Predicate { $0.expiry > time },
                                                           sortBy: [SortDescriptor(\.sequence)]))
        var receipts: [EncounterReceipt] = []
        for row in rows {
            if let receipt = try? decode(row), receipt.expiresAt > time {
                receipts.append(receipt)
            }
        }
        // A future receipt format may be undecodable here; retain it until expiry.
        return receipts
    }

    private func acknowledgeIsolated(_ identity: UUID) throws {
        guard try terminal(identity) == nil else { return }
        let time = now()
        let storedRow = try stored(identity)
        let row = storedRow.flatMap { $0.expiry > time ? $0 : nil }
        let expiry = row?.expiry ?? time.addingTimeInterval(EncounterProtocol.receiptLifetime)
        let tombstone = TerminalReceiptIdentity(identity: identity, expiry: expiry)
        let tombstones = (try fetch(FetchDescriptor<TerminalReceiptIdentity>()) + [tombstone])
            .sorted { $0.expiry < $1.expiry }
        let evicted = tombstones.prefix(max(0, tombstones.count - tombstoneLimit))
        try write {
            if let storedRow { modelContext.delete(storedRow) }
            if !evicted.contains(where: { $0 === tombstone }) { modelContext.insert(tombstone) }
            for old in evicted where old !== tombstone { modelContext.delete(old) }
        }
    }

    private func removeExpiredIsolated(asOf time: Date) throws {
        let receipts = try fetch(FetchDescriptor<StoredReceipt>(predicate: #Predicate { $0.expiry <= time }))
        let tombstones = try fetch(FetchDescriptor<TerminalReceiptIdentity>(predicate: #Predicate { $0.expiry <= time }))
        guard !receipts.isEmpty || !tombstones.isEmpty else { return }
        // The receipt deadline has already passed, so its identity needs no further retention.
        try write {
            for row in receipts { modelContext.delete(row) }
            for row in tombstones { modelContext.delete(row) }
        }
    }

    private func removeAllIsolated() throws {
        let receipts = try fetch(FetchDescriptor<StoredReceipt>())
        let tombstones = try fetch(FetchDescriptor<TerminalReceiptIdentity>())
        try write {
            for row in receipts { modelContext.delete(row) }
            for row in tombstones { modelContext.delete(row) }
        }
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        do { return try modelContext.fetch(descriptor) }
        catch { throw ReceiptStorageError.unavailable }
    }

    private func stored(_ identity: UUID) throws -> StoredReceipt? {
        var descriptor = FetchDescriptor<StoredReceipt>(predicate: #Predicate { $0.identity == identity })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func terminal(_ identity: UUID) throws -> TerminalReceiptIdentity? {
        var descriptor = FetchDescriptor<TerminalReceiptIdentity>(predicate: #Predicate { $0.identity == identity })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func encode(_ receipt: EncounterReceipt) throws -> Data {
        do { return try JSONEncoder().encode(receipt) }
        catch { throw ReceiptStorageError.encodingFailed }
    }

    private func decode(_ row: StoredReceipt) throws -> EncounterReceipt {
        do { return try JSONDecoder().decode(EncounterReceipt.self, from: row.payload) }
        catch { throw ReceiptStorageError.corruptedReceipt }
    }

    func setWriteHooks(_ hooks: ReceiptQueueWriteHooks) {
        writeHooks = hooks
    }

    private func write(_ change: () -> Void) throws {
        if let directory, let storeURL {
            try Self.validateLocation(directory: directory, storeURL: storeURL)
            try? Self.protectFiles(directory: directory, storeURL: storeURL)
        }
        change()
        do {
            try writeHooks.beforeSave()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw ReceiptStorageError.saveFailed
        }
        // A committed write must always be reported as successful, including
        // when a sidecar disappears or protection cannot be reapplied.
        if let directory, let storeURL {
            try? protectAfterSave(directory: directory, storeURL: storeURL)
        }
    }

    private func protectAfterSave(directory: URL, storeURL: URL) throws {
        try writeHooks.afterSaveProtection()
        try Self.protectFiles(directory: directory, storeURL: storeURL)
    }

    private static func validateLocation(directory: URL, storeURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue, FileManager.default.isWritableFile(atPath: directory.path) else {
            throw ReceiptStorageError.unavailable
        }
        if FileManager.default.fileExists(atPath: storeURL.path),
           !FileManager.default.isWritableFile(atPath: storeURL.path) {
            throw ReceiptStorageError.unavailable
        }
    }

    private static func protectFiles(directory: URL, storeURL: URL) throws {
        #if os(iOS)
        let paths = [directory.path, storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: path)
        }
        #endif
    }
}
