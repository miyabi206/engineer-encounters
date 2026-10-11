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
public enum ReceiptStorageError: Error, Sendable {
    case unavailable
    case corruptedReceipt
    case sequenceExhausted
}

/// Serializes saved receipt writes and retains only identity/expiry after termination.
/// Unlike the ephemeral queue, expired tombstones are deleted by removeExpired;
/// identity reuse is permitted after that deletion. Unseen acknowledgements live for 48 hours.
public actor SwiftDataReceiptQueue: ReceiptQueue {
    private let context: ModelContext
    private let directory: URL?
    private let storeURL: URL?
    private let now: @Sendable () -> Date

    private init(directory: URL?, now: @escaping @Sendable () -> Date) throws {
        let schema = Schema([StoredReceipt.self, TerminalReceiptIdentity.self])
        let configuration: ModelConfiguration
        let storeURL = directory?.appendingPathComponent("receipts.store")
        if let directory, let storeURL {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.validateLocation(directory: directory, storeURL: storeURL)
            try Self.protectFiles(directory: directory, storeURL: storeURL)
            configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
        self.directory = directory
        self.storeURL = storeURL
        self.now = now
        if let directory, let storeURL {
            try Self.protectFiles(directory: directory, storeURL: storeURL)
        }
    }

    /// Creates an isolated ephemeral store with the durable queue's semantics.
    public static func inMemory(now: @escaping @Sendable () -> Date = { Date() }) throws -> SwiftDataReceiptQueue {
        try SwiftDataReceiptQueue(directory: nil, now: now)
    }

    /// Opens a protected local store, defaulting to its own Application Support directory.
    public static func fileBacked(directory: URL? = nil,
                                  now: @escaping @Sendable () -> Date = { Date() }) throws -> SwiftDataReceiptQueue {
        let location: URL
        if let directory {
            location = directory
        } else {
            location = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
                .appendingPathComponent("EncounterStorage", isDirectory: true)
        }
        return try SwiftDataReceiptQueue(directory: location, now: now)
    }

    public func enqueue(_ receipt: EncounterReceipt) async throws {
        guard try stored(receipt.id) == nil, try terminal(receipt.id) == nil else { return }
        let last = try context.fetch(FetchDescriptor<StoredReceipt>(sortBy: [SortDescriptor(\.sequence, order: .reverse)]))
            .first?.sequence ?? -1
        guard last < Int64.max else { throw ReceiptStorageError.sequenceExhausted }
        let payload = try JSONEncoder().encode(receipt)
        try write {
            context.insert(StoredReceipt(receipt: receipt, sequence: last + 1, payload: payload))
        }
    }

    public func update(_ receipt: EncounterReceipt) async throws {
        guard let row = try stored(receipt.id) else { throw ReceiptQueueError.missingIdentity(receipt.id) }
        let original = try decode(row)
        guard original.start == receipt.start, original.protocolVersion == receipt.protocolVersion,
              original.role == receipt.role, original.exchangeNonce == receipt.exchangeNonce,
              original.priorExchangeNonce == receipt.priorExchangeNonce else {
            throw ReceiptQueueError.changedInitialEvidence(receipt.id)
        }
        let payload = try JSONEncoder().encode(receipt)
        try write { row.payload = payload }
    }

    public func pending() async throws -> [EncounterReceipt] {
        try context.fetch(FetchDescriptor<StoredReceipt>(sortBy: [SortDescriptor(\.sequence)]))
            .map { try decode($0) }
    }

    public func acknowledge(_ identity: UUID) async throws {
        guard try terminal(identity) == nil else { return }
        let row = try stored(identity)
        let expiry = row?.expiry ?? now().addingTimeInterval(EncounterProtocol.receiptLifetime)
        try write {
            if let row { context.delete(row) }
            context.insert(TerminalReceiptIdentity(identity: identity, expiry: expiry))
        }
    }

    public func removeExpired(asOf time: Date) async throws {
        let receipts = try context.fetch(FetchDescriptor<StoredReceipt>(predicate: #Predicate { $0.expiry <= time }))
        let tombstones = try context.fetch(FetchDescriptor<TerminalReceiptIdentity>(predicate: #Predicate { $0.expiry <= time }))
        // The receipt deadline has already passed, so its identity needs no further retention.
        try write {
            for row in receipts { context.delete(row) }
            for row in tombstones { context.delete(row) }
        }
    }

    public func removeAll() async throws {
        let receipts = try context.fetch(FetchDescriptor<StoredReceipt>())
        let tombstones = try context.fetch(FetchDescriptor<TerminalReceiptIdentity>())
        try write {
            for row in receipts { context.delete(row) }
            for row in tombstones { context.delete(row) }
        }
    }

    private func stored(_ identity: UUID) throws -> StoredReceipt? {
        var descriptor = FetchDescriptor<StoredReceipt>(predicate: #Predicate { $0.identity == identity })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func terminal(_ identity: UUID) throws -> TerminalReceiptIdentity? {
        var descriptor = FetchDescriptor<TerminalReceiptIdentity>(predicate: #Predicate { $0.identity == identity })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func decode(_ row: StoredReceipt) throws -> EncounterReceipt {
        do { return try JSONDecoder().decode(EncounterReceipt.self, from: row.payload) }
        catch { throw ReceiptStorageError.corruptedReceipt }
    }

    private func write(_ change: () -> Void) throws {
        do {
            if let directory, let storeURL {
                try Self.validateLocation(directory: directory, storeURL: storeURL)
                try Self.protectFiles(directory: directory, storeURL: storeURL)
            }
            change()
            try context.save()
            if let directory, let storeURL {
                try Self.protectFiles(directory: directory, storeURL: storeURL)
            }
        } catch {
            context.rollback()
            throw error
        }
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
