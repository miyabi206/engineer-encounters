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
        let cases: [(OwnProfileState, OnboardingStep)] = [(basics, .basics), (selections, .interests), (appPresentationProfile(), .permissions)]
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
            XCTAssertFalse(try XCTUnwrap(flow.settings).allowsDiscoveryActivation)
            XCTAssertEqual(builds, 0)
            XCTAssertFalse(flow.usesSignInWelcome)
        }
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
        let composition = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse()]),
            session: try appBackendTestSession())
        let flow = AccountFlowModel(composition: composition, defaults: defaults)
        await flow.start()
        let onboarding = try XCTUnwrap(flow.onboarding)
        XCTAssertFalse(defaults.bool(forKey: AccountFlowModel.completionKey(appBackendTestUser)))
        await onboarding.finish(discovery: false)
        XCTAssertEqual(flow.root, .settings)
        XCTAssertTrue(defaults.bool(forKey: AccountFlowModel.completionKey(appBackendTestUser)))
        XCTAssertFalse(try XCTUnwrap(flow.settings).showsDiscoveryExplanation)
        XCTAssertFalse(try XCTUnwrap(flow.settings).allowsDiscoveryActivation)
        XCTAssertNil(flow.onboarding)
        try await composition.account.signOut()
        try await appBackendEventually { flow.root == .welcome }
        XCTAssertNil(flow.settings)

        let sameAccount = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse()]),
            session: try appBackendTestSession())
        let relaunched = AccountFlowModel(composition: sameAccount, defaults: defaults)
        await relaunched.start()
        XCTAssertEqual(relaunched.root, .settings)

        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        let otherAccount = appFlowComposition(transport: AppBackendTransport([appAccountOK(), appOwnProfileResponse()]),
            session: try appBackendTestSession(userID: otherID))
        let other = AccountFlowModel(composition: otherAccount, defaults: defaults)
        await other.start()
        XCTAssertEqual(other.root, .onboarding)
        XCTAssertFalse(defaults.bool(forKey: AccountFlowModel.completionKey(otherID)))
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
        await radio.emit(.availabilityChanged(.available))
        try await appBackendEventually { onboarding.bluetooth == .available }
        XCTAssertEqual(builds, 1)
        XCTAssertFalse(composition.isParticipating)
        XCTAssertFalse(composition.status.discoveryOn)
        let commands = await radio.recorded()
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
        XCTAssertFalse(defaults.bool(forKey: AccountFlowModel.completionKey(appBackendTestUser)))
        flow.resumeOnboarding()
        XCTAssertEqual(flow.root, .onboarding)
        XCTAssertFalse(try XCTUnwrap(flow.onboarding).hasCompleted)
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
    transport: AppBackendTransport = AppBackendTransport(), session: BackendSession? = nil,
    transportFactory: @escaping @MainActor () async -> any BluetoothTransport = { ConsentTestTransport() }) -> AppComposition {
    AppComposition(configuration: configuration, defaults: appBackendDefaults(), transport: transport,
        sessionStore: InMemorySessionStore(session: session), serverTokenStore: InMemoryTokenBatchStore(),
        signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { InMemoryReceiptQueue() },
        transportFactory: transportFactory, now: { appBackendTestNow }, timeZone: { "Asia/Tokyo" })
}

private actor ConsentTestTransport: BluetoothTransport {
    nonisolated let events: AsyncStream<BluetoothEvent>
    private let continuation: AsyncStream<BluetoothEvent>.Continuation
    private var commands: [BluetoothCommand] = []
    init() {
        let stream = AsyncStream<BluetoothEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }
    func execute(_ command: BluetoothCommand) async { commands.append(command) }
    func emit(_ event: BluetoothEvent) { continuation.yield(event) }
    func recorded() -> [BluetoothCommand] { commands }
}
