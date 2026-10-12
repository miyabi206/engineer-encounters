import CryptoKit
import EncounterBackend
import EncounterDomain
import Foundation

/// A durable, non-secret tombstone. Never put an account identifier in this marker.
@MainActor
final class SessionCleanupMarker {
    static let key = "encounter.backend.sessionCleanupPending"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }
    var isPending: Bool { defaults.bool(forKey: Self.key) }

    func begin() throws {
        defaults.set(true, forKey: Self.key)
        guard defaults.synchronize() else { throw BackendError.storageFailure }
    }

    func complete() {
        defaults.removeObject(forKey: Self.key)
        // A surviving marker is safe: launch simply retries the idempotent deletion.
        _ = defaults.synchronize()
    }
}

struct BackendStorageOwner: Codable, Equatable, Sendable {
    let backend: String
    let accountDigest: String?

    init(backend: String, account: UUID?) {
        self.backend = backend
        accountDigest = account.map { Self.digest($0.uuidString.lowercased()) }
    }

    var namespace: String { Self.digest(backend + "|" + (accountDigest ?? "signed-out")) }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Persists only backend identities and digests; a process lease fences results from old compositions.
@MainActor
final class BackendStorageBinding {
    private final class WeakBinding {
        weak var value: BackendStorageBinding?
        init(_ value: BackendStorageBinding) { self.value = value }
    }
    private static var liveBindings: [String: WeakBinding] = [:]
    static let sessionBackendKey = "encounter.backend.sessionBackend"
    static let ownerKey = "encounter.backend.storageOwner"
    private static let leaseKey = "encounter.backend.storageLease"
    let backend: String
    let cleanup: SessionCleanupMarker
    private let defaults: UserDefaults
    private let lease = UUID().uuidString
    private var accountDigest: String?
    let predecessorDrain: Task<Void, Never>?
    var onReplacement: (@MainActor () -> Task<Void, Never>)?

    static func identity(_ configuration: BackendConfiguration) -> String {
        let scheme = configuration.address.scheme!.lowercased()
        let host = configuration.address.host!.lowercased()
        let port = configuration.address.port ?? (scheme == "https" ? 443 : 80)
        return scheme + "://" + host + ":" + String(port)
    }

    init(configuration: BackendConfiguration, defaults: UserDefaults, cleanup: SessionCleanupMarker) {
        backend = Self.identity(configuration)
        self.defaults = defaults
        self.cleanup = cleanup
        predecessorDrain = defaults.string(forKey: Self.leaseKey)
            .flatMap { Self.liveBindings[$0]?.value?.onReplacement?() }
        defaults.set(lease, forKey: Self.leaseKey)
        Self.liveBindings = Self.liveBindings.filter { $0.value.value != nil }
        Self.liveBindings[lease] = WeakBinding(self)
    }

    var isCurrent: Bool { defaults.string(forKey: Self.leaseKey) == lease }
    var allowsNetwork: Bool { isCurrent && !cleanup.isPending }
    var allowsAuthenticatedNetwork: Bool {
        allowsNetwork && accountDigest != nil && owner?.backend == backend && owner?.accountDigest == accountDigest
    }
    var currentAccountDigest: String? { accountDigest }
    var sessionMatches: Bool { defaults.string(forKey: Self.sessionBackendKey) == backend }
    var owner: BackendStorageOwner? {
        defaults.data(forKey: Self.ownerKey).flatMap { try? JSONDecoder().decode(BackendStorageOwner.self, from: $0) }
    }

    func saveSessionBinding() throws {
        guard allowsNetwork else { throw BackendError.notAuthenticated }
        defaults.set(backend, forKey: Self.sessionBackendKey)
        guard defaults.synchronize() else { throw BackendError.storageFailure }
    }

    func clearedSession() {
        accountDigest = nil
        defaults.removeObject(forKey: Self.sessionBackendKey)
        cleanup.complete()
    }

    func observeAccount(_ id: UUID) throws {
        guard allowsNetwork else { throw BackendError.notAuthenticated }
        accountDigest = BackendStorageOwner(backend: backend, account: id).accountDigest
    }

    func bind(_ owner: BackendStorageOwner) throws {
        guard isCurrent else { throw BackendError.notAuthenticated }
        defaults.set(try JSONEncoder().encode(owner), forKey: Self.ownerKey)
        guard defaults.synchronize() else { throw BackendError.storageFailure }
    }

    func allowsStorage(_ owner: BackendStorageOwner) -> Bool {
        isCurrent && self.owner == owner
    }
}

/// Every manager clear, including an invalid refresh, records the tombstone before deleting.
actor BoundSessionStore: SessionStore {
    private let store: any SessionStore
    private let binding: BackendStorageBinding
    private var writing: Task<Void, any Error>?

    init(_ store: any SessionStore, binding: BackendStorageBinding) {
        self.store = store
        self.binding = binding
    }

    func load() async throws -> BackendSession? {
        guard await binding.isCurrent else { throw BackendError.notAuthenticated }
        guard await !binding.cleanup.isPending else { throw BackendError.notAuthenticated }
        guard await binding.sessionMatches else {
            try await clear()
            return nil
        }
        do {
            let session = try await store.load()
            if let session { try await binding.observeAccount(session.userID) }
            return session
        }
        catch BackendError.notAuthenticated {
            try await clear()
            return nil
        }
    }

    func save(_ session: BackendSession) async throws {
        try await write {
            guard await self.binding.allowsNetwork else { throw BackendError.storageFailure }
            try await self.binding.observeAccount(session.userID)
            try await self.store.save(session)
            try await self.binding.saveSessionBinding()
        }
    }

    func clear() async throws {
        try await write {
            guard await self.binding.isCurrent else { throw BackendError.notAuthenticated }
            try await self.binding.cleanup.begin()
            try await self.store.clear()
            guard await self.binding.isCurrent else { throw BackendError.notAuthenticated }
            await self.binding.clearedSession()
        }
    }

    func drain() async { _ = await writing?.result }

    private func write(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = writing
        let task = Task { _ = await previous?.result; try await operation() }
        writing = task
        try await task.value
    }
}

struct BackendBoundTransport: HTTPTransport {
    let transport: any HTTPTransport
    let binding: BackendStorageBinding

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard await binding.allowsNetwork else { throw CancellationError() }
        let account = await binding.currentAccountDigest
        if request.url?.path.contains("/rest/v1/rpc/") == true {
            guard await binding.allowsAuthenticatedNetwork else { throw CancellationError() }
        }
        let response = try await transport.send(request)
        guard await binding.isCurrent, await binding.currentAccountDigest == account else { throw CancellationError() }
        return response
    }
}

struct BoundTokenBatchStore: TokenBatchStore {
    let store: any TokenBatchStore
    let binding: BackendStorageBinding
    let owner: BackendStorageOwner

    func load() async throws -> TokenBatch? {
        guard await binding.allowsStorage(owner) else { throw CancellationError() }
        let batch = try await store.load()
        guard await binding.allowsStorage(owner) else { throw CancellationError() }
        return batch
    }
    func save(_ batch: TokenBatch) async throws {
        guard await binding.allowsStorage(owner) else { throw CancellationError() }
        try await store.save(batch)
    }
    func clear() async throws {
        guard await binding.allowsStorage(owner) else { throw CancellationError() }
        try await store.clear()
    }
}

struct BoundReceiptQueue: ReceiptQueue {
    let queue: any ReceiptQueue
    let binding: BackendStorageBinding
    let owner: BackendStorageOwner

    private func check() async throws {
        guard await binding.allowsStorage(owner) else { throw CancellationError() }
    }
    func pending() async throws -> [EncounterReceipt] {
        try await check()
        let receipts = try await queue.pending()
        try await check()
        return receipts
    }
    func enqueue(_ receipt: EncounterReceipt) async throws { try await check(); try await queue.enqueue(receipt) }
    func update(_ receipt: EncounterReceipt) async throws { try await check(); try await queue.update(receipt) }
    func acknowledge(_ identity: UUID) async throws { try await check(); try await queue.acknowledge(identity) }
    func removeExpired(asOf time: Date) async throws { try await check(); try await queue.removeExpired(asOf: time) }
    func removeAll() async throws { try await check(); try await queue.removeAll() }
}
