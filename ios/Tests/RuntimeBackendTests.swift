import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class RuntimeBackendTests: XCTestCase {
    func testStartRefreshExchangeAndEvidenceEachTriggerUploadAndReplaceRetry() async throws {
        let queue = InMemoryReceiptQueue()
        try await queue.enqueue(appBackendFinalReceipt())
        let transport = AppBackendTransport(Array(repeating: HTTPResponse(data: Data("[]".utf8), statusCode: 200), count: 4))
        let scheduler = ManualReceiptUploadScheduler()
        let runtime = try appBackendRuntime(transport: transport, queue: queue, scheduler: scheduler)
        await runtime.start()
        try await appBackendEventually { scheduler.jobs.count == 1 }
        XCTAssertEqual(scheduler.jobs[0].date, appBackendTestNow.addingTimeInterval(5))
        await runtime.refresh()
        try await appBackendEventually { scheduler.jobs.count == 2 }
        XCTAssertTrue(scheduler.jobs[0].cancelled)
        runtime.receive(.exchangeCompleted(role: .central, nonceDigest: "fixture-digest"))
        try await appBackendEventually { scheduler.jobs.count == 3 }
        runtime.receive(.evidenceReached(role: .central, nonceDigest: "fixture-digest", observedDuration: 120))
        try await appBackendEventually { scheduler.jobs.count == 4 }
        let requests = await transport.recorded()
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, Array(repeating: "submit_receipts", count: 4))
        await runtime.invalidateForAccountChange()
    }

    func testOutcomeTimeDrivesScheduledRetryWithoutSleepingAndTerminalResultEndsSchedule() async throws {
        let queue = InMemoryReceiptQueue()
        let receipt = appBackendFinalReceipt()
        try await queue.enqueue(receipt)
        let candidate = try JSONEncoder().encode([ReceiptStatusTransfer(id: receipt.id, status: .candidate)])
        let resolved = try JSONEncoder().encode([ReceiptStatusTransfer(id: receipt.id, status: .resolved)])
        let transport = AppBackendTransport([HTTPResponse(data: candidate, statusCode: 200),
                                             HTTPResponse(data: resolved, statusCode: 200)])
        let scheduler = ManualReceiptUploadScheduler()
        let clock = ManualEncounterClock()
        let runtime = try appBackendRuntime(transport: transport, queue: queue, scheduler: scheduler, clock: clock)
        // Foreground retry also works when the local radio participation switch is off.
        await runtime.refresh()
        try await appBackendEventually { !scheduler.jobs.isEmpty }
        let job = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(job.date, appBackendTestNow.addingTimeInterval(5))
        let candidateQueue = try await queue.pending()
        XCTAssertEqual(candidateQueue.first?.uploadStatus, .acceptedAsCandidate)
        await clock.advance(by: job.date.timeIntervalSince(appBackendTestNow))
        await job.operation()
        try await appBackendEventually { runtime.status.pendingReceiptCount == 0 }
        let pending = try await queue.pending()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertTrue(job.cancelled)
        XCTAssertEqual(runtime.status.pendingReceiptCount, 0)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 2)
        await runtime.invalidateForAccountChange()
    }

    func testRetryableFailureUsesOutcomeTimeAndCancelledCallbacksCannotRunAfterAccountChange() async throws {
        let queue = InMemoryReceiptQueue()
        try await queue.enqueue(appBackendFinalReceipt())
        let transport = AppBackendTransport([HTTPResponse(data: Data(), statusCode: 503)])
        let scheduler = ManualReceiptUploadScheduler()
        let runtime = try appBackendRuntime(transport: transport, queue: queue, scheduler: scheduler)
        await runtime.refresh()
        try await appBackendEventually { !scheduler.jobs.isEmpty }
        let job = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(job.date, appBackendTestNow.addingTimeInterval(5))
        await runtime.invalidateForAccountChange()
        XCTAssertTrue(job.cancelled)
        // Deliberately deliver an already dequeued callback despite cancellation.
        await job.operation()
        await runtime.start()
        await runtime.refresh()
        runtime.receive(.exchangeCompleted(role: .central, nonceDigest: "fixture-digest"))
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testSignedOutNeverUploadsOrSchedulesForAnyTrigger() async throws {
        let queue = InMemoryReceiptQueue()
        let transport = AppBackendTransport(Array(repeating: HTTPResponse(data: Data("[]".utf8), statusCode: 200), count: 4))
        let scheduler = ManualReceiptUploadScheduler()
        let clock = ManualEncounterClock()
        // Wire the real composition and backend. The application, rather than this test,
        // must decide that a signed-out runtime has no upload route.
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(), notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
            transport: transport, keychain: AppMemoryKeychain(), sessionStore: InMemorySessionStore(),
            serverTokenStore: InMemoryTokenBatchStore(), signedOutTokenStore: InMemoryTokenBatchStore(),
            queueOpener: { queue }, transportFactory: {
                await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
            }, clock: clock, uploadScheduler: scheduler, now: { appBackendTestNow })
        await composition.waitForRestoration()
        XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertNotNil(composition.account.service)
        try await queue.enqueue(appBackendFinalReceipt())
        await composition.setParticipation(true)
        let runtime = try XCTUnwrap(composition.runtime)
        await runtime.refresh()
        runtime.receive(.exchangeCompleted(role: .central, nonceDigest: "fixture-digest"))
        runtime.receive(.evidenceReached(role: .central, nonceDigest: "fixture-digest", observedDuration: 120))
        await runtime.refreshLocalSummary()
        await composition.setParticipation(false)
        await runtime.invalidateForAccountChange()
        let requests = await transport.recorded()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        // Positive control: the same wired transport and queue do upload for a live account.
        let signedIn = try appBackendRuntime(transport: transport, queue: queue, scheduler: scheduler)
        await signedIn.refresh()
        try await appBackendEventually { !(await transport.recorded()).isEmpty }
        let controlRequests = await transport.recorded()
        XCTAssertEqual(controlRequests.map { $0.url?.lastPathComponent }, ["submit_receipts"])
        await signedIn.invalidateForAccountChange()
    }

    func testInjectedSessionFlagReachesEngineReceipts() async throws {
        let clock = ManualEncounterClock()
        let link = FakeBluetoothLink()
        let transport = await FakeBluetoothTransport(phone: .first, link: link, clock: clock)
        let peerTransport = await FakeBluetoothTransport(phone: .second, link: link, clock: clock)
        let queue = InMemoryReceiptQueue()
        let peerWindow = try TokenWindow(token: EncounterSamples.token(seed: 999),
            validFrom: appBackendTestNow, validUntil: appBackendTestNow.addingTimeInterval(900))
        let peer = EncounterEngine(transport: peerTransport,
            tokenProvider: TokenProvider(store: InMemoryTokenBatchStore(batch: try TokenBatch(windows: [peerWindow]))),
            receiptQueue: InMemoryReceiptQueue(), clock: clock, sessionFlag: { false })
        let runtime = EncounterRuntime(tokenIssuer: nil, sessionFlag: { true }, transportFactory: { transport },
            queueOpener: { queue }, tokenStore: InMemoryTokenBatchStore(batch: try EncounterSamples.batch()), clock: clock)
        await link.setObservations(to: .second, enabled: false)
        await peer.start()
        try await appBackendEventually {
            let idle = await peer.isIdle
            let commands = await peerTransport.commands()
            return idle && commands.contains(.startDiscovery)
        }
        await runtime.start()
        try await appBackendEventually { try await queue.pending().first?.sessionFlag == true }
        await runtime.stop()
        await peer.stop()
    }

    func testSignOutAwaitsIssuerSaveBeforeClearingTokensAndReceipts() async throws {
        let batch = try JSONEncoder().encode(TokenBatchTransfer(batchID: appBackendTestUser, batch: EncounterSamples.batch()))
        let transport = AppBackendTransport([HTTPResponse(data: Data(), statusCode: 204),
                                             HTTPResponse(data: batch, statusCode: 200)])
        let store = HeldAppTokenStore()
        let queue = InMemoryReceiptQueue()
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(), notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
            transport: transport, keychain: AppMemoryKeychain(), sessionStore: InMemorySessionStore(session: try appBackendTestSession()),
            serverTokenStore: store, queueOpener: { queue },
            // The next ordered reply belongs to the held token issue, not an activation get.
            productLifecycle: ProductSceneLifecycle(phase: .background, notifications: NotificationCenter()),
            now: { appBackendTestNow })
        await composition.waitForRestoration()
        let oldRuntime = try XCTUnwrap(composition.runtime)
        let issuer = try XCTUnwrap(oldRuntime.tokenIssuer)
        let issuing = Task { try await issuer.replenish(at: appBackendTestNow) }
        try await appBackendEventually { await store.saveStarted }
        try await queue.enqueue(EncounterSamples.receipt())
        let prepare = composition.account.prepareForSessionChange
        var preparing = false
        composition.account.prepareForSessionChange = {
            preparing = true
            try await prepare()
        }
        let signingOut = Task { try await composition.account.signOut() }
        // The callback suspends the old runtime synchronously before awaiting issuer invalidation.
        try await appBackendEventually { preparing }
        let before = await store.operations
        XCTAssertEqual(before, ["saveStarted"])
        let stillPending = try await queue.pending()
        XCTAssertEqual(stillPending.count, 1)
        await store.releaseSave()
        try await issuing.value
        try await signingOut.value
        let after = await store.operations
        let tokens = try await store.load()
        let pending = try await queue.pending()
        XCTAssertEqual(after, ["saveStarted", "saveFinished", "clear"])
        XCTAssertNil(tokens)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertFalse(oldRuntime === composition.runtime)
        #if DEVELOPMENT_BUILD
        XCTAssertTrue(composition.runtime?.tokenIssuer is LocalTestTokenIssuer)
        #else
        XCTAssertNil(composition.runtime?.tokenIssuer)
        #endif
    }
}

private actor HeldAppTokenStore: TokenBatchStore {
    private var batch: TokenBatch?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var saveStarted = false
    private(set) var operations: [String] = []
    func load() async throws -> TokenBatch? { batch }
    func save(_ batch: TokenBatch) async throws {
        operations.append("saveStarted")
        saveStarted = true
        await withCheckedContinuation { continuation = $0 }
        operations.append("saveFinished")
        self.batch = batch
    }
    func clear() async throws { operations.append("clear"); batch = nil }
    func releaseSave() { continuation?.resume(); continuation = nil }
}
