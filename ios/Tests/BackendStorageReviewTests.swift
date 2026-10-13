import CryptoKit
import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class BackendStorageReviewTests: XCTestCase {
    func testLockedMatchingSessionWithEmptyOrUnreadablePreferencesNeverStartsDeletion() async throws {
        for unreadable in [false, true] {
            let defaults = ReviewDefaults(suiteName: "EngineerEncounters.Review.\(UUID())")!
            defaults.setReadable(!unreadable)
            let keychain = AppMemoryKeychain()
            let configuration = appBackendTestConfiguration()
            let store = KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(configuration), client: keychain)
            try await store.save(appBackendTestSession())
            await keychain.setUnavailable(true, deleteMissingAsSuccess: true)
            let transport = ControlledAppBackendTransport(["register_time_zone": [.response(appAccountOK())]])
            let composition = reviewComposition(defaults: defaults, keychain: keychain, transport: transport)
            await composition.waitForRestoration()
            XCTAssertEqual(composition.account.state, .signedInPending(nil))
            XCTAssertTrue(composition.status.storageUnavailable)
            XCTAssertFalse(composition.account.sessionCleanupPending)
            do { _ = try await composition.account.loadOwnProfile(); XCTFail("Unprepared storage must refuse screen requests") }
            catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .unavailable)) }
            do { _ = try await composition.account.profileActions { .available }.saveInterests(["fixture"]); XCTFail("Must preflight actions") }
            catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .unavailable)) }
            let runtime = try XCTUnwrap(composition.runtime)
            var exchanges = 0
            runtime.observeEvents { if case .exchangeCompleted = $0 { exchanges += 1 } }
            runtime.receive(.exchangeCompleted(role: .central, nonceDigest: "fixture"))
            XCTAssertEqual(exchanges, 0)
            await composition.refresh()
            let deletes = await keychain.deletionAttempts
            let requests = await transport.recorded()
            XCTAssertEqual(deletes, 0)
            XCTAssertTrue(requests.isEmpty)
            defaults.setReadable(true)
            await keychain.setUnavailable(false)
            await composition.refresh()
            XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
            XCTAssertFalse(composition.status.storageUnavailable)
            XCTAssertFalse(composition.runtime === runtime)
            let retained = try await store.load()
            let credentialDeletes = await keychain.sessionDeletionAttempts
            XCTAssertEqual(retained?.userID, appBackendTestUser)
            XCTAssertEqual(credentialDeletes, 0)
            XCTAssertNil(defaults.object(forKey: "encounter.backend.storageLease"))
        }
    }

    func testUnreadablePreferencesWithReadableOrAbsentSessionHaveNoDestructiveStep() async throws {
        for hasSession in [false, true] {
            let defaults = ReviewDefaults(suiteName: "EngineerEncounters.Review.\(UUID())")!
            let keychain = AppMemoryKeychain()
            let store = KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(appBackendTestConfiguration()), client: keychain)
            if hasSession { try await store.save(appBackendTestSession()) }
            defaults.setReadable(false)
            let transport = ControlledAppBackendTransport(["register_time_zone": [.response(appAccountOK())]])
            let composition = reviewComposition(defaults: defaults, keychain: keychain, transport: transport)
            await composition.waitForRestoration()
            XCTAssertEqual(composition.account.state, hasSession ? .signedInPending(appBackendTestUser) : .signedOut)
            XCTAssertTrue(composition.status.storageUnavailable)
            let deletes = await keychain.deletionAttempts
            let requests = await transport.recorded()
            XCTAssertEqual(deletes, 0)
            XCTAssertTrue(requests.isEmpty)
            defaults.setReadable(true)
            await composition.refresh()
            XCTAssertEqual(composition.account.state, hasSession ? .signedIn(appBackendTestUser) : .signedOut)
            let credentialDeletes = await keychain.sessionDeletionAttempts
            XCTAssertEqual(credentialDeletes, 0)
        }
    }

    func testStalePreferenceHintsCannotRejectMatchingKeychainEnvelope() async throws {
        let defaults = appBackendDefaults(userID: UUID())
        defaults.set("https://obsolete.example:443", forKey: BackendStorageBinding.sessionBackendKey)
        let keychain = AppMemoryKeychain()
        let store = KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(appBackendTestConfiguration()), client: keychain)
        try await store.save(appBackendTestSession())
        let composition = reviewComposition(defaults: defaults, keychain: keychain,
            transport: ControlledAppBackendTransport(["register_time_zone": [.response(appAccountOK())]]))
        await composition.waitForRestoration()
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        let deletes = await keychain.sessionDeletionAttempts
        XCTAssertEqual(deletes, 0)
        XCTAssertFalse(composition.account.sessionCleanupPending)
    }

    func testSuccessfulMissingItemDeleteDoesNotProveKeychainAvailability() async throws {
        let keychain = AppMemoryKeychain()
        await keychain.setUnavailable(true, deleteMissingAsSuccess: true)
        // This deliberately matches the system client's not-found-as-success contract.
        try await keychain.delete(service: AppComposition.serverTokenService, account: "current")
        let before = await keychain.deletionAttempts
        let transport = ControlledAppBackendTransport([:])
        let composition = reviewComposition(defaults: appBackendDefaults(), keychain: keychain, transport: transport,
            sessionStore: InMemorySessionStore(session: try appBackendTestSession()))
        await composition.waitForRestoration()
        await composition.refresh()
        XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
        XCTAssertTrue(composition.status.storageUnavailable)
        XCTAssertNil(composition.runtime?.tokenIssuer)
        let after = await keychain.deletionAttempts
        let requests = await transport.recorded()
        XCTAssertEqual(after, before)
        XCTAssertTrue(requests.isEmpty)
    }

    func testAccountStorageNamesUseTheInstallationHMAC() throws {
        let firstDefaults = appBackendDefaults()
        let secondDefaults = appBackendDefaults()
        let salt = try InstallationStorageSalt.load(defaults: firstDefaults)
        let backend = BackendStorageBinding.identity(appBackendTestConfiguration())
        let first = BackendStorageOwner(backend: backend, account: appBackendTestUser, salt: salt)
        let second = BackendStorageOwner(backend: backend, account: appBackendTestUser,
            salt: try InstallationStorageSalt.load(defaults: secondDefaults))
        let expected = HMAC<SHA256>.authenticationCode(for: Data(appBackendTestUser.uuidString.lowercased().utf8),
            using: SymmetricKey(data: salt)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(first.accountDigest, expected)
        XCTAssertNotEqual(first.accountDigest, second.accountDigest)
        XCTAssertNotEqual(first.namespace, second.namespace)
        XCTAssertNotEqual(AppComposition.serverTokenService(owner: first), AppComposition.serverTokenService(owner: second))
        let data = try XCTUnwrap(firstDefaults.data(forKey: BackendStorageBinding.ownerKey))
        XCTAssertEqual(try JSONDecoder().decode(BackendStorageOwner.self, from: data), first)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains(appBackendTestUser.uuidString.lowercased()))
    }

    func testRefreshDuringSignInAndSignOutDoesNotQueueAnotherChange() async throws {
        let defaults = appBackendDefaults(userID: nil)
        let keychain = AppMemoryKeychain()
        let tokens = HeldReviewTokenStore()
        let queue = FailingAppReceiptQueue()
        let transport = ControlledAppBackendTransport([
            "signin": [.response(appBackendAuthResponse())], "accept_declarations": [.response(appAccountOK())],
            "register_time_zone": [.response(appAccountOK())]
        ])
        let composition = reviewComposition(defaults: defaults, keychain: keychain, transport: transport,
            tokens: tokens, queue: queue)
        await composition.waitForRestoration()
        await tokens.holdNextClear()
        let signingIn = Task { try await reviewSignIn(composition) }
        try await appBackendEventually { await tokens.isHeld }
        XCTAssertTrue(composition.account.sessionCleanupPending)
        await composition.account.refresh()
        await composition.refresh()
        await tokens.release()
        try await signingIn.value
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        let signInDeletes = await keychain.sessionDeletionAttempts
        let signInWrites = await keychain.sessionWrites
        XCTAssertEqual(signInDeletes, 1)
        XCTAssertEqual(signInWrites, 1)
        await tokens.holdNextClear()
        let signingOut = Task { try await composition.account.signOut() }
        try await appBackendEventually { await tokens.isHeld }
        await composition.account.refresh()
        await composition.refresh()
        await tokens.release()
        try await signingOut.value
        XCTAssertEqual(composition.account.state, .signedOut)
        let finalDeletes = await keychain.sessionDeletionAttempts
        let clears = await tokens.clears
        XCTAssertEqual(finalDeletes, 2)
        XCTAssertEqual(clears, 2)
        XCTAssertFalse(composition.account.sessionCleanupPending)
    }

    func testGuardCoversBindingPreparationAndAQueuedSignOutCannotLeaveTheEarlierOwner() async throws {
        let defaults = appBackendDefaults(userID: nil)
        let keychain = HeldReviewProbeKeychain()
        let transport = ControlledAppBackendTransport([
            "signin": [.response(appBackendAuthResponse())], "accept_declarations": [.response(appAccountOK())],
            "register_time_zone": [.response(appAccountOK())]
        ])
        let composition = reviewComposition(defaults: defaults, keychain: keychain, transport: transport)
        await composition.waitForRestoration()
        await keychain.holdProbeAfterSave()
        let signingIn = Task { try await reviewSignIn(composition) }
        try await appBackendEventually { await keychain.isHeld }
        XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
        XCTAssertTrue(composition.account.sessionChangeInProgress)
        XCTAssertTrue(composition.status.storageUnavailable)
        let setupCalls = await transport.count("accept_declarations")
        XCTAssertEqual(setupCalls, 0)
        await composition.refresh()
        let writes = await keychain.memory.sessionWrites
        XCTAssertEqual(writes, 1)
        let signingOut = Task { try await composition.account.signOut() }
        await keychain.release()
        _ = await signingIn.result
        try await signingOut.value
        await composition.refresh()
        XCTAssertEqual(composition.account.state, .signedOut)
        let data = try XCTUnwrap(defaults.data(forKey: BackendStorageBinding.ownerKey))
        let owner = try JSONDecoder().decode(BackendStorageOwner.self, from: data)
        XCTAssertNil(owner.accountDigest)
        let stored = try await keychain.read(service: KeychainSessionStore.service, account: "current")
        XCTAssertNil(stored)
    }

    func testSignedOutCleanupRefreshOnlyDeletesCredentialsAndRetainsRuntimeAndReceipts() async throws {
        let defaults = appBackendDefaults()
        let keychain = AppMemoryKeychain()
        try await KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(appBackendTestConfiguration()), client: keychain)
            .save(appBackendTestSession())
        let queue = FailingAppReceiptQueue()
        let tokens = HeldReviewTokenStore()
        let composition = reviewComposition(defaults: defaults, keychain: keychain,
            transport: ControlledAppBackendTransport(["register_time_zone": [.response(appAccountOK())]]), tokens: tokens, queue: queue)
        await composition.waitForRestoration()
        await keychain.setSessionDeletionFailure(true)
        do { try await composition.account.signOut(); XCTFail("Deletion failure must surface") }
        catch { XCTAssertEqual(error as? BackendError, .storageFailure) }
        let runtime = try XCTUnwrap(composition.runtime)
        let receipt = appBackendFinalReceipt()
        try await queue.enqueue(receipt)
        let queueClears = await queue.clears
        let tokenClears = await tokens.clears
        let before = await keychain.sessionDeletionAttempts
        await composition.refresh()
        XCTAssertTrue(composition.account.sessionCleanupFailed)
        await keychain.setSessionDeletionFailure(false)
        await composition.refresh()
        let after = await keychain.sessionDeletionAttempts
        let finalQueueClears = await queue.clears
        let finalTokenClears = await tokens.clears
        let pending = try await queue.pending()
        XCTAssertEqual(after, before + 2)
        XCTAssertEqual(finalQueueClears, queueClears)
        XCTAssertEqual(finalTokenClears, tokenClears)
        XCTAssertEqual(pending, [receipt])
        XCTAssertTrue(composition.runtime === runtime)
        XCTAssertFalse(composition.account.sessionCleanupFailed)
        XCTAssertNil(defaults.object(forKey: SessionCleanupMarker.key))
    }

    func testEveryCredentialDeleteSeesAnAlreadySynchronizedMarker() async throws {
        for path in ["signIn", "signOut", "mismatch", "refresh"] {
            let defaults = ReviewDefaults(suiteName: "EngineerEncounters.Review.\(UUID())")!
            let keychain = AppMemoryKeychain(beforeSessionDeletion: { defaults.markerWasSynchronized })
            let backend = BackendStorageBinding.identity(appBackendTestConfiguration())
            let store = KeychainSessionStore(backendIdentity: path == "mismatch" ? "https://other.example:443" : backend, client: keychain)
            if path != "signIn" { try await store.save(path == "refresh" ? appBackendExpiredSession() : appBackendTestSession()) }
            let transport = ControlledAppBackendTransport([
                "signin": [.response(appBackendAuthResponse())], "accept_declarations": [.response(appAccountOK())],
                "register_time_zone": [.response(appAccountOK())],
                "token": [.response(HTTPResponse(data: Data(#"{"error":"invalid_grant"}"#.utf8), statusCode: 400))]
            ])
            let composition = reviewComposition(defaults: defaults, keychain: keychain, transport: transport)
            await composition.waitForRestoration()
            if path == "signIn" { try await reviewSignIn(composition) }
            if path == "signOut" { try await composition.account.signOut() }
            let checks = await keychain.sessionDeletionMarkerChecks
            XCTAssertFalse(checks.isEmpty, path)
            XCTAssertTrue(checks.allSatisfy { $0 }, path)
        }
    }

    func testProductionBoundQueueOpenerPreservesMatchingReceiptsAndSeparatesTheNextAccount() async throws {
        let defaults = appBackendDefaults()
        let salt = try InstallationStorageSalt.load(defaults: defaults)
        let backend = BackendStorageBinding.identity(appBackendTestConfiguration())
        let owner = BackendStorageOwner(backend: backend, account: appBackendTestUser, salt: salt)
        let queue = try await EncounterRuntime.openBoundQueue(namespace: owner.namespace)
        try await queue.removeAll()
        let receipt = EncounterSamples.receipt(observedAt: Date().addingTimeInterval(60))
        try await queue.enqueue(receipt)
        let keychain = AppMemoryKeychain()
        try await KeychainSessionStore(backendIdentity: backend, client: keychain).save(appBackendTestSession())
        let next = UUID()
        let transport = ControlledAppBackendTransport([
            "signin": [.response(appBackendAuthResponse(userID: next))], "accept_declarations": [.response(appAccountOK())],
            "register_time_zone": [.response(appAccountOK()), .response(appAccountOK())]
        ])
        // Intentionally omit queueOpener: exercise the actual file-backed app path.
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults, notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
            transport: transport, keychain: keychain, signedOutTokenStore: InMemoryTokenBatchStore(),
            uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow })
        await composition.waitForRestoration()
        await composition.refreshLocalSummary()
        XCTAssertEqual(composition.status.pendingReceiptCount, 1)
        let retained = try await queue.pending()
        XCTAssertEqual(retained, [receipt])
        try await composition.account.signOut()
        let cleared = try await queue.pending()
        XCTAssertTrue(cleared.isEmpty)
        try await reviewSignIn(composition)
        let nextOwner = BackendStorageOwner(backend: backend, account: next, salt: salt)
        let nextQueue = try await EncounterRuntime.openBoundQueue(namespace: nextOwner.namespace)
        let nextReceipt = EncounterSamples.receipt(2, observedAt: Date().addingTimeInterval(60))
        try await nextQueue.enqueue(nextReceipt)
        await composition.refreshLocalSummary()
        XCTAssertEqual(composition.status.pendingReceiptCount, 1)
        let oldPending = try await queue.pending()
        XCTAssertTrue(oldPending.isEmpty)
        try await nextQueue.removeAll()
    }

    func testProfilePreflightAndUnchangedCancellationNeverDiscardTheAccount() async throws {
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())], "get_own_profile": [.cancelled]
        ])
        let composition = reviewComposition(defaults: appBackendDefaults(), keychain: AppMemoryKeychain(), transport: transport,
            sessionStore: InMemorySessionStore(session: try appBackendTestSession()))
        await composition.waitForRestoration()
        composition.account.canRefreshSession = { false }
        do { _ = try await composition.account.loadOwnProfile(); XCTFail("Unprepared binding must fail before the service") }
        catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .unavailable)) }
        let refusedRequests = await transport.count("get_own_profile")
        XCTAssertEqual(refusedRequests, 0)
        composition.account.canRefreshSession = { true }
        do { _ = try await composition.account.loadOwnProfile(); XCTFail("Cancellation must be preserved") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        XCTAssertFalse(composition.account.sessionCleanupPending)
    }

    func testHeldProfileAfterBackendReplacementUsesTheSharedNotAuthenticatedMapping() async throws {
        let defaults = appBackendDefaults()
        let keychain = AppMemoryKeychain()
        let store = KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(appBackendTestConfiguration()), client: keychain)
        try await store.save(appBackendTestSession())
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())], "get_own_profile": [.held]
        ])
        let first = reviewComposition(defaults: defaults, keychain: keychain, transport: transport)
        await first.waitForRestoration()
        let reading = Task { try await first.account.loadOwnProfile() }
        try await appBackendEventually { await transport.isHeld("get_own_profile") }
        let other = try XCTUnwrap(BackendConfiguration(address: "https://other.example", publicClientKey: "fixture-key"))
        let replacement = AppComposition(configuration: other, defaults: defaults, notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(), transport: AppBackendTransport(),
            keychain: keychain, signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { InMemoryReceiptQueue() })
        await replacement.waitForRestoration()
        await transport.release("get_own_profile", with: appOwnProfileResponse())
        do { _ = try await reading.value; XCTFail("The obsolete profile must be rejected") }
        catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .notAuthenticated)) }
        XCTAssertNil(first.account.profile)
        XCTAssertEqual(replacement.account.state, .signedOut)
    }

    func testSharedFenceDistinguishesChangedAccountAndBindingFromOrdinaryCancellation() async throws {
        var generation = UUID()
        let epoch = generation
        let fence = BackendCallFence { generation == epoch }
        do { _ = try await fence.call { () async throws -> Void in throw CancellationError() }; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        generation = UUID()
        do { _ = try await fence.call { () async throws -> Void in throw CancellationError() }; XCTFail("Must reject obsolete context") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        do { _ = try await fence.call { 1 }; XCTFail("A successful obsolete result is also fenced") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
    }
}

/// Simulates protected preferences independently of the Keychain, without any sleeps.
private final class ReviewDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var readable = true
    private var synchronizedMarker = false
    var markerWasSynchronized: Bool { lock.withLock { synchronizedMarker } }
    func setReadable(_ value: Bool) { lock.withLock { readable = value } }
    override func synchronize() -> Bool {
        guard lock.withLock({ readable }) else { return false }
        let result = super.synchronize()
        if result, super.bool(forKey: SessionCleanupMarker.key) { lock.withLock { synchronizedMarker = true } }
        return result
    }
    override func set(_ value: Bool, forKey name: String) {
        if name == SessionCleanupMarker.key { lock.withLock { synchronizedMarker = false } }
        super.set(value, forKey: name)
    }
    override func removeObject(forKey name: String) {
        if name == SessionCleanupMarker.key { lock.withLock { synchronizedMarker = false } }
        super.removeObject(forKey: name)
    }
    override func object(forKey name: String) -> Any? {
        guard lock.withLock({ readable }) else { return nil }
        return super.object(forKey: name)
    }
    override func data(forKey name: String) -> Data? {
        guard lock.withLock({ readable }) else { return nil }
        return super.data(forKey: name)
    }
}

private actor HeldReviewTokenStore: TokenBatchStore {
    private var batch: TokenBatch?
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var clears = 0
    var isHeld: Bool { continuation != nil }
    func load() async throws -> TokenBatch? { batch }
    func save(_ batch: TokenBatch) async throws { self.batch = batch }
    func holdNextClear() { hold = true }
    func clear() async throws {
        clears += 1
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        batch = nil
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor HeldReviewProbeKeychain: KeychainClient {
    let memory = AppMemoryKeychain()
    private var holdAfterSave = false
    private var holdRead = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { continuation != nil }
    func holdProbeAfterSave() { holdAfterSave = true }
    func read(service: String, account: String) async throws -> Data? {
        if holdRead, service == KeychainSessionStore.service {
            holdRead = false
            await withCheckedContinuation { continuation = $0 }
        }
        return try await memory.read(service: service, account: account)
    }
    func writeOrReplace(_ data: Data, service: String, account: String) async throws {
        try await memory.writeOrReplace(data, service: service, account: account)
        if holdAfterSave, service == KeychainSessionStore.service { holdRead = true; holdAfterSave = false }
    }
    func delete(service: String, account: String) async throws { try await memory.delete(service: service, account: account) }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private func reviewComposition(defaults: UserDefaults, keychain: any KeychainClient, transport: any HTTPTransport,
    sessionStore: (any SessionStore)? = nil, tokens: any TokenBatchStore = InMemoryTokenBatchStore(),
    queue: any ReceiptQueue = InMemoryReceiptQueue()) -> AppComposition {
    let clock = ManualEncounterClock()
    return AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults, notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(), transport: transport,
        keychain: keychain, sessionStore: sessionStore, serverTokenStore: tokens, signedOutTokenStore: InMemoryTokenBatchStore(),
        queueOpener: { queue }, transportFactory: {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow })
}

@MainActor
private func reviewSignIn(_ composition: AppComposition) async throws {
    try await composition.account.signIn(using: AuthRequest(path: "signin", body: Data()), isAdult: true,
        acceptsTermsAndPrivacy: true, termsVersion: "fixture", privacyVersion: "fixture")
}
