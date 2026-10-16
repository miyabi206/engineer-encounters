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
        let composition = AppComposition(configuration: nil, defaults: appBackendDefaults(), notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(), keychain: keychain,
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
        let store = KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(appBackendTestConfiguration()), client: keychain)
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
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(), notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
            transport: transport, keychain: AppMemoryKeychain(), sessionStore: store, serverTokenStore: InMemoryTokenBatchStore(),
            queueOpener: { InMemoryReceiptQueue() }, now: { appBackendTestNow }, timeZone: { zone.value })
        var states: [AccountState] = []
        let subscription = composition.account.$state.sink { states.append($0) }
        await composition.waitForRestoration()
        XCTAssertEqual(states, [.restoring, .signedInPending(appBackendTestUser), .signedIn(appBackendTestUser)])
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

    func testRelaunchSkipsRegisteredZoneAndRegistersAChangedZoneOnce() async throws {
        let defaults = appBackendDefaults()
        let firstTransport = AppBackendTransport([HTTPResponse(data: Data(), statusCode: 204)])
        let first = try timeZoneComposition(defaults: defaults, transport: firstTransport, zone: "Asia/Tokyo")
        await first.waitForRestoration()
        XCTAssertEqual(first.account.state, .signedIn(appBackendTestUser))
        XCTAssertEqual(RegisteredTimeZoneStore(defaults: defaults).zone(for: appBackendTestUser), "Asia/Tokyo")
        let firstRequests = await firstTransport.recorded()
        XCTAssertEqual(firstRequests.map { $0.url?.lastPathComponent }, ["register_time_zone"])

        let sameTransport = AppBackendTransport()
        let same = try timeZoneComposition(defaults: defaults, transport: sameTransport, zone: "Asia/Tokyo")
        await same.waitForRestoration()
        await same.account.refresh()
        XCTAssertEqual(same.account.state, .signedIn(appBackendTestUser))
        let sameRequests = await sameTransport.recorded()
        XCTAssertTrue(sameRequests.isEmpty)

        let changedTransport = AppBackendTransport([HTTPResponse(data: Data(), statusCode: 204)])
        let changed = try timeZoneComposition(defaults: defaults, transport: changedTransport, zone: "Europe/London")
        await changed.waitForRestoration()
        await changed.account.refresh()
        XCTAssertEqual(changed.account.state, .signedIn(appBackendTestUser))
        let changedRequests = await changedTransport.recorded()
        XCTAssertEqual(changedRequests.map { $0.url?.lastPathComponent }, ["register_time_zone"])
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(changedRequests.first?.httpBody)) as? [String: String]
        XCTAssertEqual(body?["time_zone"], "Europe/London")
        XCTAssertEqual(RegisteredTimeZoneStore(defaults: defaults).zone(for: appBackendTestUser), "Europe/London")
    }

    func testProfileWithMissingOrDifferentTimeZoneRetriesRegistrationOnNextRefresh() async throws {
        for serverZone in ["", "UTC", "Asia/Tokyo"] {
            let defaults = appBackendDefaults()
            var profile = appPresentationProfile()
            profile.timeZone = serverZone
            var responses = [appAccountOK(), appOwnProfileResponse(profile)]
            if serverZone != "Asia/Tokyo" { responses.append(appAccountOK()) }
            let transport = AppBackendTransport(responses)
            let composition = try timeZoneComposition(defaults: defaults, transport: transport, zone: "Asia/Tokyo")
            await composition.waitForRestoration()
            let zones = RegisteredTimeZoneStore(defaults: defaults)
            let key = try zones.key(for: appBackendTestUser)
            XCTAssertEqual(defaults.string(forKey: key), "Asia/Tokyo")
            let otherAccount = UUID()
            zones.record("Europe/London", for: otherAccount)

            let loaded = try await composition.account.loadOwnProfile()
            XCTAssertEqual(loaded.timeZone, serverZone)
            XCTAssertEqual(defaults.string(forKey: key), serverZone == "Asia/Tokyo" ? "Asia/Tokyo" : nil)
            XCTAssertEqual(zones.zone(for: otherAccount), "Europe/London")
            await composition.account.refresh()
            await composition.account.refresh()
            XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
            XCTAssertEqual(zones.zone(for: appBackendTestUser), "Asia/Tokyo")
            let requests = await transport.recorded()
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, serverZone == "Asia/Tokyo" ?
                ["register_time_zone", "get_own_profile"] :
                ["register_time_zone", "get_own_profile", "register_time_zone"])
        }
    }

    func testRateLimitedTimeZoneDoesNotFailSetupAndRetriesOnNextLaunch() async throws {
        for previousZone in [nil, "Europe/London"] as [String?] {
            let defaults = appBackendDefaults()
            let zones = RegisteredTimeZoneStore(defaults: defaults)
            if let previousZone { zones.record(previousZone, for: appBackendTestUser) }
            let limitedTransport = AppBackendTransport([
                HTTPResponse(data: Data(#"{"message":"rate_limited"}"#.utf8), statusCode: 429)])
            let limited = try timeZoneComposition(defaults: defaults, transport: limitedTransport, zone: "Asia/Tokyo")
            await limited.waitForRestoration()
            XCTAssertEqual(limited.account.state, .signedIn(appBackendTestUser))
            XCTAssertEqual(zones.zone(for: appBackendTestUser), previousZone)
            let limitedRequests = await limitedTransport.recorded()
            XCTAssertEqual(limitedRequests.map { $0.url?.lastPathComponent }, ["register_time_zone"])

            let retryTransport = AppBackendTransport([HTTPResponse(data: Data(), statusCode: 204)])
            let retry = try timeZoneComposition(defaults: defaults, transport: retryTransport, zone: "Asia/Tokyo")
            await retry.waitForRestoration()
            XCTAssertEqual(retry.account.state, .signedIn(appBackendTestUser))
            XCTAssertEqual(zones.zone(for: appBackendTestUser), "Asia/Tokyo")
            let retryRequests = await retryTransport.recorded()
            XCTAssertEqual(retryRequests.map { $0.url?.lastPathComponent }, ["register_time_zone"])

            let savedTransport = AppBackendTransport()
            let saved = try timeZoneComposition(defaults: defaults, transport: savedTransport, zone: "Asia/Tokyo")
            await saved.waitForRestoration()
            XCTAssertEqual(saved.account.state, .signedIn(appBackendTestUser))
            let savedRequests = await savedTransport.recorded()
            XCTAssertTrue(savedRequests.isEmpty)
        }
    }

    func testOtherTimeZoneErrorsStillFailSetupAndAreNotRecorded() async throws {
        for code in ["invalid_input", "declaration_required", "account_not_ready"] {
            let defaults = appBackendDefaults()
            let transport = AppBackendTransport([
                HTTPResponse(data: Data("{\"message\":\"\(code)\"}".utf8), statusCode: 400)])
            let composition = try timeZoneComposition(defaults: defaults, transport: transport, zone: "Asia/Tokyo")
            await composition.waitForRestoration()
            XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
            XCTAssertNil(RegisteredTimeZoneStore(defaults: defaults).zone(for: appBackendTestUser))
        }
    }

    func testRegisteredZoneIsClearedWhenSessionIsDiscardedOrAccountDeleted() async throws {
        for operation in ["signOut", "deletion", "deadSession", "missingSession"] {
            let defaults = appBackendDefaults()
            let sessionStore = InMemorySessionStore(session: try appBackendTestSession())
            let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults,
                notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
                transport: AppBackendTransport([HTTPResponse(data: Data(), statusCode: 204)]),
                keychain: AppMemoryKeychain(), sessionStore: sessionStore, serverTokenStore: InMemoryTokenBatchStore(),
                queueOpener: { InMemoryReceiptQueue() }, now: { appBackendTestNow }, timeZone: { "Asia/Tokyo" })
            await composition.waitForRestoration()
            let zones = RegisteredTimeZoneStore(defaults: defaults)
            let key = try zones.key(for: appBackendTestUser)
            XCTAssertEqual(zones.zone(for: appBackendTestUser), "Asia/Tokyo")
            switch operation {
            case "signOut": try await composition.account.signOut()
            case "deletion": await composition.account.completeAccountDeletion(generation: composition.account.sessionGeneration)
            case "deadSession": await composition.account.rejectDeadSession(generation: composition.account.sessionGeneration)
            default:
                try await sessionStore.clear()
                await composition.account.restore()
            }
            XCTAssertEqual(composition.account.state, .signedOut)
            XCTAssertNil(defaults.object(forKey: key), operation)
            XCTAssertNil(zones.zone(for: appBackendTestUser), operation)
        }
    }

    func testRegisteredZoneIsClearedOnBackendOrAccountBindingChange() async throws {
        for changeBackend in [false, true] {
            let defaults = appBackendDefaults()
            let first = try timeZoneComposition(defaults: defaults,
                transport: AppBackendTransport([HTTPResponse(data: Data(), statusCode: 204)]), zone: "Asia/Tokyo")
            await first.waitForRestoration()
            let zones = RegisteredTimeZoneStore(defaults: defaults)
            XCTAssertEqual(zones.zone(for: appBackendTestUser), "Asia/Tokyo")
            let oldAccount = UUID()
            zones.record("Europe/London", for: oldAccount)
            let user = changeBackend ? appBackendTestUser : UUID()
            let configuration = changeBackend ? BackendConfiguration(address: "https://other.example", publicClientKey: "public-test-key")! : appBackendTestConfiguration()
            let transport = AppBackendTransport([HTTPResponse(data: Data(), statusCode: 204)])
            let changed = try timeZoneComposition(defaults: defaults, transport: transport, zone: "Asia/Tokyo",
                userID: user, configuration: configuration)
            await changed.waitForRestoration()
            XCTAssertEqual(changed.account.state, .signedIn(user))
            XCTAssertEqual(zones.zone(for: user), "Asia/Tokyo")
            XCTAssertNil(defaults.object(forKey: try zones.key(for: oldAccount)))
            if !changeBackend { XCTAssertNil(zones.zone(for: appBackendTestUser)) }
            let requests = await transport.recorded()
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["register_time_zone"])
        }
    }

    func testRegisteredZoneStoreUsesInstallationSaltAndSeparateAccountKeys() throws {
        let defaults = appBackendDefaults()
        let zones = RegisteredTimeZoneStore(defaults: defaults)
        let otherUser = UUID()
        zones.record("Asia/Tokyo", for: appBackendTestUser)
        XCTAssertNil(zones.zone(for: otherUser))
        zones.record("Europe/London", for: otherUser)
        XCTAssertEqual(zones.zone(for: appBackendTestUser), "Asia/Tokyo")
        XCTAssertEqual(zones.zone(for: otherUser), "Europe/London")
        let key = try zones.key(for: appBackendTestUser)
        let onboardingKey = try OnboardingCompletionStore(defaults: defaults).key(for: appBackendTestUser)
        XCTAssertEqual(key.split(separator: ".").last, onboardingKey.split(separator: ".").last)
        XCTAssertEqual(key.split(separator: ".").last?.count, 64)
        XCTAssertFalse(key.lowercased().contains(appBackendTestUser.uuidString.lowercased()))
        XCTAssertNotEqual(key, try RegisteredTimeZoneStore(defaults: appBackendDefaults()).key(for: appBackendTestUser))
        zones.clear()
        XCTAssertNil(zones.zone(for: appBackendTestUser))
        XCTAssertNil(zones.zone(for: otherUser))
    }

    private func timeZoneComposition(defaults: UserDefaults, transport: AppBackendTransport, zone: String,
                                     userID: UUID = appBackendTestUser,
                                     configuration: BackendConfiguration = appBackendTestConfiguration()) throws -> AppComposition {
        AppComposition(configuration: configuration, defaults: defaults,
            notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(), transport: transport,
            keychain: AppMemoryKeychain(), sessionStore: InMemorySessionStore(session: try appBackendTestSession(userID: userID)),
            serverTokenStore: InMemoryTokenBatchStore(), queueOpener: { InMemoryReceiptQueue() },
            now: { appBackendTestNow }, timeZone: { zone })
    }

    func testSignedOutIssuerSelectionForThisBuildAndSignOutClearsOnlyServerStore() async throws {
        let keychain = AppMemoryKeychain()
        let defaults = appBackendDefaults()
        let owner = BackendStorageOwner(backend: BackendStorageBinding.identity(appBackendTestConfiguration()), account: appBackendTestUser, salt: try InstallationStorageSalt.load(defaults: defaults))
        let service = AppComposition.serverTokenService(owner: owner)
        let server = KeychainTokenBatchStore(service: service, client: keychain)
        let queue = InMemoryReceiptQueue()
        let store = InMemorySessionStore(session: try appBackendTestSession())
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults, notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
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
        composition.account.onboardingCompletion.finish(appBackendTestUser)
        try await composition.account.signOut()
        XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertFalse(composition.account.onboardingCompletion.contains(appBackendTestUser))
        let session = try await store.load()
        let batch = try await server.load()
        let pending = try await queue.pending()
        XCTAssertNil(session)
        XCTAssertNil(batch)
        XCTAssertTrue(pending.isEmpty)
        // An issuer retained by an old operation cannot refill cleared storage after invalidation.
        let transportRequestsBefore = await keychain.services
        XCTAssertTrue(transportRequestsBefore.contains(service))
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
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults, notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
            transport: AppBackendTransport([HTTPResponse(data: Data(), statusCode: 204)]),
            keychain: AppMemoryKeychain(), sessionStore: InMemorySessionStore(session: try appBackendTestSession()),
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
    func testTemporarySignInContinuesOnTimeZoneRateLimitButNotDeclarationRateLimit() async throws {
        for limitDeclarations in [false, true] {
            let defaults = appBackendDefaults(userID: nil)
            let limited = HTTPResponse(data: Data(#"{"message":"rate_limited"}"#.utf8), statusCode: 429)
            var responses = [appBackendAuthResponse()]
            if !limitDeclarations { responses.append(HTTPResponse(data: Data(), statusCode: 204)) }
            responses.append(limited)
            let transport = AppBackendTransport(responses)
            let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults,
                notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(), transport: transport,
                keychain: AppMemoryKeychain(), sessionStore: InMemorySessionStore(), serverTokenStore: InMemoryTokenBatchStore(),
                queueOpener: { InMemoryReceiptQueue() }, now: { appBackendTestNow }, timeZone: { "Asia/Tokyo" })
            await composition.waitForRestoration()
            do {
                try await composition.account.signInTemporaryAccount(isAdult: true, acceptsTermsAndPrivacy: true)
                XCTAssertFalse(limitDeclarations)
            } catch {
                XCTAssertTrue(limitDeclarations)
                XCTAssertEqual(error as? BackendError, .rateLimited)
            }
            XCTAssertEqual(composition.account.state, limitDeclarations ? .signedInPending(appBackendTestUser) : .signedIn(appBackendTestUser))
            XCTAssertNil(RegisteredTimeZoneStore(defaults: defaults).zone(for: appBackendTestUser))
            let requests = await transport.recorded()
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, limitDeclarations ?
                ["signup", "accept_declarations"] : ["signup", "accept_declarations", "register_time_zone"])
        }
    }

    func testTemporarySignInUsesExactAuthBodyRecordsDeclarationsAndRecreatesRuntime() async throws {
        let transport = AppBackendTransport([appBackendAuthResponse(),
            HTTPResponse(data: Data(), statusCode: 204), HTTPResponse(data: Data(), statusCode: 204)])
        let queue = InMemoryReceiptQueue()
        let server = InMemoryTokenBatchStore(batch: try EncounterSamples.batch())
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(), notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
            transport: transport, keychain: AppMemoryKeychain(), sessionStore: InMemorySessionStore(), serverTokenStore: server,
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

    func testDeclarationFailureKeepsEstablishedSessionAndServerIssuer() async throws {
        let sessions = InMemorySessionStore()
        let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(), notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
            transport: AppBackendTransport([appBackendAuthResponse(), HTTPResponse(data: Data(), statusCode: 500)]),
            keychain: AppMemoryKeychain(), sessionStore: sessions, serverTokenStore: InMemoryTokenBatchStore(),
            signedOutTokenStore: InMemoryTokenBatchStore(),
            queueOpener: { InMemoryReceiptQueue() }, now: { appBackendTestNow })
        await composition.waitForRestoration()
        var states: [AccountState] = []
        let subscription = composition.account.$state.sink { states.append($0) }
        do { try await composition.account.signInTemporaryAccount(isAdult: true, acceptsTermsAndPrivacy: true); XCTFail("Declaration failure must fail sign-in") }
        catch { XCTAssertEqual(error as? BackendError, .transportFailure) }
        XCTAssertEqual(states, [.signedOut, .signedInPending(appBackendTestUser)])
        let remainingSession = try await sessions.load()
        XCTAssertNotNil(remainingSession)
        await composition.refreshLocalSummary()
        XCTAssertTrue(composition.runtime?.tokenIssuer is ServerTokenIssuer)
        withExtendedLifetime(subscription) {}
    }
    #endif
}
