import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class SessionRecoveryTests: XCTestCase {
    func testRestoreFailuresKeepServerStorageAndRetryOnRefresh() async throws {
        let failures: [ControlledAppBackendTransport.Reply] = [
            .failure, .response(HTTPResponse(data: Data(), statusCode: 503)),
            .response(HTTPResponse(data: Data(), statusCode: 401)),
            .response(HTTPResponse(data: Data("invalid".utf8), statusCode: 200))
        ]
        for failure in failures {
            let transport = ControlledAppBackendTransport([
                "token": [failure, .response(appBackendAuthResponse())],
                "register_time_zone": [.response(appAccountOK())]
            ])
            let sessions = InMemorySessionStore(session: try appBackendExpiredSession())
            let server = InMemoryTokenBatchStore(batch: try appBackendLongBatch())
            let queue = InMemoryReceiptQueue()
            let receipt = EncounterSamples.receipt()
            try await queue.enqueue(receipt)
            let composition = makeRecoveryComposition(transport: transport, sessions: sessions, tokens: server, queue: queue)
            await composition.waitForRestoration()
            XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
            XCTAssertTrue(composition.account.state.isSignedIn)
            XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
            let restored = try await sessions.load()
            let retained = try await server.load()
            let pending = try await queue.pending()
            XCTAssertNotNil(restored)
            XCTAssertNotNil(retained)
            XCTAssertEqual(pending, [receipt])
            await composition.refresh()
            XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
            let attempts = await transport.count("token")
            XCTAssertEqual(attempts, 2)
        }
    }

    func testStorageFailureAtLaunchStaysPendingWithoutNetworkOrLocalTestTokens() async throws {
        let transport = ControlledAppBackendTransport(["register_time_zone": [.response(appAccountOK())]])
        let sessions = FailingAppSessionStore(session: try appBackendTestSession(), failLoad: true)
        let composition = makeRecoveryComposition(transport: transport, sessions: sessions)
        await composition.waitForRestoration()
        XCTAssertEqual(composition.account.state, .signedInPending(nil))
        XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
        let requests = await transport.recorded()
        XCTAssertTrue(requests.isEmpty)
        await sessions.recover()
        await composition.refresh()
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
    }

    func testDeadSessionAtLaunchAndOnRefreshUseIdenticalCleanup() async throws {
        for atLaunch in [true, false] {
            let transport = ControlledAppBackendTransport([
                "token": [.response(HTTPResponse(data: Data(#"{"error":"invalid_grant"}"#.utf8), statusCode: 400))],
                "register_time_zone": [.response(appAccountOK())]
            ])
            let session = atLaunch ? try appBackendExpiredSession() : try appBackendTestSession()
            let sessions = InMemorySessionStore(session: session)
            let tokens = InMemoryTokenBatchStore(batch: try appBackendLongBatch())
            let queue = InMemoryReceiptQueue()
            if atLaunch { try await queue.enqueue(EncounterSamples.receipt()) }
            let composition = makeRecoveryComposition(transport: transport, sessions: sessions, tokens: tokens, queue: queue)
            if !atLaunch {
                await composition.waitForRestoration()
                // Force an expiry without advancing the engine's clock.
                _ = try? await composition.account.sessions?.refresh()
            }
            await composition.waitForRestoration()
            if !atLaunch {
                try await queue.enqueue(EncounterSamples.receipt())
                await composition.refresh()
            }
            XCTAssertEqual(composition.account.state, .signedOut)
            let stored = try await sessions.load()
            let batch = try await tokens.load()
            let pending = try await queue.pending()
            XCTAssertNil(stored)
            XCTAssertNil(batch)
            XCTAssertTrue(pending.isEmpty)
            #if DEVELOPMENT_BUILD
            if let runtime = composition.runtime { XCTAssertTrue(runtime.tokenIssuer is LocalTestTokenIssuer) }
            #else
            XCTAssertNil(composition.runtime?.tokenIssuer)
            #endif
        }
    }

    func testLaunchStartsFromStoredTokensAndCanStopWhileSessionRefreshIsHeld() async throws {
        let transport = ControlledAppBackendTransport([
            "token": [.held], "register_time_zone": [.response(appAccountOK())]
        ])
        let defaults = appBackendDefaults()
        ParticipationFlag(defaults: defaults).isEnabled = true
        let composition = makeRecoveryComposition(transport: transport,
            sessions: InMemorySessionStore(session: try appBackendExpiredSession()),
            tokens: InMemoryTokenBatchStore(batch: try appBackendLongBatch()), defaults: defaults)
        try await appBackendEventually {
            let held = await transport.isHeld("token")
            return composition.status.discoveryOn && held
        }
        XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
        let stopping = Task { await composition.setParticipation(false) }
        var stopped = false
        let completion = Task { await stopping.value; stopped = true }
        try await appBackendEventually { stopped }
        XCTAssertFalse(composition.status.discoveryOn)
        XCTAssertFalse(composition.isParticipating)
        let refreshHeld = await transport.isHeld("token")
        XCTAssertTrue(refreshHeld)
        await transport.release("token", with: appBackendAuthResponse())
        await composition.waitForRestoration()
        await completion.value
        XCTAssertFalse(composition.status.discoveryOn)
    }

    func testSignInIsRefusedBeforeIOWhileAnotherAccountIsPresent() async throws {
        let other = UUID()
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())], "signin": [.held]
        ])
        let sessions = InMemorySessionStore(session: try appBackendTestSession(userID: other))
        let tokens = InMemoryTokenBatchStore(batch: try appBackendLongBatch())
        let queue = InMemoryReceiptQueue()
        let composition = makeRecoveryComposition(transport: transport, sessions: sessions, tokens: tokens, queue: queue,
            defaults: appBackendDefaults(userID: other))
        await composition.waitForRestoration()
        let oldRuntime = composition.runtime
        let receipt = EncounterSamples.receipt()
        try await queue.enqueue(receipt)
        do { try await recoverySignIn(composition); XCTFail("A present session must refuse sign-in") }
        catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        let before = try await sessions.load()
        let retainedTokens = try await tokens.load()
        let retainedReceipts = try await queue.pending()
        XCTAssertEqual(before?.userID, other)
        XCTAssertNotNil(retainedTokens)
        XCTAssertEqual(retainedReceipts, [receipt])
        XCTAssertTrue(composition.runtime === oldRuntime)
        let signInCalls = await transport.count("signin")
        XCTAssertEqual(signInCalls, 0)
        XCTAssertEqual(composition.account.state, .signedIn(other))
        XCTAssertTrue(composition.runtime === oldRuntime)
        let after = try await sessions.load()
        XCTAssertEqual(after?.userID, other)
    }

    func testSignOutSupersedesAHeldProviderRequestWithoutWaitingForIt() async throws {
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())], "signin": [.held]
        ])
        let sessions = InMemorySessionStore()
        let composition = makeRecoveryComposition(transport: transport, sessions: sessions)
        await composition.waitForRestoration()
        let signingIn = Task { try await recoverySignIn(composition) }
        try await appBackendEventually { await transport.isHeld("signin") }
        var signedOut = false
        let signingOut = Task { try await composition.account.signOut(); signedOut = true }
        try await appBackendEventually { signedOut }
        await transport.release("signin", with: appBackendAuthResponse())
        do { try await signingIn.value; XCTFail("An obsolete provider request cannot establish the current account") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        try await signingOut.value
        let stored = try await sessions.load()
        let declarations = await transport.count("accept_declarations")
        XCTAssertNil(stored)
        XCTAssertEqual(declarations, 0)
        XCTAssertEqual(composition.account.state, .signedOut)
    }

    func testDeclarationAndTimeZoneFailuresRetryWithoutDiscardingEstablishedSession() async throws {
        for failedCall in ["accept_declarations", "register_time_zone"] {
            let transport = ControlledAppBackendTransport([
                "signin": [.response(appBackendAuthResponse())],
                "accept_declarations": failedCall == "accept_declarations" ? [.failure, .response(appAccountOK())] : [.response(appAccountOK())],
                "register_time_zone": failedCall == "register_time_zone" ? [.failure, .response(appAccountOK())] : [.response(appAccountOK())]
            ])
            let sessions = InMemorySessionStore()
            let queue = InMemoryReceiptQueue()
            let composition = makeRecoveryComposition(transport: transport, sessions: sessions, queue: queue)
            await composition.waitForRestoration()
            // A signed-out Development trial's evidence must not survive sign-in.
            try await queue.enqueue(appBackendFinalReceipt())
            do { try await recoverySignIn(composition); XCTFail("Setup failure must surface") }
            catch { XCTAssertEqual(error as? BackendError, .transportFailure) }
            XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
            XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
            let stored = try await sessions.load()
            let pending = try await queue.pending()
            XCTAssertNotNil(stored)
            XCTAssertTrue(pending.isEmpty)
            await composition.refresh()
            XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
            let declarations = await transport.count("accept_declarations")
            let zones = await transport.count("register_time_zone")
            let uploads = await transport.count("submit_receipts")
            XCTAssertEqual(declarations, failedCall == "accept_declarations" ? 2 : 1)
            XCTAssertEqual(zones, failedCall == "register_time_zone" ? 2 : 1)
            XCTAssertEqual(uploads, 0)
        }
    }

    func testRuntimeStartsBeforeDeclarationsAndSignOutDoesNotWaitForHeldSetup() async throws {
        let transport = ControlledAppBackendTransport(["signin": [.response(appBackendAuthResponse())],
            "accept_declarations": [.held]])
        let defaults = appBackendDefaults()
        ParticipationFlag(defaults: defaults).isEnabled = true
        let composition = makeRecoveryComposition(transport: transport, sessions: InMemorySessionStore(), defaults: defaults)
        await composition.waitForRestoration()
        let oldRuntime = composition.runtime
        let signingIn = Task { try await recoverySignIn(composition) }
        try await appBackendEventually {
            let held = await transport.isHeld("accept_declarations")
            return held && composition.status.radioAvailability != .unknown
        }
        XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
        XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
        XCTAssertFalse(composition.runtime === oldRuntime)
        XCTAssertNotEqual(composition.status.radioAvailability, .unknown)
        var signedOut = false
        let signingOut = Task { try await composition.account.signOut(); signedOut = true }
        try await appBackendEventually { signedOut }
        let declarationsHeld = await transport.isHeld("accept_declarations")
        XCTAssertTrue(declarationsHeld)
        await transport.release("accept_declarations", with: appAccountOK())
        do { try await signingIn.value; XCTFail("An obsolete sign-in must not publish its account") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        try await signingOut.value
        XCTAssertEqual(composition.account.state, .signedOut)
        let zones = await transport.count("register_time_zone")
        XCTAssertEqual(zones, 0)
        await composition.setParticipation(false)
    }

    func testSignOutStorageFailuresAlwaysRecreateAndReleaseTheChangeGuard() async throws {
        for failingStore in ["tokens", "receipts", "session"] {
            let transport = ControlledAppBackendTransport(["register_time_zone": [.response(appAccountOK())]])
            let sessions = FailingAppSessionStore(session: try appBackendTestSession(), failClear: failingStore == "session")
            let tokens = FailingAppTokenStore(batch: try appBackendLongBatch())
            let queue = FailingAppReceiptQueue()
            let composition = makeRecoveryComposition(transport: transport, sessions: sessions, tokens: tokens, queue: queue)
            await composition.waitForRestoration()
            let oldRuntime = composition.runtime
            try await queue.enqueue(EncounterSamples.receipt())
            await tokens.setClearFailure(failingStore == "tokens")
            await queue.setClearFailure(failingStore == "receipts")
            do { try await composition.account.signOut(); XCTFail("Persistence failure must surface") }
            catch { XCTAssertEqual(error as? BackendError, .storageFailure) }
            XCTAssertEqual(composition.account.state, .signedOut)
            XCTAssertFalse(composition.runtime === oldRuntime)
            await composition.refreshLocalSummary()
            XCTAssertNotNil(composition.status.pendingReceiptCount)
            try await composition.requestBluetooth()
            do { _ = try await composition.account.sessions?.session(); XCTFail("The actual manager must be signed out") }
            catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
            #if DEVELOPMENT_BUILD
            XCTAssertTrue(composition.runtime?.tokenIssuer is LocalTestTokenIssuer)
            #else
            XCTAssertNil(composition.runtime?.tokenIssuer)
            #endif
        }
    }

    func testSignInCleanupFailureRetainsSignedOutStateAndFreshPersistenceFailureKeepsNewAccount() async throws {
        for failingStore in ["tokens", "receipts", "clearSession", "saveSession"] {
            let transport = ControlledAppBackendTransport(["register_time_zone": [.response(appAccountOK()), .response(appAccountOK())],
                "signin": [.response(appBackendAuthResponse())], "accept_declarations": [.response(appAccountOK())]])
            let sessions = FailingAppSessionStore(
                failSave: failingStore == "saveSession", failClear: failingStore == "clearSession")
            let tokens = FailingAppTokenStore(batch: try appBackendLongBatch())
            let queue = FailingAppReceiptQueue()
            let composition = makeRecoveryComposition(transport: transport, sessions: sessions, tokens: tokens, queue: queue)
            await composition.waitForRestoration()
            let oldRuntime = composition.runtime
            await tokens.setClearFailure(failingStore == "tokens")
            await queue.setClearFailure(failingStore == "receipts")
            do { try await recoverySignIn(composition); XCTFail("Storage failure must surface") }
            catch { XCTAssertEqual(error as? BackendError, .storageFailure) }
            if ["tokens", "receipts", "clearSession"].contains(failingStore) {
                XCTAssertEqual(composition.account.state, .signedOut)
                do { _ = try await composition.account.sessions?.session(); XCTFail("Cleanup failure must retain signed-out storage") }
                catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
            } else {
                XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
                let actualSession = try await composition.account.sessions?.session()
                XCTAssertEqual(actualSession?.userID, appBackendTestUser)
                XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
            }
            if failingStore == "clearSession" {
                let signIns = await transport.count("signin")
                XCTAssertEqual(signIns, 0)
            } else { XCTAssertFalse(composition.runtime === oldRuntime) }
            await composition.refreshLocalSummary()
            XCTAssertNotNil(composition.status.pendingReceiptCount)
            try await composition.requestBluetooth()
        }
    }
}

@MainActor
private func makeRecoveryComposition(transport: any HTTPTransport, sessions: any SessionStore,
    tokens: any TokenBatchStore = InMemoryTokenBatchStore(), queue: any ReceiptQueue = InMemoryReceiptQueue(),
    defaults: UserDefaults? = nil) -> AppComposition {
    let clock = ManualEncounterClock()
    return AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults ?? appBackendDefaults(),
        transport: transport, keychain: AppMemoryKeychain(), sessionStore: sessions, serverTokenStore: tokens,
        signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { queue }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow }, timeZone: { "Asia/Tokyo" })
}

@MainActor
private func recoverySignIn(_ composition: AppComposition) async throws {
    try await composition.account.signIn(using: AuthRequest(path: "signin", body: Data()),
        isAdult: true, acceptsTermsAndPrivacy: true, termsVersion: "fixture-terms", privacyVersion: "fixture-privacy")
}
