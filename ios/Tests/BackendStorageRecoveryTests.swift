import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class BackendStorageRecoveryTests: XCTestCase {
    func testCanonicalBackendIdentityAndAccountNamespaces() throws {
        let first = try XCTUnwrap(BackendConfiguration(address: "HTTPS://Backend.Example/path/", publicClientKey: "fixture-key"))
        let equivalent = try XCTUnwrap(BackendConfiguration(address: "https://backend.example:443", publicClientKey: "different-key"))
        let different = try XCTUnwrap(BackendConfiguration(address: "https://backend.example:8443", publicClientKey: "fixture-key"))
        let identity = BackendStorageBinding.identity(first)
        XCTAssertEqual(identity, "https://backend.example:443")
        XCTAssertEqual(identity, BackendStorageBinding.identity(equivalent))
        XCTAssertNotEqual(identity, BackendStorageBinding.identity(different))
        let owner = BackendStorageOwner(backend: identity, account: appBackendTestUser)
        XCTAssertEqual(owner.namespace, BackendStorageOwner(backend: BackendStorageBinding.identity(equivalent), account: appBackendTestUser).namespace)
        XCTAssertNotEqual(owner.namespace, BackendStorageOwner(backend: identity, account: UUID()).namespace)
        XCTAssertNotEqual(owner.namespace, BackendStorageOwner(backend: BackendStorageBinding.identity(different), account: appBackendTestUser).namespace)
        XCTAssertFalse(owner.namespace.contains(appBackendTestUser.uuidString))
    }

    func testUnavailableKeychainQuarantinesRuntimeAndRefreshRetriesBindingAfterRecovery() async throws {
        for sessionInKeychain in [false, true] {
            let defaults = appBackendDefaults()
            ParticipationFlag(defaults: defaults).isEnabled = true
            let configuration = appBackendTestConfiguration()
            let keychain = AppMemoryKeychain()
            let session = try appBackendTestSession()
            let persisted = KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(configuration), client: keychain)
            try await persisted.save(session)
            let owner = BackendStorageOwner(backend: BackendStorageBinding.identity(configuration), account: session.userID)
            let tokens = KeychainTokenBatchStore(service: AppComposition.serverTokenService(owner: owner), client: keychain)
            try await tokens.save(appBackendLongBatch())
            let legacy = KeychainTokenBatchStore(service: AppComposition.serverTokenService, client: keychain)
            try await legacy.save(appBackendLongBatch())
            let queue = InMemoryReceiptQueue()
            let receipt = appBackendFinalReceipt()
            try await queue.enqueue(receipt)
            let acknowledgement = try JSONEncoder().encode([ReceiptStatusTransfer(id: receipt.id, status: .resolved)])
            let transport = ControlledAppBackendTransport([
                "register_time_zone": [.response(appAccountOK())],
                "submit_receipts": [.response(HTTPResponse(data: acknowledgement, statusCode: 200))]
            ])
            let clock = ManualEncounterClock()
            var queueOpens = 0
            var radioBuilds = 0
            await keychain.setUnavailable(true)
            let composition = AppComposition(configuration: configuration, defaults: defaults, transport: transport,
                keychain: keychain, sessionStore: sessionInKeychain ? nil : InMemorySessionStore(session: session),
                queueOpener: { queueOpens += 1; return queue }, transportFactory: {
                    radioBuilds += 1
                    return await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
                }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow })
            await composition.waitForRestoration()
            let isolated = try XCTUnwrap(composition.runtime)
            XCTAssertEqual(composition.account.state, .signedInPending(sessionInKeychain ? nil : session.userID))
            XCTAssertNil(isolated.tokenIssuer)
            XCTAssertNil(isolated.uploadTask)
            XCTAssertTrue(composition.status.storageUnavailable)
            XCTAssertFalse(composition.status.validTokenAvailable)
            XCTAssertFalse(composition.status.discoveryOn)
            XCTAssertEqual(queueOpens, 0)
            XCTAssertEqual(radioBuilds, 0)
            let failedAttempts = await keychain.deletionAttempts
            XCTAssertGreaterThan(failedAttempts, 0)
            await composition.refresh()
            let retryAttempts = await keychain.deletionAttempts
            let requestsWhileUnavailable = await transport.recorded()
            XCTAssertGreaterThan(retryAttempts, failedAttempts)
            XCTAssertTrue(requestsWhileUnavailable.isEmpty)
            XCTAssertFalse(composition.status.validTokenAvailable)
            XCTAssertTrue(composition.status.storageUnavailable)
            XCTAssertEqual(queueOpens, 0)
            XCTAssertEqual(radioBuilds, 0)
            await keychain.setUnavailable(false)
            await composition.refresh()
            XCTAssertEqual(composition.account.state, .signedIn(session.userID))
            XCTAssertFalse(composition.runtime === isolated)
            XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
            XCTAssertFalse(composition.status.storageUnavailable)
            XCTAssertTrue(composition.status.validTokenAvailable)
            XCTAssertEqual(queueOpens, 1)
            XCTAssertEqual(radioBuilds, 1)
            try await appBackendEventually { try await queue.pending().isEmpty }
            let uploads = await transport.count("submit_receipts")
            let tokenRequests = await transport.count("issue_token_batch")
            let retained = try await tokens.load()
            let quarantined = try await legacy.load()
            XCTAssertEqual(uploads, 1)
            XCTAssertEqual(tokenRequests, 0)
            XCTAssertNotNil(retained)
            XCTAssertNil(quarantined)
            await composition.setParticipation(false)
        }
    }

    func testHeldAccountSetupAfterBackendReplacementReportsNotAuthenticated() async throws {
        let defaults = appBackendDefaults()
        let keychain = AppMemoryKeychain()
        let oldTransport = ControlledAppBackendTransport([
            "signin": [.response(appBackendAuthResponse())], "accept_declarations": [.held]
        ])
        let first = storageComposition(configuration: appBackendTestConfiguration(), defaults: defaults,
            keychain: keychain, transport: oldTransport, queue: InMemoryReceiptQueue())
        await first.waitForRestoration()
        let signingIn = Task { try await storageSignIn(first) }
        try await appBackendEventually { await oldTransport.isHeld("accept_declarations") }
        let other = try XCTUnwrap(BackendConfiguration(address: "https://other.example", publicClientKey: "fixture-key"))
        let restarted = storageComposition(configuration: other, defaults: defaults, keychain: keychain,
            transport: ControlledAppBackendTransport([:]), queue: InMemoryReceiptQueue())
        await restarted.waitForRestoration()
        await oldTransport.release("accept_declarations", with: appAccountOK())
        do { try await signingIn.value; XCTFail("An obsolete backend cannot publish its account") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        XCTAssertEqual(restarted.account.state, .signedOut)
        let stored = try await KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(other), client: keychain).load()
        let zones = await oldTransport.count("register_time_zone")
        XCTAssertNil(stored)
        XCTAssertEqual(zones, 0)
    }

    func testFailedDeletionStaysSignedOutAcrossRestartBlocksSignInAndRetriesUntilSuccess() async throws {
        let defaults = appBackendDefaults()
        let keychain = AppMemoryKeychain()
        let configuration = appBackendTestConfiguration()
        let persisted = KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(configuration), client: keychain)
        try await persisted.save(appBackendTestSession())
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK()), .response(appAccountOK()), .response(appAccountOK())],
            "signin": [.response(appBackendAuthResponse())], "accept_declarations": [.response(appAccountOK())]
        ])
        let tokens = InMemoryTokenBatchStore(batch: try appBackendLongBatch())
        let queue = InMemoryReceiptQueue()
        let first = storageComposition(configuration: configuration, defaults: defaults, keychain: keychain,
            transport: transport, tokens: tokens, queue: queue)
        await first.waitForRestoration()
        await keychain.setSessionDeletionFailure(true)
        do { try await first.account.signOut(); XCTFail("Failed deletion must surface") }
        catch { XCTAssertEqual(error as? BackendError, .storageFailure) }
        XCTAssertEqual(first.account.state, .signedOut)
        XCTAssertEqual(defaults.object(forKey: SessionCleanupMarker.key) as? Bool, true)
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        XCTAssertTrue(first.account.sessionCleanupFailed)
        #endif
        let surviving = try await persisted.load()
        XCTAssertEqual(surviving?.userID, appBackendTestUser)
        let requestsBeforeRestart = await transport.recorded().count
        let writesBeforeRestart = await keychain.sessionWrites
        let attemptsBeforeRestart = await keychain.sessionDeletionAttempts
        let restarted = storageComposition(configuration: configuration, defaults: defaults, keychain: keychain,
            transport: transport, tokens: tokens, queue: queue)
        await restarted.waitForRestoration()
        XCTAssertEqual(restarted.account.state, .signedOut)
        XCTAssertNil(restarted.account.profile)
        do { _ = try await restarted.account.loadOwnProfile(); XCTFail("A quarantined account cannot load its profile") }
        catch { XCTAssertEqual((error as? EncounterUI.ProfileActionError)?.code, .notAuthenticated) }
        do { try await storageSignIn(restarted); XCTFail("Pending deletion must refuse sign-in") }
        catch { XCTAssertEqual(error as? BackendError, .storageFailure) }
        await restarted.refresh()
        let requestsDuringCleanup = await transport.recorded().count
        let writesDuringCleanup = await keychain.sessionWrites
        let retryAttempts = await keychain.sessionDeletionAttempts
        XCTAssertEqual(requestsDuringCleanup, requestsBeforeRestart)
        XCTAssertEqual(writesDuringCleanup, writesBeforeRestart)
        XCTAssertGreaterThanOrEqual(retryAttempts, attemptsBeforeRestart + 2)
        XCTAssertTrue(restarted.account.sessionCleanupFailed)
        await keychain.setSessionDeletionFailure(false)
        await restarted.refresh()
        XCTAssertFalse(restarted.account.sessionCleanupPending)
        XCTAssertFalse(restarted.account.sessionCleanupFailed)
        XCTAssertNil(defaults.object(forKey: SessionCleanupMarker.key))
        let deleted = try await persisted.load()
        XCTAssertNil(deleted)
        try await storageSignIn(restarted)
        XCTAssertEqual(restarted.account.state, .signedIn(appBackendTestUser))
        let secondRestart = storageComposition(configuration: configuration, defaults: defaults, keychain: keychain,
            transport: transport, tokens: tokens, queue: queue)
        await secondRestart.waitForRestoration()
        XCTAssertEqual(secondRestart.account.state, .signedIn(appBackendTestUser))
    }

    func testInvalidRefreshRecordsCleanupEvenWhenManagerDeletionFails() async throws {
        let defaults = appBackendDefaults()
        let keychain = AppMemoryKeychain()
        let configuration = appBackendTestConfiguration()
        let persisted = KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(configuration), client: keychain)
        try await persisted.save(appBackendExpiredSession())
        await keychain.setSessionDeletionFailure(true)
        let transport = ControlledAppBackendTransport(["token": [.response(HTTPResponse(
            data: Data(#"{"error":"invalid_grant"}"#.utf8), statusCode: 400))]])
        let queue = InMemoryReceiptQueue()
        let first = storageComposition(configuration: configuration, defaults: defaults, keychain: keychain,
            transport: transport, queue: queue)
        await first.waitForRestoration()
        XCTAssertEqual(first.account.state, .signedOut)
        XCTAssertTrue(first.account.sessionCleanupPending)
        let second = storageComposition(configuration: configuration, defaults: defaults, keychain: keychain,
            transport: transport, queue: queue)
        await second.waitForRestoration()
        XCTAssertEqual(second.account.state, .signedOut)
        let refreshes = await transport.count("token")
        XCTAssertEqual(refreshes, 1)
    }

    func testOtherBackendAndLegacySessionsAreDeletedBeforeRequestsOrRadio() async throws {
        for legacy in [false, true] {
            let defaults = appBackendDefaults(bound: !legacy)
            let keychain = AppMemoryKeychain()
            let original = appBackendTestConfiguration()
            let other = try XCTUnwrap(BackendConfiguration(address: "https://other.example", publicClientKey: "fixture-key"))
            if legacy {
                let session = try appBackendTestSession()
                let data = try JSONEncoder().encode(LegacySession(session))
                try await keychain.writeOrReplace(data, service: KeychainSessionStore.service, account: "current")
            } else {
                try await KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(original), client: keychain).save(appBackendTestSession())
            }
            let owner = BackendStorageOwner(backend: BackendStorageBinding.identity(original), account: appBackendTestUser)
            let tokenService = legacy ? AppComposition.serverTokenService : AppComposition.serverTokenService(owner: owner)
            let tokens = KeychainTokenBatchStore(service: tokenService, client: keychain)
            try await tokens.save(appBackendLongBatch())
            let earlierTokens = KeychainTokenBatchStore(client: keychain)
            try await earlierTokens.save(appBackendLongBatch())
            let queue = InMemoryReceiptQueue()
            try await queue.enqueue(appBackendFinalReceipt())
            let transport = ControlledAppBackendTransport([:])
            let composition = storageComposition(configuration: legacy ? original : other, defaults: defaults,
                keychain: keychain, transport: transport, queue: queue)
            await composition.waitForRestoration()
            XCTAssertEqual(composition.account.state, .signedOut)
            let stored = try await keychain.read(service: KeychainSessionStore.service, account: "current")
            let batch = try await tokens.load()
            let earlierBatch = try await earlierTokens.load()
            let pending = try await queue.pending()
            let requests = await transport.recorded()
            XCTAssertNil(stored)
            XCTAssertNil(batch)
            XCTAssertNil(earlierBatch)
            XCTAssertTrue(pending.isEmpty)
            XCTAssertTrue(requests.isEmpty)
            XCTAssertNil(composition.runtime)
            await composition.setParticipation(true)
            let serverRequests = await transport.recorded()
            XCTAssertTrue(serverRequests.isEmpty)
            await composition.setParticipation(false)
            let restarted = storageComposition(configuration: original, defaults: defaults, keychain: keychain,
                transport: transport, queue: queue)
            await restarted.waitForRestoration()
            XCTAssertEqual(restarted.account.state, .signedOut)
        }
    }

    func testSessionEnvelopeRejectsOtherBackendAndLegacyEvenWithACurrentSidecar() async throws {
        for legacy in [false, true] {
            let defaults = appBackendDefaults()
            let keychain = AppMemoryKeychain()
            let configuration = appBackendTestConfiguration()
            if legacy {
                try await keychain.writeOrReplace(JSONEncoder().encode(LegacySession(appBackendTestSession())),
                    service: KeychainSessionStore.service, account: "current")
            } else {
                try await KeychainSessionStore(backendIdentity: "https://other.example:443", client: keychain).save(appBackendTestSession())
            }
            let transport = ControlledAppBackendTransport([:])
            let composition = storageComposition(configuration: configuration, defaults: defaults, keychain: keychain,
                transport: transport, queue: InMemoryReceiptQueue())
            await composition.waitForRestoration()
            let stored = try await keychain.read(service: KeychainSessionStore.service, account: "current")
            let requests = await transport.recorded()
            XCTAssertEqual(composition.account.state, .signedOut)
            XCTAssertNil(stored)
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testUnboundAndOtherAccountTokensAndReceiptsArePurgedBeforeAuthenticatedIOAndRadio() async throws {
        for unbound in [true, false] {
            let defaults = appBackendDefaults(userID: unbound ? appBackendTestUser : UUID())
            if unbound { defaults.removeObject(forKey: BackendStorageBinding.ownerKey) }
            let keychain = AppMemoryKeychain()
            let configuration = appBackendTestConfiguration()
            try await KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(configuration), client: keychain).save(appBackendTestSession())
            let tokens = InMemoryTokenBatchStore(batch: try appBackendLongBatch())
            let queue = InMemoryReceiptQueue()
            try await queue.enqueue(appBackendFinalReceipt())
            let transport = StorageBoundaryTransport(tokens: tokens, queue: queue)
            ParticipationFlag(defaults: defaults).isEnabled = true
            var radioSawCleanStorage = false
            let clock = ManualEncounterClock()
            let composition = AppComposition(configuration: configuration, defaults: defaults, transport: transport,
                keychain: keychain, serverTokenStore: tokens, signedOutTokenStore: InMemoryTokenBatchStore(),
                queueOpener: { queue }, transportFactory: {
                    let batch = try? await tokens.load()
                    let pending = try? await queue.pending()
                    radioSawCleanStorage = batch == nil && pending?.isEmpty == true
                    return await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
                }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow })
            await composition.waitForRestoration()
            XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
            XCTAssertTrue(radioSawCleanStorage)
            let crossedWithOldStorage = await transport.crossedWithOldStorage
            XCTAssertFalse(crossedWithOldStorage)
            let pending = try await queue.pending()
            XCTAssertTrue(pending.isEmpty)
            await composition.setParticipation(false)
        }
    }

    func testHeldSessionTokenAndUploadResultsCannotCrossABackendRestart() async throws {
        let defaults = appBackendDefaults()
        let keychain = AppMemoryKeychain()
        let original = appBackendTestConfiguration()
        let other = try XCTUnwrap(BackendConfiguration(address: "https://other.example:8443", publicClientKey: "fixture-key"))
        try await KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(original), client: keychain).save(appBackendTestSession())
        let queue = InMemoryReceiptQueue()
        let oldTransport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())], "issue_token_batch": [.held],
            "submit_receipts": [.held], "token": [.held]
        ])
        let first = storageComposition(configuration: original, defaults: defaults, keychain: keychain,
            transport: oldTransport, queue: queue)
        await first.waitForRestoration()
        let oldRuntime = try XCTUnwrap(first.runtime)
        let issuer = try XCTUnwrap(oldRuntime.tokenIssuer)
        let issuing = Task { try await issuer.replenish(at: appBackendTestNow) }
        try await appBackendEventually { await oldTransport.isHeld("issue_token_batch") }
        let receipt = appBackendFinalReceipt()
        try await queue.enqueue(receipt)
        await oldRuntime.refresh()
        try await appBackendEventually { await oldTransport.isHeld("submit_receipts") }
        let uploading = try XCTUnwrap(oldRuntime.uploadTask)
        let refreshing = Task { try await first.account.sessions?.refresh() }
        try await appBackendEventually { await oldTransport.isHeld("token") }
        let newUser = UUID()
        let newTransport = ControlledAppBackendTransport([
            "signin": [.response(appBackendAuthResponse(userID: newUser))],
            "accept_declarations": [.response(appAccountOK())], "register_time_zone": [.response(appAccountOK())]
        ])
        let restarted = storageComposition(configuration: other, defaults: defaults, keychain: keychain,
            transport: newTransport, queue: queue)
        await restarted.waitForRestoration()
        XCTAssertEqual(restarted.account.state, .signedOut)
        try await storageSignIn(restarted)
        try await queue.enqueue(receipt) // Reuse the ID to detect an obsolete acknowledgement.
        let newOwner = BackendStorageOwner(backend: BackendStorageBinding.identity(other), account: newUser)
        let newTokens = KeychainTokenBatchStore(service: AppComposition.serverTokenService(owner: newOwner), client: keychain)
        let newBatch = try appBackendLongBatch()
        try await newTokens.save(newBatch)
        let batchResponse = try JSONEncoder().encode(TokenBatchTransfer(batchID: appBackendTestUser, batch: EncounterSamples.batch()))
        let acknowledgement = try JSONEncoder().encode([ReceiptStatusTransfer(id: receipt.id, status: .resolved)])
        await oldTransport.release("issue_token_batch", with: HTTPResponse(data: batchResponse, statusCode: 200))
        await oldTransport.release("submit_receipts", with: HTTPResponse(data: acknowledgement, statusCode: 200))
        await oldTransport.release("token", with: appBackendAuthResponse())
        _ = await issuing.result
        _ = await refreshing.result
        await uploading.value
        let stored = try await KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(other), client: keychain).load()
        let oldOwner = BackendStorageOwner(backend: BackendStorageBinding.identity(original), account: appBackendTestUser)
        let oldTokens = try await KeychainTokenBatchStore(service: AppComposition.serverTokenService(owner: oldOwner), client: keychain).load()
        let retained = try await newTokens.load()
        let pending = try await queue.pending()
        XCTAssertEqual(stored?.userID, newUser)
        XCTAssertNil(oldTokens)
        XCTAssertEqual(retained, newBatch)
        XCTAssertEqual(pending, [receipt])
        XCTAssertEqual(restarted.account.state, .signedIn(newUser))
        XCTAssertFalse(restarted.account.sessionCleanupPending)
        await oldRuntime.invalidateForAccountChange()
    }
}

private struct LegacySession: Encodable {
    let accessCredential: String
    let refreshCredential: String
    let expiresAt: Date
    let userID: UUID
    init(_ session: BackendSession) {
        accessCredential = session.accessCredential
        refreshCredential = session.refreshCredential
        expiresAt = session.expiresAt
        userID = session.userID
    }
}

private actor StorageBoundaryTransport: HTTPTransport {
    let tokens: any TokenBatchStore
    let queue: any ReceiptQueue
    private(set) var crossedWithOldStorage = false
    init(tokens: any TokenBatchStore, queue: any ReceiptQueue) { self.tokens = tokens; self.queue = queue }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let batch = try await tokens.load()
        let pending = try await queue.pending()
        if batch != nil || !pending.isEmpty { crossedWithOldStorage = true }
        if request.url?.lastPathComponent == "register_time_zone" { return appAccountOK() }
        throw BackendError.transportFailure
    }
}

@MainActor
private func storageComposition(configuration: BackendConfiguration, defaults: UserDefaults,
    keychain: any KeychainClient, transport: any HTTPTransport, tokens: (any TokenBatchStore)? = nil,
    queue: any ReceiptQueue) -> AppComposition {
    let clock = ManualEncounterClock()
    return AppComposition(configuration: configuration, defaults: defaults, transport: transport, keychain: keychain,
        serverTokenStore: tokens, signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { queue }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow }, timeZone: { "Asia/Tokyo" })
}

@MainActor
private func storageSignIn(_ composition: AppComposition) async throws {
    try await composition.account.signIn(using: AuthRequest(path: "signin", body: Data()), isAdult: true,
        acceptsTermsAndPrivacy: true, termsVersion: "fixture", privacyVersion: "fixture")
}
