import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class AccountFlowTests: XCTestCase {
    func testUnavailableAndSignedOutRootsKeepWelcomeAndOnlyDevelopmentOffersSignIn() async {
        for available in [false, true] {
            let composition = appFlowComposition(configuration: available ? appBackendTestConfiguration() : nil)
            let flow = AccountFlowModel(composition: composition, defaults: appBackendDefaults())
            await flow.start()
            XCTAssertEqual(flow.root, .welcome)
            XCTAssertEqual(composition.account.state, available ? .signedOut : .unavailable)
            XCTAssertEqual(flow.usesSignInWelcome, available && BuildKind.isDevelopment)
            XCTAssertNil(flow.onboarding)
            XCTAssertNil(flow.settings)
            XCTAssertNil(composition.runtime)
        }
    }

    func testUnfinishedProfilesResumeAtEachSupportedStepWithoutRequestingBluetooth() async throws {
        var basics = appPresentationProfile()
        basics.displayName = ""
        var selections = appPresentationProfile()
        selections.interestIDs = []
        let cases: [(OwnProfileState, OnboardingStep)] = [(basics, .basics), (selections, .interests), (appPresentationProfile(), .firstLink), (appLinkedPresentationProfile(), .permissions)]
        for (profile, step) in cases {
            var builds = 0
            let composition = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse(profile)]),
                session: try appBackendTestSession(), transportFactory: {
                    builds += 1
                    return ConsentTestTransport()
                })
            let flow = AccountFlowModel(composition: composition, defaults: appBackendDefaults())
            await flow.start()
            XCTAssertEqual(flow.root, .onboarding)
            XCTAssertEqual(flow.onboarding?.step, step)
            XCTAssertEqual(flow.onboarding?.profile, profile)
            XCTAssertFalse(try XCTUnwrap(flow.onboarding).canEnableDiscovery)
            XCTAssertTrue(try XCTUnwrap(flow.settings).allowsDiscoveryActivation)
            XCTAssertEqual(builds, 0)
            XCTAssertFalse(flow.usesSignInWelcome)
        }
    }

    func testSettingsDiscoveryActivationRequiresReadyAccountAndEachPrerequisite() async throws {
        for missing in ["none", "display_name", "introduction", "interest", "link", "declarations", "time_zone", "moderation"] {
            var profile = appLinkedPresentationProfile()
            switch missing {
            case "display_name": profile.prerequisites.displayName = false
            case "introduction": profile.prerequisites.introduction = false
            case "interest": profile.prerequisites.interest = false
            case "link": profile.prerequisites.link = false
            case "declarations": profile.declarationsRecorded = false
            case "time_zone": profile.timeZone = ""
            case "moderation": profile.moderationState = "suspended"
            default: break
            }
            var enabled = profile; enabled.discoveryOn = true
            let transport = ControlledAppBackendTransport([
                "register_time_zone": [.response(appAccountOK())],
                "get_own_profile": [.response(appOwnProfileResponse(profile)), .response(appOwnProfileResponse(enabled))],
                "set_discovery": [.response(appAccountOK())]
            ])
            let defaults = appBackendDefaults()
            OnboardingCompletionStore(defaults: defaults).finish(appBackendTestUser)
            let composition = appFlowComposition(transport: transport, session: try appBackendTestSession(), defaults: defaults)
            let flow = AccountFlowModel(composition: composition)
            await flow.start()
            XCTAssertEqual(flow.root, .settings)
            let settings = try XCTUnwrap(flow.settings)
            // Supply the radio observation independently from profile readiness.
            composition.runtime?.receive(.radioAvailability(.available))
            settings.receive(profile: profile, bluetooth: .available)
            XCTAssertEqual(settings.canEnableDiscovery, missing == "none", missing)
            let saved = await settings.setDiscovery(true)
            XCTAssertEqual(saved, missing == "none", missing)
            let count = await transport.count("set_discovery")
            XCTAssertEqual(count, missing == "none" ? 1 : 0, missing)
        }
    }

    func testSettingsActivationFollowsReadinessAndNewLinkProfileUpdates() async throws {
        var unready = appLinkedPresentationProfile(); unready.declarationsRecorded = false
        let composition = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse(unready)]),
            session: try appBackendTestSession())
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        XCTAssertFalse(try XCTUnwrap(flow.settings).allowsDiscoveryActivation)
        composition.runtime?.receive(.radioAvailability(.available))
        composition.account.publishProfile(appPresentationProfile(), stale: false)
        let settings = try XCTUnwrap(flow.settings)
        XCTAssertTrue(settings.allowsDiscoveryActivation)
        settings.receive(profile: appPresentationProfile(), bluetooth: .available)
        XCTAssertFalse(settings.canEnableDiscovery)
        composition.account.publishProfile(appLinkedPresentationProfile(), stale: false)
        XCTAssertTrue(try XCTUnwrap(flow.settings).canEnableDiscovery)
    }

    func testReadinessChangeRetainsSettingsDraftsCatalogueAndSaveInFlight() async throws {
        let profile = appLinkedPresentationProfile()
        var unready = profile
        unready.declarationsRecorded = false
        var saved = unready
        saved.minimumSharedInterests = 5
        let catalogue = HTTPResponse(data: Data(#"[{"interest_id":"a","label_ja":"技術","label_en":"Technology","display_order":1}]"#.utf8), statusCode: 200)
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())],
            "get_own_profile": [.response(appOwnProfileResponse(profile)), .response(appOwnProfileResponse(profile)),
                .response(appOwnProfileResponse(saved))],
            "list_interests": [.response(catalogue)],
            "set_minimum_shared_interests": [.held]
        ])
        let composition = appFlowComposition(transport: transport, session: try appBackendTestSession())
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        let settings = try XCTUnwrap(flow.settings)
        await settings.loadInterests()
        let interests = settings.interests
        XCTAssertTrue(settings.hasLoadedInterests)
        XCTAssertEqual(interests.count, 1)
        settings.introduction = "Unsaved introduction"
        settings.visibility[.introduction] = .private
        settings.minimumSharedInterests = 5
        XCTAssertEqual(settings.profile.minimumSharedInterests, 3)
        XCTAssertTrue(settings.canSaveMatching)
        let saving = Task { await settings.saveMatching() }
        try await appBackendEventually { await transport.isHeld("set_minimum_shared_interests") }
        composition.account.publishProfile(unready, stale: false)
        XCTAssertTrue(flow.settings === settings)
        XCTAssertFalse(settings.allowsDiscoveryActivation)
        XCTAssertTrue(settings.isSaving)
        XCTAssertEqual(settings.introduction, "Unsaved introduction")
        XCTAssertEqual(settings.visibility[.introduction], .private)
        XCTAssertEqual(settings.interests, interests)
        await transport.release("set_minimum_shared_interests", with: appAccountOK())
        await saving.value
        XCTAssertTrue(flow.settings === settings)
        XCTAssertFalse(settings.isSaving)
        XCTAssertEqual(settings.profile.minimumSharedInterests, 5)
        XCTAssertNil(settings.errors[.discovery])
        XCTAssertNil(settings.failedOperations[.discovery])
        var ready = saved
        ready.declarationsRecorded = true
        ready.prerequisites.link = false
        composition.account.publishProfile(ready, stale: false)
        XCTAssertTrue(flow.settings === settings)
        XCTAssertTrue(settings.allowsDiscoveryActivation)
        XCTAssertFalse(settings.canEnableDiscovery)
        XCTAssertEqual(settings.introduction, "Unsaved introduction")
        XCTAssertEqual(settings.visibility[.introduction], .private)
        XCTAssertEqual(settings.interests, interests)
        XCTAssertTrue(settings.hasLoadedInterests)
        let writes = await transport.count("set_minimum_shared_interests")
        XCTAssertEqual(writes, 1)
    }

    func testProfileLoadFailureRetriesWithoutLosingTheSession() async throws {
        let transport = AppBackendTransport([appAccountOK(), HTTPResponse(data: Data(), statusCode: 503), appOwnProfileResponse()])
        let composition = appFlowComposition(transport: transport, session: try appBackendTestSession())
        let flow = AccountFlowModel(composition: composition, defaults: appBackendDefaults())
        await flow.start()
        XCTAssertEqual(flow.root, .profileUnavailable)
        XCTAssertEqual(flow.profileError, .init(code: .unavailable))
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        await flow.refresh()
        XCTAssertEqual(flow.root, .onboarding)
        XCTAssertNil(flow.profileError)
    }

    func testFinishedOnboardingSurvivesRelaunchForOnlyThatAccount() async throws {
        let defaults = appBackendDefaults()
        let composition = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse(appLinkedPresentationProfile())]),
            session: try appBackendTestSession())
        let flow = AccountFlowModel(composition: composition, defaults: defaults)
        await flow.start()
        let onboarding = try XCTUnwrap(flow.onboarding)
        XCTAssertFalse(flow.completion.contains(appBackendTestUser))
        await onboarding.finish(discovery: false)
        XCTAssertEqual(flow.root, .settings)
        XCTAssertTrue(flow.completion.contains(appBackendTestUser))
        XCTAssertFalse(try XCTUnwrap(flow.settings).showsDiscoveryExplanation)
        XCTAssertTrue(try XCTUnwrap(flow.settings).allowsDiscoveryActivation)
        XCTAssertNil(flow.onboarding)
        let sameAccount = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse(appLinkedPresentationProfile())]),
            session: try appBackendTestSession())
        let relaunched = AccountFlowModel(composition: sameAccount, defaults: defaults)
        await relaunched.start()
        XCTAssertEqual(relaunched.root, .settings)

        try await composition.account.signOut()
        XCTAssertEqual(flow.root, .welcome)
        XCTAssertNil(flow.settings)
        XCTAssertFalse(flow.completion.contains(appBackendTestUser))
        let afterSignOut = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse(appLinkedPresentationProfile())]),
            session: try appBackendTestSession())
        let restarted = AccountFlowModel(composition: afterSignOut, defaults: defaults)
        await restarted.start()
        XCTAssertEqual(restarted.root, .onboarding)

        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        let otherAccount = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse(appLinkedPresentationProfile())]),
            session: try appBackendTestSession(userID: otherID))
        let other = AccountFlowModel(composition: otherAccount, defaults: defaults)
        await other.start()
        XCTAssertEqual(other.root, .onboarding)
        XCTAssertFalse(other.completion.contains(otherID))
    }

    func testForegroundAndRadioEventsReachReceiveWithoutOverwritingDrafts() async throws {
        var fresh = appPresentationProfile()
        fresh.displayName = "更新した名前"
        fresh.introduction = "更新した紹介"
        let composition = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse(), appOwnProfileResponse(fresh)]),
            session: try appBackendTestSession())
        let flow = AccountFlowModel(composition: composition, defaults: appBackendDefaults())
        await flow.start()
        let onboarding = try XCTUnwrap(flow.onboarding)
        let settings = try XCTUnwrap(flow.settings)
        onboarding.introduction = "入力中"
        settings.introduction = "入力中"
        await flow.refresh()
        XCTAssertEqual(onboarding.profile, fresh)
        XCTAssertEqual(settings.profile, fresh)
        XCTAssertEqual(onboarding.displayName, fresh.displayName)
        XCTAssertEqual(settings.displayName, fresh.displayName)
        XCTAssertEqual(onboarding.introduction, "入力中")
        XCTAssertEqual(settings.introduction, "入力中")
        composition.runtime?.receive(.radioAvailability(.unauthorized))
        XCTAssertEqual(onboarding.bluetooth, .denied)
        XCTAssertEqual(settings.bluetooth, .denied)
        composition.runtime?.receive(.radioAvailability(.available))
        XCTAssertEqual(onboarding.bluetooth, .available)
        XCTAssertEqual(settings.bluetooth, .available)
        XCTAssertFalse(onboarding.canEnableDiscovery)
        XCTAssertFalse(settings.canEnableDiscovery)
    }

    func testBluetoothRequestCreatesOneRuntimeTransportAndDoesNotStartParticipation() async throws {
        let radio = ConsentTestTransport()
        var builds = 0
        let composition = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse(), appOwnProfileResponse()]),
            session: try appBackendTestSession(), transportFactory: { builds += 1; return radio })
        let flow = AccountFlowModel(composition: composition, defaults: appBackendDefaults())
        await flow.start()
        let onboarding = try XCTUnwrap(flow.onboarding)
        XCTAssertEqual(builds, 0)
        await onboarding.requestBluetooth()
        radio.emit(.availabilityChanged(.available))
        try await appBackendEventually { onboarding.bluetooth == .available }
        XCTAssertEqual(builds, 1)
        XCTAssertFalse(composition.isParticipating)
        XCTAssertFalse(composition.status.discoveryOn)
        let commands = radio.recorded()
        XCTAssertEqual(commands, [.stopDiscovery])
        try await composition.requestBluetooth()
        XCTAssertEqual(builds, 1)
        XCTAssertFalse(try XCTUnwrap(flow.settings).canRequestBluetooth)
        try await composition.account.signOut()
    }

    func testBackToWelcomeCanResumeOnboardingWithoutSigningOutOrRecordingCompletion() async throws {
        var profile = appPresentationProfile()
        profile.displayName = ""
        let defaults = appBackendDefaults()
        let composition = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse(profile)]),
            session: try appBackendTestSession())
        let flow = AccountFlowModel(composition: composition, defaults: defaults)
        await flow.start()
        flow.onboarding?.back()
        XCTAssertEqual(flow.root, .welcome)
        XCTAssertTrue(flow.canResumeOnboarding)
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        XCTAssertFalse(flow.completion.contains(appBackendTestUser))
        flow.resumeOnboarding()
        XCTAssertEqual(flow.root, .onboarding)
        XCTAssertFalse(try XCTUnwrap(flow.onboarding).hasCompleted)
    }

    func testRestorationHasNoSignInAndRefusesSignInBeforeAnyProviderIO() async throws {
        let sessions = HeldAppSessionStore(session: try appBackendTestSession())
        let transport = AppBackendTransport([appAccountOK(), appOwnProfileResponse()])
        let composition = appFlowComposition(transport: transport, sessionStore: sessions)
        let flow = AccountFlowModel(composition: composition, defaults: appBackendDefaults())
        XCTAssertEqual(flow.root, .restoring)
        XCTAssertFalse(flow.usesSignInWelcome)
        let starting = Task { await flow.start() }
        try await appBackendEventually { await sessions.isHeld }
        do { try await flowSignIn(composition); XCTFail("Restoring must refuse sign-in") }
        catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        let requests = await transport.recorded()
        XCTAssertTrue(requests.isEmpty)
        await sessions.release()
        await starting.value
        XCTAssertEqual(flow.root, .onboarding)
        XCTAssertFalse(flow.usesSignInWelcome)
    }

    func testWindowCreatedDuringStoredSessionRefreshAlsoShowsRestoration() async throws {
        let transport = ControlledAppBackendTransport([
            "token": [.held], "register_time_zone": [.response(appAccountOK())],
            "get_own_profile": [.response(appOwnProfileResponse())]
        ])
        let composition = appFlowComposition(transport: transport, session: try appBackendExpiredSession())
        try await appBackendEventually { await transport.isHeld("token") }
        XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
        let flow = AccountFlowModel(composition: composition)
        XCTAssertEqual(flow.root, .restoring)
        XCTAssertFalse(flow.usesSignInWelcome)
        let starting = Task { await flow.start() }
        await transport.release("token", with: appBackendAuthResponse())
        await starting.value
        XCTAssertEqual(flow.root, .onboarding)
    }

    func testLaunchAndSignInProfileLoadsSurviveCancellationOfTheRootViewTask() async throws {
        for atLaunch in [true, false] {
            let transport = ControlledAppBackendTransport([
                "signin": [.response(appBackendAuthResponse())],
                "accept_declarations": [.response(appAccountOK())],
                "register_time_zone": [.response(appAccountOK())],
                "get_own_profile": [.held]
            ])
            let composition = appFlowComposition(transport: transport, session: atLaunch ? try appBackendTestSession() : nil)
            let flow = AccountFlowModel(composition: composition, defaults: appBackendDefaults())
            let viewTask: Task<Void, Never>
            if atLaunch { viewTask = Task { await flow.start() } }
            else {
                await flow.start()
                try await flowSignIn(composition)
                viewTask = Task { await flow.start() }
            }
            try await appBackendEventually { await transport.isHeld("get_own_profile") }
            XCTAssertEqual(flow.root, .loadingProfile)
            XCTAssertEqual(flow.offersDiagnostics, BuildKind.isDevelopment || BuildKind.isInternal)
            viewTask.cancel()
            await transport.release("get_own_profile", with: appOwnProfileResponse())
            await viewTask.value
            try await appBackendEventually { flow.root == .onboarding }
            XCTAssertNotNil(flow.settings)
            XCTAssertNil(flow.profileError)
        }
    }

    func testSecondWindowLoadsItsOwnModelsAfterTheFirstWindowStarted() async throws {
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())],
            "get_own_profile": [.response(appOwnProfileResponse()), .held]
        ])
        let composition = appFlowComposition(transport: transport, session: try appBackendTestSession())
        let first = AccountFlowModel(composition: composition, defaults: appBackendDefaults())
        await first.start()
        let second = AccountFlowModel(composition: composition, defaults: appBackendDefaults())
        let starting = Task { await second.start() }
        try await appBackendEventually { await transport.isHeld("get_own_profile") }
        XCTAssertEqual(second.root, .loadingProfile)
        starting.cancel()
        await transport.release("get_own_profile", with: appOwnProfileResponse())
        await starting.value
        XCTAssertEqual(second.root, .onboarding)
        XCTAssertNotNil(second.settings)
        XCTAssertFalse(first.settings === second.settings)
    }

    func testCancelledProfileResponseShowsUnavailableAndCanBeRetried() async throws {
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())],
            "get_own_profile": [.cancelled, .response(appOwnProfileResponse())]
        ])
        let composition = appFlowComposition(transport: transport, session: try appBackendTestSession())
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        XCTAssertEqual(flow.root, .profileUnavailable)
        XCTAssertEqual(flow.profileError, .init(code: .unavailable))
        XCTAssertEqual(flow.offersDiagnostics, BuildKind.isDevelopment || BuildKind.isInternal)
        await flow.refresh()
        XCTAssertEqual(flow.root, .onboarding)
    }

    func testUnavailableRetryRefreshesThePendingAccountBeforeReadingItsProfile() async throws {
        let transport = ControlledAppBackendTransport([
            "token": [.failure, .response(appBackendAuthResponse())],
            "register_time_zone": [.response(appAccountOK())],
            "get_own_profile": [.response(appOwnProfileResponse())]
        ])
        let composition = appFlowComposition(transport: transport, session: try appBackendExpiredSession())
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        XCTAssertEqual(flow.root, .profileUnavailable)
        XCTAssertFalse(flow.usesSignInWelcome)
        do { try await flowSignIn(composition); XCTFail("A pending stored session must refuse sign-in") }
        catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        await flow.refresh()
        XCTAssertEqual(flow.root, .onboarding)
        let paths = await transport.recorded().map { $0.url?.lastPathComponent }
        XCTAssertEqual(paths, ["token", "token", "register_time_zone", "get_own_profile"])
    }

    func testDeadProfileOrScreenActionReturnsToWelcomeAndClearsAccountStorage() async throws {
        for onScreen in [false, true] {
            let transport = ControlledAppBackendTransport([
                "register_time_zone": [.response(appAccountOK())],
                "get_own_profile": onScreen ? [.response(appOwnProfileResponse())] :
                    [.response(appNotAuthenticatedResponse()), .response(appNotAuthenticatedResponse())],
                "set_minimum_shared_interests": [.response(appNotAuthenticatedResponse()), .response(appNotAuthenticatedResponse())],
                "token": [.response(appBackendAuthResponse())]
            ])
            let queue = InMemoryReceiptQueue()
            let tokens = InMemoryTokenBatchStore(batch: try EncounterSamples.batch())
            let sessions = InMemorySessionStore(session: try appBackendTestSession())
            let composition = AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(), notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(),
                transport: transport, keychain: AppMemoryKeychain(), sessionStore: sessions, serverTokenStore: tokens,
                signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { queue },
                transportFactory: { ConsentTestTransport() },
                productLifecycle: ProductSceneLifecycle(phase: .background, notifications: NotificationCenter()),
                now: { appBackendTestNow }, timeZone: { "Asia/Tokyo" })
            let flow = AccountFlowModel(composition: composition)
            if !onScreen { try await queue.enqueue(EncounterSamples.receipt()) }
            await flow.start()
            if onScreen {
                try await queue.enqueue(EncounterSamples.receipt())
                let model = try XCTUnwrap(flow.settings)
                model.minimumSharedInterests = 5
                await model.saveMatching()
            }
            XCTAssertEqual(flow.root, .welcome)
            XCTAssertEqual(composition.account.state, .signedOut)
            XCTAssertNil(flow.settings)
            XCTAssertNil(flow.onboarding)
            let stored = try await sessions.load()
            let batch = try await tokens.load()
            let receipts = try await queue.pending()
            XCTAssertNil(stored)
            XCTAssertNil(batch)
            XCTAssertTrue(receipts.isEmpty)
        }
    }

    func testSavedStaleProfileIsVisibleAndRefreshesWithoutRepeatingTheWrite() async throws {
        var saved = appPresentationProfile()
        saved.minimumSharedInterests = 5
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())],
            "get_own_profile": [.response(appOwnProfileResponse()), .failure, .response(appOwnProfileResponse(saved))],
            "set_minimum_shared_interests": [.response(appAccountOK())]
        ])
        let composition = appFlowComposition(transport: transport, session: try appBackendTestSession())
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        let settings = try XCTUnwrap(flow.settings)
        settings.minimumSharedInterests = 5
        await settings.saveMatching()
        XCTAssertNil(settings.errors[.discovery])
        XCTAssertNil(settings.failedOperations[.discovery])
        XCTAssertEqual(settings.profile.minimumSharedInterests, 5)
        XCTAssertTrue(flow.savedWithStaleProfile)
        await flow.refresh()
        XCTAssertFalse(flow.savedWithStaleProfile)
        let writes = await transport.count("set_minimum_shared_interests")
        XCTAssertEqual(writes, 1)
    }

    func testOneFlowSignsOutAccountAAndThenLoadsAccountBWithoutRetainingDraftsOrCompletion() async throws {
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        var otherProfile = appPresentationProfile()
        otherProfile.displayName = "Second account"
        let defaults = appBackendDefaults()
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK()), .response(appAccountOK())],
            "get_own_profile": [.response(appOwnProfileResponse(appLinkedPresentationProfile())), .response(appOwnProfileResponse(otherProfile))],
            "signin": [.response(appBackendAuthResponse(userID: otherID))],
            "accept_declarations": [.response(appAccountOK())]
        ])
        let composition = appFlowComposition(transport: transport, session: try appBackendTestSession(), defaults: defaults)
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        let oldSettings = try XCTUnwrap(flow.settings)
        let oldOnboarding = try XCTUnwrap(flow.onboarding)
        oldSettings.introduction = "Unsubmitted account A draft"
        await flow.onboarding?.finish(discovery: false)
        XCTAssertTrue(flow.completion.contains(appBackendTestUser))
        try await composition.account.signOut()
        XCTAssertEqual(flow.root, .welcome)
        XCTAssertFalse(flow.completion.contains(appBackendTestUser))
        try await flowSignIn(composition)
        try await appBackendEventually { flow.root == .onboarding }
        XCTAssertEqual(composition.account.state, .signedIn(otherID))
        XCTAssertEqual(flow.settings?.profile, otherProfile)
        XCTAssertEqual(flow.settings?.introduction, otherProfile.introduction)
        XCTAssertFalse(oldSettings === flow.settings)
        XCTAssertFalse(flow.completion.contains(otherID))
        let before = await transport.recorded().count
        oldSettings.minimumSharedInterests = 9
        await oldSettings.saveMatching()
        oldOnboarding.edit(.displayName)
        oldOnboarding.back()
        let after = await transport.recorded().count
        XCTAssertEqual(after, before)
        XCTAssertEqual(composition.account.state, .signedIn(otherID))
        XCTAssertEqual(flow.root, .onboarding)
    }

    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    func testDiagnosticsParticipationControlPersistsAndDrivesTheLocalRuntimeInBothBuildKinds() async throws {
        let defaults = appBackendDefaults()
        var builds = 0
        let composition = appFlowComposition(configuration: nil, defaults: defaults, transportFactory: {
            builds += 1
            return ConsentTestTransport()
        })
        await composition.waitForRestoration()
        var completed = false
        let control = DiagnosticsParticipationControl(composition: composition, isLoading: false, perform: { operation in
            Task { await operation(); completed = true }
        })
        control.participation.wrappedValue = true
        try await appBackendEventually { completed }
        XCTAssertTrue(composition.isParticipating)
        XCTAssertTrue(ParticipationFlag(defaults: defaults).isEnabled)
        XCTAssertEqual(builds, 1)
        completed = false
        control.participation.wrappedValue = false
        try await appBackendEventually { completed }
        XCTAssertFalse(composition.isParticipating)
        XCTAssertFalse(ParticipationFlag(defaults: defaults).isEnabled)
        XCTAssertFalse(composition.status.discoveryOn)
    }
    #endif

    func testCompletionUsesAnInstallationSaltAndNeverPersistsAnAccountIdentifier() throws {
        let defaults = appBackendDefaults()
        defaults.set(true, forKey: "encounter.onboarding.completed.\(appBackendTestUser.uuidString.lowercased())")
        let store = OnboardingCompletionStore(defaults: defaults)
        store.finish(appBackendTestUser)
        let key = try store.key(for: appBackendTestUser)
        XCTAssertFalse(key.contains(appBackendTestUser.uuidString.lowercased()))
        XCTAssertTrue(OnboardingCompletionStore(defaults: defaults).contains(appBackendTestUser))
        XCTAssertNotEqual(try OnboardingCompletionStore(defaults: appBackendDefaults()).key(for: appBackendTestUser), key)
        for (name, value) in defaults.dictionaryRepresentation() {
            XCTAssertFalse(name.lowercased().contains(appBackendTestUser.uuidString.lowercased()))
            XCTAssertFalse(String(describing: value).lowercased().contains(appBackendTestUser.uuidString.lowercased()))
        }
        store.clear()
        XCTAssertFalse(store.contains(appBackendTestUser))
    }

    func testPermissionObserverShowsPoweredOffWhileParticipationIsOff() async throws {
        let radio = ConsentTestTransport()
        let composition = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse(), appOwnProfileResponse()]),
            session: try appBackendTestSession(), transportFactory: { radio })
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        await flow.onboarding?.requestBluetooth()
        radio.powerOff()
        XCTAssertEqual(flow.bluetooth, .poweredOff)
        XCTAssertEqual(flow.onboarding?.bluetooth, .poweredOff)
        XCTAssertEqual(flow.settings?.bluetooth, .poweredOff)
        XCTAssertFalse(composition.isParticipating)
        radio.emit(.availabilityChanged(.available))
        XCTAssertEqual(flow.bluetooth, .available)
        XCTAssertEqual(AccountFlowModel.permission(.init(radioAvailability: .unavailable)), .unavailable)
    }

    #if DEVELOPMENT_BUILD
    func testTemporarySignInRoutesFromWelcomeThroughTheLoadedProfile() async throws {
        let composition = appFlowComposition(transport: AppBackendTransport([appBackendAuthResponse(), appAccountOK(), appAccountOK(), appOwnProfileResponse(.init())]))
        let flow = AccountFlowModel(composition: composition, defaults: appBackendDefaults())
        await flow.start()
        XCTAssertTrue(flow.usesSignInWelcome)
        try await composition.account.signInTemporaryAccount(isAdult: true, acceptsTermsAndPrivacy: true)
        try await appBackendEventually { flow.root == .onboarding }
        XCTAssertEqual(flow.onboarding?.step, .basics)
        XCTAssertFalse(flow.usesSignInWelcome)
    }
    #endif
}

@MainActor
private func appFlowComposition(configuration: BackendConfiguration? = appBackendTestConfiguration(),
    transport: any HTTPTransport = AppBackendTransport(), session: BackendSession? = nil,
    sessionStore: (any SessionStore)? = nil, defaults: UserDefaults? = nil,
    transportFactory: @escaping @MainActor () async -> any BluetoothTransport = { ConsentTestTransport() }) -> AppComposition {
    AppComposition(configuration: configuration, defaults: defaults ?? appBackendDefaults(userID: session?.userID ?? appBackendTestUser), notificationCenter: TestLocalNotificationCenter(), trialLogURL: appTrialLogURL(), transport: transport,
        keychain: AppMemoryKeychain(), sessionStore: sessionStore ?? InMemorySessionStore(session: session), serverTokenStore: InMemoryTokenBatchStore(),
        signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { InMemoryReceiptQueue() },
        transportFactory: transportFactory,
        // Account-flow fixtures keep their request order independently of host activation.
        productLifecycle: ProductSceneLifecycle(phase: .background, notifications: NotificationCenter()),
        now: { appBackendTestNow }, timeZone: { "Asia/Tokyo" })
}

@MainActor
private func flowSignIn(_ composition: AppComposition) async throws {
    try await composition.account.signIn(using: AuthRequest(path: "signin", body: Data()),
        isAdult: true, acceptsTermsAndPrivacy: true, termsVersion: "fixture-terms", privacyVersion: "fixture-privacy")
}

private actor HeldAppSessionStore: SessionStore {
    private var session: BackendSession?
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    var isHeld: Bool { waiting != nil }
    init(session: BackendSession) { self.session = session }
    func load() async throws -> BackendSession? {
        if !released { await withCheckedContinuation { waiting = $0 } }
        return session
    }
    func save(_ session: BackendSession) async throws { self.session = session }
    func clear() async throws { session = nil }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

@MainActor
private final class ConsentTestTransport: BluetoothTransport, RuntimeBluetoothStateReporting {
    nonisolated let events: AsyncStream<BluetoothEvent>
    private let continuation: AsyncStream<BluetoothEvent>.Continuation
    private var commands: [BluetoothCommand] = []
    private var receive: (@MainActor (RadioAvailability, Bool) -> Void)?
    init() {
        let stream = AsyncStream<BluetoothEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }
    nonisolated func execute(_ command: BluetoothCommand) async { await record(command) }
    private func record(_ command: BluetoothCommand) { commands.append(command) }
    func observeRadioState(_ receive: @escaping @MainActor (RadioAvailability, Bool) -> Void) { self.receive = receive }
    func emit(_ event: BluetoothEvent) {
        if case .availabilityChanged(let state) = event { receive?(state, false) }
        continuation.yield(event)
    }
    func powerOff() { receive?(.unavailable, true) }
    func recorded() -> [BluetoothCommand] { commands }
}
