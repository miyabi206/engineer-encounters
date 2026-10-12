import Combine
import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class AccountModelTests: XCTestCase {
    func testConfigurationComesFromInfoAndRejectsMissingEmptyInvalidAndUnexpandedValues() {
        let invalid: [[String: Any]] = [[:], ["BackendURL": "https://backend.example"],
            ["BackendURL": "", "BackendPublicKey": "key"],
            ["BackendURL": "file:///backend", "BackendPublicKey": "key"],
            ["BackendURL": "https://backend.example", "BackendPublicKey": ""],
            ["BackendURL": "https://backend.example", "BackendPublicKey": "bad\nkey"],
            ["BackendURL": "$(BACKEND_URL)", "BackendPublicKey": "$(BACKEND_PUBLIC_KEY)"]]
        for info in invalid { XCTAssertNil(AppComposition.backendConfiguration(info: info)) }
        let valid = AppComposition.backendConfiguration(info: [
            "BackendURL": "https://backend.example", "BackendPublicKey": "public-test-key"])
        XCTAssertEqual(valid, appBackendTestConfiguration())
    }

    func testMissingConfigurationDoesNotReadSessionOrCreateBluetoothOrClearReceipts() async throws {
        let queue = InMemoryReceiptQueue()
        try await queue.enqueue(EncounterSamples.receipt())
        let keychain = AppMemoryKeychain()
        var bluetoothBuilds = 0
        let composition = AppComposition(configuration: nil, defaults: appBackendDefaults(), keychain: keychain,
            queueOpener: { queue }, transportFactory: {
                bluetoothBuilds += 1
                return await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: ManualEncounterClock())
            })
        await composition.waitForRestoration()
        XCTAssertEqual(composition.account.state, .unavailable)
        XCTAssertNil(composition.runtime)
        await composition.refreshLocalSummary()
        XCTAssertEqual(bluetoothBuilds, 0)
        let reads = await keychain.reads
        // The summary reads a token store, but unavailable configuration never reads credentials.
        XCTAssertEqual(reads, 1)
        let pending = try await queue.pending()
        XCTAssertEqual(pending.count, 1)
        #if DEVELOPMENT_BUILD
        XCTAssertTrue(composition.runtime?.tokenIssuer is LocalTestTokenIssuer)
        #else
        XCTAssertNil(composition.runtime?.tokenIssuer)
        #endif
    }

    func testKeychainSessionRoundTripCorruptionAndSeparationFromServerTokens() async throws {
        let keychain = AppMemoryKeychain()
        let store = KeychainSessionStore(client: keychain)
        let tokens = KeychainTokenBatchStore(service: AppComposition.serverTokenService, client: keychain)
        let session = try appBackendTestSession()
        try await store.save(session)
        try await tokens.save(EncounterSamples.batch())
        let loaded = try await store.load()
        XCTAssertTrue(loaded == session)
        try await store.clear()
        let cleared = try await store.load()
        let retained = try await tokens.load()
        XCTAssertNil(cleared)
        XCTAssertNotNil(retained)
        await keychain.corruptSession()
        do { _ = try await store.load(); XCTFail("Corrupt credentials must fail closed") }
        catch { XCTAssertEqual(error as? BackendError, .storageFailure) }
    }

    func testRestoresWithoutUIAndRegistersChangedZoneOnForegroundOnly() async throws {
        let transport = AppBackendTransport(Array(repeating: HTTPResponse(data: Data(), statusCode: 204), count: 2))
        let store = InMemorySessionStore(session: try appBackendTestSession())
        let zone = AppTestTimeZone("Asia/Tokyo")
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(),
            transport: transport, sessionStore: store, serverTokenStore: InMemoryTokenBatchStore(),
            queueOpener: { InMemoryReceiptQueue() }, now: { appBackendTestNow }, timeZone: { zone.value })
        var states: [AccountState] = []
        let subscription = composition.account.$state.sink { states.append($0) }
        await composition.waitForRestoration()
        XCTAssertEqual(states, [.signedOut, .signedIn(appBackendTestUser)])
        XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
        await composition.refresh()
        zone.value = "Europe/London"
        await composition.refresh()
        await composition.refresh()
        let requests = await transport.recorded()
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["register_time_zone", "register_time_zone"])
        let zones = try requests.map {
            let body = try XCTUnwrap($0.httpBody)
            return (try JSONSerialization.jsonObject(with: body) as? [String: String])?["time_zone"]
        }
        XCTAssertEqual(zones, ["Asia/Tokyo", "Europe/London"])
        withExtendedLifetime(subscription) {}
    }

    func testSignedOutIssuerSelectionForThisBuildAndSignOutClearsOnlyServerStore() async throws {
        let keychain = AppMemoryKeychain()
        let server = KeychainTokenBatchStore(service: AppComposition.serverTokenService, client: keychain)
        let queue = InMemoryReceiptQueue()
        let store = InMemorySessionStore(session: try appBackendTestSession())
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(),
            transport: AppBackendTransport([HTTPResponse(data: Data(), statusCode: 204)]), keychain: keychain,
            sessionStore: store, queueOpener: { queue }, now: { appBackendTestNow })
        await composition.waitForRestoration()
        let oldRuntime = try XCTUnwrap(composition.runtime)
        let oldIssuer = try XCTUnwrap(oldRuntime.tokenIssuer)
        XCTAssertTrue(oldIssuer is ServerTokenIssuer)
        try await server.save(EncounterSamples.batch())
        try await queue.enqueue(EncounterSamples.receipt())
        #if DEVELOPMENT_BUILD
        let local = KeychainTokenBatchStore(service: "EngineerEncounters.Development.LocalTestTokens", client: keychain)
        try await local.save(EncounterSamples.batch())
        #endif
        try await composition.account.signOut()
        XCTAssertEqual(composition.account.state, .signedOut)
        let session = try await store.load()
        let batch = try await server.load()
        let pending = try await queue.pending()
        XCTAssertNil(session)
        XCTAssertNil(batch)
        XCTAssertTrue(pending.isEmpty)
        // An issuer retained by an old operation cannot refill cleared storage after invalidation.
        let transportRequestsBefore = await keychain.services
        XCTAssertTrue(transportRequestsBefore.contains(AppComposition.serverTokenService))
        await oldRuntime.refresh()
        await composition.refreshLocalSummary()
        XCTAssertFalse(oldRuntime === composition.runtime)
        #if DEVELOPMENT_BUILD
        let localBatch = try await local.load()
        XCTAssertNotNil(localBatch)
        XCTAssertTrue(composition.runtime?.tokenIssuer is LocalTestTokenIssuer)
        #else
        XCTAssertNil(composition.runtime?.tokenIssuer)
        #endif
    }

    func testPersistedParticipationLaunchRestoresServerIssuerBeforeCreatingBluetooth() async throws {
        let defaults = appBackendDefaults()
        ParticipationFlag(defaults: defaults).isEnabled = true
        let clock = ManualEncounterClock()
        var builds = 0
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults,
            transport: AppBackendTransport([HTTPResponse(data: Data(), statusCode: 204)]),
            sessionStore: InMemorySessionStore(session: try appBackendTestSession()),
            serverTokenStore: InMemoryTokenBatchStore(batch: try EncounterSamples.batch()),
            queueOpener: { InMemoryReceiptQueue() }, transportFactory: {
                builds += 1
                return await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
            }, clock: clock, now: { appBackendTestNow })
        await composition.waitForRestoration()
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
        XCTAssertEqual(builds, 1)
        await composition.setParticipation(false)
    }

    #if DEVELOPMENT_BUILD
    func testTemporarySignInUsesExactAuthBodyRecordsDeclarationsAndRecreatesRuntime() async throws {
        let transport = AppBackendTransport([appBackendAuthResponse(),
            HTTPResponse(data: Data(), statusCode: 204), HTTPResponse(data: Data(), statusCode: 204)])
        let queue = InMemoryReceiptQueue()
        let server = InMemoryTokenBatchStore(batch: try EncounterSamples.batch())
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(),
            transport: transport, sessionStore: InMemorySessionStore(), serverTokenStore: server,
            queueOpener: { queue }, now: { appBackendTestNow }, timeZone: { "Asia/Tokyo" })
        await composition.waitForRestoration()
        await composition.refreshLocalSummary()
        let oldRuntime = try XCTUnwrap(composition.runtime)
        XCTAssertTrue(oldRuntime.tokenIssuer is LocalTestTokenIssuer)
        try await queue.enqueue(EncounterSamples.receipt())
        try await composition.account.signInTemporaryAccount(isAdult: true, acceptsTermsAndPrivacy: true)
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        XCTAssertFalse(oldRuntime === composition.runtime)
        XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
        let pending = try await queue.pending()
        let cleared = try await server.load()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNil(cleared)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/auth/v1/signup", "/rest/v1/rpc/accept_declarations",
                                                     "/rest/v1/rpc/register_time_zone"])
        XCTAssertEqual(requests[0].httpMethod, "POST")
        let authBody = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? NSDictionary
        XCTAssertEqual(authBody, ["data": [:]] as NSDictionary)
        let declarations = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? NSDictionary
        XCTAssertEqual(declarations, ["age_18": true, "terms_version": "development-draft",
                                      "privacy_version": "development-draft"] as NSDictionary)
        XCTAssertFalse(composition.account.temporarySignInTitle.isEmpty)
    }

    func testFailedTemporarySignInDoesNotPublishSignedInOrUseServerIssuer() async throws {
        let sessions = InMemorySessionStore()
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(),
            transport: AppBackendTransport([appBackendAuthResponse(), HTTPResponse(data: Data(), statusCode: 500)]),
            sessionStore: sessions, serverTokenStore: InMemoryTokenBatchStore(),
            signedOutTokenStore: InMemoryTokenBatchStore(),
            queueOpener: { InMemoryReceiptQueue() }, now: { appBackendTestNow })
        await composition.waitForRestoration()
        var states: [AccountState] = []
        let subscription = composition.account.$state.sink { states.append($0) }
        do { try await composition.account.signInTemporaryAccount(isAdult: true, acceptsTermsAndPrivacy: true); XCTFail("Declaration failure must fail sign-in") }
        catch { XCTAssertEqual(error as? BackendError, .transportFailure) }
        XCTAssertTrue(states.allSatisfy { $0 == .signedOut })
        let remainingSession = try await sessions.load()
        XCTAssertNil(remainingSession)
        await composition.refreshLocalSummary()
        XCTAssertTrue(composition.runtime?.tokenIssuer is LocalTestTokenIssuer)
        withExtendedLifetime(subscription) {}
    }
    #endif
}
