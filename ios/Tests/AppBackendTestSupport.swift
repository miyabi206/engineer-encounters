import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import Foundation
import XCTest
@testable import EngineerEncounters

let appBackendTestNow = EncounterSamples.observationTime
let appBackendTestUser = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!

func appBackendTestConfiguration() -> BackendConfiguration {
    BackendConfiguration(address: "https://backend.example", publicClientKey: "public-test-key")!
}

func appBackendTestSession(userID: UUID = appBackendTestUser) throws -> BackendSession {
    try BackendSession(accessCredential: "fixture-access", refreshCredential: "fixture-refresh",
                       expiresAt: appBackendTestNow.addingTimeInterval(3600), userID: userID)
}

func appBackendAuthResponse(userID: UUID = appBackendTestUser) -> HTTPResponse {
    HTTPResponse(data: Data("""
    {"access_token":"fixture-access","refresh_token":"fixture-refresh","token_type":"bearer",
     "expires_in":3600,"user":{"id":"\(userID.uuidString)"}}
    """.utf8), statusCode: 200)
}

func appBackendFinalReceipt(_ index: Int = 1) -> EncounterReceipt {
    var receipt = EncounterSamples.receipt(index)
    receipt.isFinalEvidence = true
    receipt.sessionFlag = true
    return receipt
}

actor AppBackendTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    private var responses: [HTTPResponse]
    init(_ responses: [HTTPResponse] = []) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackendError.transportFailure }
        return responses.removeFirst()
    }
    func recorded() -> [URLRequest] { requests }
}

actor AppMemoryKeychain: KeychainClient {
    private var values: [String: Data] = [:]
    private(set) var services: Set<String> = []
    private(set) var reads = 0
    func read(service: String, account: String) async throws -> Data? {
        reads += 1
        return values[service + ":" + account]
    }
    func writeOrReplace(_ data: Data, service: String, account: String) async throws {
        services.insert(service)
        values[service + ":" + account] = data
    }
    func delete(service: String, account: String) async throws {
        values[service + ":" + account] = nil
    }
    func corruptSession() { values[KeychainSessionStore.service + ":current"] = Data("invalid".utf8) }
}

@MainActor
final class ManualReceiptUploadScheduler: ReceiptUploadScheduler {
    final class Job: ReceiptUploadCancellation {
        let date: Date
        let operation: @MainActor () async -> Void
        var cancelled = false
        init(date: Date, operation: @escaping @MainActor () async -> Void) {
            self.date = date
            self.operation = operation
        }
        func cancel() { cancelled = true }
    }
    private(set) var jobs: [Job] = []
    func schedule(at date: Date, operation: @escaping @MainActor () async -> Void) -> any ReceiptUploadCancellation {
        let job = Job(date: date, operation: operation)
        jobs.append(job)
        return job
    }
}

@MainActor
func appBackendEventually(_ condition: @MainActor () async throws -> Bool) async throws {
    for _ in 0..<10000 {
        if try await condition() { return }
        await Task.yield()
    }
    throw AppBackendTestFailure.didNotSettle
}

enum AppBackendTestFailure: Error { case didNotSettle }

@MainActor
func appBackendDefaults() -> UserDefaults {
    UserDefaults(suiteName: "EngineerEncounters.Backend.Tests.\(UUID().uuidString)")!
}

@MainActor
func appBackendRuntime(transport: any HTTPTransport, queue: any ReceiptQueue,
                       scheduler: ManualReceiptUploadScheduler, signedIn: Bool = true,
                       clock: ManualEncounterClock = ManualEncounterClock()) throws -> EncounterRuntime {
    let configuration = appBackendTestConfiguration()
    let sessions = SessionManager(configuration: configuration, transport: transport,
        store: InMemorySessionStore(session: try appBackendTestSession()), now: { appBackendTestNow })
    let client = RemoteProcedureClient(configuration: configuration, transport: transport, sessions: sessions)
    let factory: (@MainActor (any ReceiptQueue) -> ReceiptUploader)?
    if signedIn {
        factory = { ReceiptUploader(client: client, queue: $0, schedule: ReceiptRetrySchedule(random: { 0.5 })) }
    } else { factory = nil }
    return EncounterRuntime(tokenIssuer: nil, sessionFlag: { false }, transportFactory: {
        await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
    }, queueOpener: { queue }, tokenStore: InMemoryTokenBatchStore(batch: try EncounterSamples.batch()),
        clock: clock, uploadFactory: factory, uploadScheduler: scheduler)
}

@MainActor
final class AppTestTimeZone {
    var value: String
    init(_ value: String) { self.value = value }
}

func appBackendExpiredSession() throws -> BackendSession {
    try BackendSession(accessCredential: "fixture-access", refreshCredential: "fixture-refresh",
                       expiresAt: appBackendTestNow.addingTimeInterval(-1), userID: appBackendTestUser)
}

func appBackendLongBatch() throws -> TokenBatch {
    try TokenBatch(windows: (0..<16).map { index in
        try TokenWindow(token: EncounterSamples.token(seed: index + 1),
            validFrom: appBackendTestNow.addingTimeInterval(Double(index) * 900),
            validUntil: appBackendTestNow.addingTimeInterval(Double(index + 1) * 900))
    })
}

/// Held requests deliberately ignore cancellation to exercise stale-result fences.
actor ControlledAppBackendTransport: HTTPTransport {
    enum Reply: Sendable {
        case response(HTTPResponse), failure, held
    }
    private var plans: [String: [Reply]]
    private var requests: [URLRequest] = []
    private var held: [(String, CheckedContinuation<HTTPResponse, any Error>)] = []

    init(_ plans: [String: [Reply]]) { self.plans = plans }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let path = request.url!.lastPathComponent
        guard var replies = plans[path], !replies.isEmpty else { throw BackendError.transportFailure }
        let reply = replies.removeFirst()
        plans[path] = replies
        switch reply {
        case .response(let response): return response
        case .failure: throw BackendError.transportFailure
        case .held: return try await withCheckedThrowingContinuation { held.append((path, $0)) }
        }
    }
    func count(_ path: String) -> Int { requests.filter { $0.url?.lastPathComponent == path }.count }
    func recorded() -> [URLRequest] { requests }
    func isHeld(_ path: String) -> Bool { held.contains { $0.0 == path } }
    func release(_ path: String, with response: HTTPResponse) {
        guard let index = held.firstIndex(where: { $0.0 == path }) else { return }
        held.remove(at: index).1.resume(returning: response)
    }
}

actor FailingAppSessionStore: SessionStore {
    private(set) var stored: BackendSession?
    private var failLoad: Bool
    private var failSave: Bool
    private var failClear: Bool
    private(set) var operations: [String] = []

    init(session: BackendSession? = nil, failLoad: Bool = false, failSave: Bool = false, failClear: Bool = false) {
        stored = session
        self.failLoad = failLoad
        self.failSave = failSave
        self.failClear = failClear
    }
    func load() async throws -> BackendSession? {
        operations.append("load")
        if failLoad { throw BackendError.storageFailure }
        return stored
    }
    func save(_ session: BackendSession) async throws {
        operations.append("save")
        if failSave { throw BackendError.storageFailure }
        stored = session
    }
    func clear() async throws {
        operations.append("clear")
        if failClear { throw BackendError.storageFailure }
        stored = nil
    }
    func recover() { failLoad = false; failSave = false; failClear = false }
}

actor FailingAppTokenStore: TokenBatchStore {
    private var batch: TokenBatch?
    private var failClear = false
    private(set) var reads = 0
    init(batch: TokenBatch? = nil) { self.batch = batch }
    func load() async throws -> TokenBatch? { reads += 1; return batch }
    func save(_ batch: TokenBatch) async throws { self.batch = batch }
    func clear() async throws {
        if failClear { throw BackendError.storageFailure }
        batch = nil
    }
    func setClearFailure(_ value: Bool) { failClear = value }
}

actor FailingAppReceiptQueue: ReceiptQueue {
    private let queue = InMemoryReceiptQueue()
    private var failClear = false
    private(set) var reads = 0
    func enqueue(_ receipt: EncounterReceipt) async throws { try await queue.enqueue(receipt) }
    func update(_ receipt: EncounterReceipt) async throws { try await queue.update(receipt) }
    func pending() async throws -> [EncounterReceipt] { reads += 1; return try await queue.pending() }
    func acknowledge(_ id: UUID) async throws { try await queue.acknowledge(id) }
    func removeExpired(asOf time: Date) async throws { try await queue.removeExpired(asOf: time) }
    func removeAll() async throws {
        if failClear { throw BackendError.storageFailure }
        try await queue.removeAll()
    }
    func setClearFailure(_ value: Bool) { failClear = value }
}

actor RetryingAppTokenIssuer: TokenIssuer {
    private let store: any TokenBatchStore
    private var failures: Int
    private(set) var attempts = 0
    init(store: any TokenBatchStore, failures: Int) { self.store = store; self.failures = failures }
    func replenish(at now: Date) async throws {
        attempts += 1
        if failures > 0 { failures -= 1; throw BackendError.transportFailure }
        let window = try TokenWindow(token: EncounterSamples.token(seed: 987),
            validFrom: now, validUntil: now.addingTimeInterval(900))
        try await store.save(TokenBatch(windows: [window]))
    }
}
