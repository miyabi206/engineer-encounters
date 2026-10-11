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

func appBackendTestSession() throws -> BackendSession {
    try BackendSession(accessCredential: "fixture-access", refreshCredential: "fixture-refresh",
                       expiresAt: appBackendTestNow.addingTimeInterval(3600), userID: appBackendTestUser)
}

func appBackendAuthResponse() -> HTTPResponse {
    HTTPResponse(data: Data("""
    {"access_token":"fixture-access","refresh_token":"fixture-refresh","token_type":"bearer",
     "expires_in":3600,"user":{"id":"\(appBackendTestUser.uuidString)"}}
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
func appBackendRuntime(transport: AppBackendTransport, queue: any ReceiptQueue,
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
