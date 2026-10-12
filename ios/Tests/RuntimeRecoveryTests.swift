import Combine
import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class RuntimeRecoveryTests: XCTestCase {
    func testStopCompletesDuringHeldUploadAndUploadCanFinishWithParticipationOff() async throws {
        let receipt = appBackendFinalReceipt()
        let queue = InMemoryReceiptQueue()
        try await queue.enqueue(receipt)
        let transport = ControlledAppBackendTransport(["submit_receipts": [.held]])
        let runtime = try appBackendRuntime(transport: transport, queue: queue, scheduler: ManualReceiptUploadScheduler())
        await runtime.start()
        try await appBackendEventually { await transport.isHeld("submit_receipts") }
        let uploading = try XCTUnwrap(runtime.uploadTask)
        var stopped = false
        let stopping = Task { await runtime.stop(); stopped = true }
        try await appBackendEventually { stopped }
        XCTAssertFalse(runtime.status.discoveryOn)
        let held = await transport.isHeld("submit_receipts")
        XCTAssertTrue(held)
        let response = try JSONEncoder().encode([ReceiptStatusTransfer(id: receipt.id, status: .resolved)])
        await transport.release("submit_receipts", with: HTTPResponse(data: response, statusCode: 200))
        await uploading.value
        await stopping.value
        let pending = try await queue.pending()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(runtime.status.pendingReceiptCount, 0)
        XCTAssertFalse(runtime.status.discoveryOn)
        await runtime.invalidateForAccountChange()
    }

    func testSignOutCompletesDuringHeldUploadAndLateAcknowledgementCannotTouchNewReceipts() async throws {
        let queue = InMemoryReceiptQueue()
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())], "submit_receipts": [.held]
        ])
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(),
            transport: transport, keychain: AppMemoryKeychain(), sessionStore: InMemorySessionStore(session: try appBackendTestSession()),
            serverTokenStore: InMemoryTokenBatchStore(), signedOutTokenStore: InMemoryTokenBatchStore(),
            queueOpener: { queue }, now: { appBackendTestNow })
        await composition.waitForRestoration()
        let receipt = appBackendFinalReceipt()
        try await queue.enqueue(receipt)
        let oldRuntime = try XCTUnwrap(composition.runtime)
        await oldRuntime.refresh()
        try await appBackendEventually { await transport.isHeld("submit_receipts") }
        let uploading = try XCTUnwrap(oldRuntime.uploadTask)
        var signedOut = false
        let signingOut = Task { try await composition.account.signOut(); signedOut = true }
        try await appBackendEventually { signedOut }
        XCTAssertEqual(composition.account.state, .signedOut)
        let cleared = try await queue.pending()
        XCTAssertTrue(cleared.isEmpty)
        // Reusing the ID proves the late acknowledgement is fenced, not merely idempotent.
        try await queue.enqueue(receipt)
        let response = try JSONEncoder().encode([ReceiptStatusTransfer(id: receipt.id, status: .resolved)])
        await transport.release("submit_receipts", with: HTTPResponse(data: response, statusCode: 200))
        await uploading.value
        XCTAssertEqual(oldRuntime.backendFailure, .notAuthenticated)
        try await signingOut.value
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [receipt])
        XCTAssertFalse(composition.runtime === oldRuntime)
    }

    func testAccountSwitchInvalidatesHeldTokenRequestBeforeClearingAndOldResultCannotRefill() async throws {
        let other = UUID()
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK()), .response(appAccountOK())],
            "issue_token_batch": [.held], "signin": [.response(appBackendAuthResponse(userID: other))],
            "accept_declarations": [.response(appAccountOK())]
        ])
        let tokens = InMemoryTokenBatchStore()
        let sessions = InMemorySessionStore(session: try appBackendTestSession())
        let queue = InMemoryReceiptQueue()
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(),
            transport: transport, keychain: AppMemoryKeychain(), sessionStore: sessions, serverTokenStore: tokens,
            signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { queue }, now: { appBackendTestNow })
        await composition.waitForRestoration()
        let oldRuntime = try XCTUnwrap(composition.runtime)
        let issuer = try XCTUnwrap(oldRuntime.tokenIssuer)
        let issuing = Task { try await issuer.replenish(at: appBackendTestNow) }
        try await appBackendEventually { await transport.isHeld("issue_token_batch") }
        try await queue.enqueue(EncounterSamples.receipt())
        var switched = false
        let switching = Task {
            try await composition.account.signOut()
            XCTAssertEqual(composition.account.state, .signedOut)
            try await composition.account.signIn(using: AuthRequest(path: "signin", body: Data()),
                isAdult: true, acceptsTermsAndPrivacy: true, termsVersion: "fixture", privacyVersion: "fixture")
            switched = true
        }
        try await appBackendEventually { switched }
        XCTAssertEqual(composition.account.state, .signedIn(other))
        XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
        let held = await transport.isHeld("issue_token_batch")
        XCTAssertTrue(held)
        let cleared = try await queue.pending()
        XCTAssertTrue(cleared.isEmpty)
        let batch = try JSONEncoder().encode(TokenBatchTransfer(batchID: appBackendTestUser, batch: appBackendLongBatch()))
        await transport.release("issue_token_batch", with: HTTPResponse(data: batch, statusCode: 200))
        try await issuing.value
        try await switching.value
        let retained = try await tokens.load()
        let stored = try await sessions.load()
        XCTAssertNil(retained)
        XCTAssertEqual(stored?.userID, other)
    }

    func testStopAndSignOutCompleteDuringRuntimeTokenReplenishment() async throws {
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())], "issue_token_batch": [.held]
        ])
        let tokens = InMemoryTokenBatchStore()
        let clock = ManualEncounterClock()
        let defaults = appBackendDefaults()
        ParticipationFlag(defaults: defaults).isEnabled = true
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults,
            transport: transport, keychain: AppMemoryKeychain(), sessionStore: InMemorySessionStore(session: try appBackendTestSession()),
            serverTokenStore: tokens, signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { InMemoryReceiptQueue() },
            transportFactory: { await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock) },
            clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow })
        await composition.waitForRestoration()
        try await appBackendEventually { await transport.isHeld("issue_token_batch") }
        let runtime = try XCTUnwrap(composition.runtime)
        let replenishing = try XCTUnwrap(runtime.tokenTopUpTask)
        var stopped = false
        let stopping = Task { await composition.setParticipation(false); stopped = true }
        try await appBackendEventually { stopped }
        var signedOut = false
        let signingOut = Task { try await composition.account.signOut(); signedOut = true }
        try await appBackendEventually { signedOut }
        let held = await transport.isHeld("issue_token_batch")
        XCTAssertTrue(held)
        XCTAssertFalse(composition.status.discoveryOn)
        let batch = try JSONEncoder().encode(TokenBatchTransfer(batchID: appBackendTestUser, batch: appBackendLongBatch()))
        await transport.release("issue_token_batch", with: HTTPResponse(data: batch, statusCode: 200))
        await replenishing.value
        XCTAssertEqual(runtime.backendFailure, .notAuthenticated)
        await stopping.value
        try await signingOut.value
        let retained = try await tokens.load()
        XCTAssertNil(retained)
        XCTAssertEqual(composition.account.state, .signedOut)
    }

    func testBackendPreflightDefersUploadsAndTokensUntilTheScheduledRetryIsReady() async throws {
        let receipt = appBackendFinalReceipt()
        let queue = InMemoryReceiptQueue()
        try await queue.enqueue(receipt)
        let batchResponse = try JSONEncoder().encode(TokenBatchTransfer(batchID: appBackendTestUser, batch: appBackendLongBatch()))
        let acknowledgement = try JSONEncoder().encode([ReceiptStatusTransfer(id: receipt.id, status: .resolved)])
        let transport = ControlledAppBackendTransport([
            "issue_token_batch": [.response(HTTPResponse(data: batchResponse, statusCode: 200))],
            "submit_receipts": [.response(HTTPResponse(data: acknowledgement, statusCode: 200))]
        ])
        let configuration = appBackendTestConfiguration()
        let sessions = SessionManager(configuration: configuration, transport: transport,
            store: InMemorySessionStore(session: try appBackendTestSession()), now: { appBackendTestNow })
        let client = RemoteProcedureClient(configuration: configuration, transport: transport, sessions: sessions)
        let tokens = InMemoryTokenBatchStore()
        let clock = ManualEncounterClock()
        let scheduler = ManualReceiptUploadScheduler()
        let ready = BackendReadiness()
        let runtime = EncounterRuntime(tokenIssuer: ServerTokenIssuer(client: client, store: tokens), sessionFlag: { false },
            transportFactory: { await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock) },
            queueOpener: { queue }, tokenStore: tokens, clock: clock,
            uploadFactory: { ReceiptUploader(client: client, queue: $0) }, uploadScheduler: scheduler,
            canCallBackend: { ready.value })
        await runtime.start()
        try await appBackendEventually { scheduler.jobs.filter { !$0.cancelled }.count >= 2 }
        let before = await transport.recorded()
        XCTAssertTrue(before.isEmpty)
        let retained = try await queue.pending()
        XCTAssertEqual(retained, [receipt])
        let retries = scheduler.jobs.filter { !$0.cancelled }
        ready.value = true
        await clock.advance(by: 5)
        for retry in retries { await retry.operation() }
        try await appBackendEventually {
            let pending = try await queue.pending()
            return runtime.status.validTokenAvailable && pending.isEmpty
        }
        let uploads = await transport.count("submit_receipts")
        let tokenCalls = await transport.count("issue_token_batch")
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(tokenCalls, 1)
        await runtime.invalidateForAccountChange()
    }

    func testTokenRetriesGrowToBoundThenStopWhenSchedulerDeliversAToken() async throws {
        let clock = ManualEncounterClock()
        let tokens = InMemoryTokenBatchStore()
        let issuer = RetryingAppTokenIssuer(store: tokens, failures: 10)
        let scheduler = ManualReceiptUploadScheduler()
        let runtime = EncounterRuntime(tokenIssuer: issuer, sessionFlag: { false }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, queueOpener: { InMemoryReceiptQueue() }, tokenStore: tokens, clock: clock, uploadScheduler: scheduler)
        await runtime.start()
        let expectedDelays: [TimeInterval] = [5, 10, 20, 40, 80, 160, 320, 640, 900, 900]
        for (index, delay) in expectedDelays.enumerated() {
            try await appBackendEventually { scheduler.jobs.count == index + 1 }
            let job = scheduler.jobs[index]
            let now = await clock.now()
            XCTAssertEqual(job.date.timeIntervalSince(now.wall), delay)
            XCTAssertTrue(runtime.status.pausedForLackOfToken)
            let attempts = await issuer.attempts
            XCTAssertEqual(attempts, index + 1)
            // Events and an explicit foreground trigger cannot bypass the scheduled delay.
            runtime.receive(.participationPausedForLackOfToken)
            await runtime.refresh()
            let unchanged = await issuer.attempts
            XCTAssertEqual(unchanged, attempts)
            await clock.advance(by: delay)
            await job.operation()
            XCTAssertTrue(job.cancelled)
        }
        try await appBackendEventually { runtime.status.discoveryOn && runtime.status.validTokenAvailable }
        XCTAssertFalse(runtime.status.pausedForLackOfToken)
        XCTAssertEqual(scheduler.jobs.count, expectedDelays.count)
        await runtime.stop()
    }

    func testRetryStopsWithoutAnotherRequestWhenAStoredTokenBecomesAvailable() async throws {
        let clock = ManualEncounterClock()
        let tokens = InMemoryTokenBatchStore()
        let issuer = RetryingAppTokenIssuer(store: tokens, failures: 2)
        let scheduler = ManualReceiptUploadScheduler()
        let runtime = EncounterRuntime(tokenIssuer: issuer, sessionFlag: { false }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, queueOpener: { InMemoryReceiptQueue() }, tokenStore: tokens, clock: clock, uploadScheduler: scheduler)
        await runtime.start()
        try await appBackendEventually { !scheduler.jobs.isEmpty }
        try await tokens.save(appBackendLongBatch())
        await scheduler.jobs[0].operation()
        try await appBackendEventually { runtime.status.discoveryOn && runtime.status.validTokenAvailable }
        let attempts = await issuer.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(scheduler.jobs.count, 1)
        await runtime.stop()
    }

    func testAccountChangeCancelsScheduledTokenRetryEvenIfCallbackIsAlreadyDequeued() async throws {
        let clock = ManualEncounterClock()
        let tokens = InMemoryTokenBatchStore()
        let issuer = RetryingAppTokenIssuer(store: tokens, failures: 2)
        let scheduler = ManualReceiptUploadScheduler()
        let runtime = EncounterRuntime(tokenIssuer: issuer, sessionFlag: { false }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, queueOpener: { InMemoryReceiptQueue() }, tokenStore: tokens, clock: clock, uploadScheduler: scheduler)
        await runtime.start()
        try await appBackendEventually { !scheduler.jobs.isEmpty }
        let job = scheduler.jobs[0]
        await runtime.invalidateForAccountChange()
        XCTAssertTrue(job.cancelled)
        await job.operation()
        await runtime.start()
        let attempts = await issuer.attempts
        XCTAssertEqual(attempts, 1)
    }

    #if DEVELOPMENT_BUILD
    func testUnavailableBackendRetainsLocalTokenStartupWithoutAnInitialTokenPause() async throws {
        let clock = ManualEncounterClock()
        let defaults = appBackendDefaults()
        ParticipationFlag(defaults: defaults).isEnabled = true
        let transport = AppBackendTransport()
        let composition = AppComposition(configuration: nil, defaults: defaults, transport: transport,
            keychain: AppMemoryKeychain(), signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { InMemoryReceiptQueue() }, transportFactory: {
                await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
            }, clock: clock)
        var pauses = 0
        let subscription = composition.$runtime.sink { runtime in
            runtime?.observeEvents { event in
                if case .participationPausedForLackOfToken = event { pauses += 1 }
            }
        }
        await composition.waitForRestoration()
        try await appBackendEventually { composition.status.discoveryOn }
        XCTAssertEqual(composition.account.state, .unavailable)
        XCTAssertTrue(composition.runtime?.tokenIssuer is LocalTestTokenIssuer)
        XCTAssertEqual(pauses, 0)
        let requests = await transport.recorded()
        XCTAssertTrue(requests.isEmpty)
        await composition.setParticipation(false)
        withExtendedLifetime(subscription) {}
    }
    #endif

    func testUnavailableBackendAndParticipationOffRefreshDoesNotReadStorage() async throws {
        let queue = FailingAppReceiptQueue()
        let tokens = FailingAppTokenStore()
        var opens = 0
        var builds = 0
        let composition = AppComposition(configuration: nil, defaults: appBackendDefaults(),
            keychain: AppMemoryKeychain(), signedOutTokenStore: tokens, queueOpener: { opens += 1; return queue }, transportFactory: {
                builds += 1
                return await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: ManualEncounterClock())
            })
        await composition.waitForRestoration()
        await composition.refresh()
        XCTAssertNil(composition.runtime)
        // Once a local summary created the runtime, refresh still has the original early return.
        await composition.refreshLocalSummary()
        let queueReads = await queue.reads
        let tokenReads = await tokens.reads
        await composition.refresh()
        let queueReadsAfter = await queue.reads
        let tokenReadsAfter = await tokens.reads
        XCTAssertEqual(queueReadsAfter, queueReads)
        XCTAssertEqual(tokenReadsAfter, tokenReads)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(builds, 0)
        XCTAssertEqual(composition.account.state, .unavailable)
    }
}

@MainActor
private final class BackendReadiness {
    var value = false
}
