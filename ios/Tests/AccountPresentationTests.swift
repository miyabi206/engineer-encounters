import EncounterBackend
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class AccountPresentationTests: XCTestCase {
    func testLocallyRefusedBluetoothActionNeverDiscardsHealthyAccount() async throws {
        for code in [ProfileActionError.Code.notAuthenticated, .unavailable] {
            let account = try await makePresentationAccount(transport: AppBackendTransport([appAccountOK()]))
            var discards = 0
            account.prepareToDiscardSession = { discards += 1 }
            let actions = account.profileActions { throw ProfileActionError(code: code) }
            do { _ = try await actions.requestBluetooth(); XCTFail("Local refusal must surface") }
            catch { XCTAssertEqual(error as? ProfileActionError, .init(code: code)) }
            XCTAssertEqual(account.state, .signedIn(appBackendTestUser))
            XCTAssertEqual(discards, 0)
            let session = try await account.sessions?.session()
            XCTAssertEqual(session?.userID, appBackendTestUser)
        }
    }

    func testEveryProfileWriteUsesItsContractParametersAndPublishesConfirmedProfile() async throws {
        let cases: [(String, [String: Any], @MainActor (ProfileActions) async throws -> OwnProfileState)] = [
            ("update_own_profile", ["display_name": "名前", "introduction": "紹介", "contact_detail": "連絡先"],
                { try await $0.saveProfile("名前", "紹介", "連絡先") }),
            ("set_own_interests", ["interest_ids": ["a", "b"]], { try await $0.saveInterests(["b", "a"]) }),
            ("set_own_purposes", ["purposes": ["collaboration", "discovery"]],
                { try await $0.savePurposes([.discovery, .collaboration]) }),
            ("set_discovery", ["enabled": false], { try await $0.setDiscovery(false) }),
            ("set_minimum_shared_interests", ["value": 3], { try await $0.setMinimumSharedInterests(3) }),
            ("set_field_visibility", ["field": "contact_detail", "level": "compatible_only"],
                { try await $0.setFieldVisibility(.contactDetail, .compatibleOnly) })
        ]
        let expected = appPresentationProfile()
        for (name, parameters, operation) in cases {
            let transport = AppBackendTransport([appAccountOK(), appAccountOK(), appOwnProfileResponse(expected)])
            let account = try await makePresentationAccount(transport: transport)
            let actions = account.profileActions { .notRequested }
            let result = try await operation(actions)
            XCTAssertEqual(result, expected)
            XCTAssertEqual(account.profile, expected)
            let requests = await transport.recorded()
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["register_time_zone", name, "get_own_profile"])
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? NSDictionary
            XCTAssertEqual(body, parameters as NSDictionary)
        }
    }

    func testCatalogueAndBluetoothActionsAlsoRefreshConfirmedProfile() async throws {
        let catalogue = HTTPResponse(data: Data("""
        [{"interest_id":"a","label_ja":"技術","label_en":"Technology","display_order":1}]
        """.utf8), statusCode: 200)
        let transport = AppBackendTransport([appAccountOK(), catalogue, appOwnProfileResponse(), appOwnProfileResponse()])
        let account = try await makePresentationAccount(transport: transport)
        var requests = 0
        let actions = account.profileActions { requests += 1; return .available }
        let interests = try await actions.loadInterests()
        XCTAssertEqual(interests, [InterestOption(id: "a", labelJapanese: "技術", labelEnglish: "Technology")])
        let bluetooth = try await actions.requestBluetooth()
        XCTAssertEqual(bluetooth, .available)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(account.profile, appPresentationProfile())
        let recorded = await transport.recorded()
        XCTAssertEqual(recorded.map { $0.url?.lastPathComponent },
            ["register_time_zone", "list_interests", "get_own_profile", "get_own_profile"])
    }

    func testEveryContractErrorFromAnActionPreservesItsCodeAndFieldNames() async throws {
        let failures: [(String, [String], ProfileActionError.Code)] = [
            ("not_authenticated", [], .notAuthenticated), ("account_not_ready", [], .accountNotReady),
            ("declaration_required", [], .declarationRequired),
            ("invalid_input", ["display_name", "interest_ids"], .invalidInput),
            ("prerequisite_missing", ["introduction", "link"], .prerequisiteMissing),
            ("rate_limited", [], .rateLimited), ("not_found", [], .notFound)
        ]
        for (code, fields, expected) in failures {
            let data = try JSONSerialization.data(withJSONObject: ["message": code, "details": fields.joined(separator: ",")])
            let failure = HTTPResponse(data: data, statusCode: 400)
            var responses = [appAccountOK(), failure]
            // The client retries authentication once before surfacing the contract failure.
            if code == "not_authenticated" { responses += [appBackendAuthResponse(), failure] }
            let transport = AppBackendTransport(responses)
            let account = try await makePresentationAccount(transport: transport)
            do {
                _ = try await account.profileActions { .notRequested }.saveProfile("name", "intro", "")
                XCTFail("Failed contract operation must throw")
            } catch {
                XCTAssertEqual(error as? ProfileActionError, .init(code: expected, fields: fields))
            }
            XCTAssertNil(account.profile)
        }
        let clientFailures: [BackendError] = [.invalidRequest, .invalidResponse, .transportFailure, .storageFailure, .httpFailure(statusCode: 503)]
        for failure in clientFailures { XCTAssertEqual(AccountModel.presentationError(failure), .init(code: .unavailable)) }
    }

    func testSignedOutActionsDoNotCallBackendOrAskForBluetooth() async throws {
        let transport = AppBackendTransport([HTTPResponse(data: Data("[]".utf8), statusCode: 200)])
        let configuration = appBackendTestConfiguration()
        let sessions = SessionManager(configuration: configuration, transport: transport,
            store: InMemorySessionStore(), now: { appBackendTestNow })
        // Keep an independently authenticated service wired in. Missing action guards
        // would reach this transport, rather than failing on an empty credential store.
        let liveSessions = SessionManager(configuration: configuration, transport: transport,
            store: InMemorySessionStore(session: try appBackendTestSession()), now: { appBackendTestNow })
        let service = OwnAccountService(client: RemoteProcedureClient(configuration: configuration, transport: transport, sessions: liveSessions))
        let account = AccountModel(sessions: sessions, service: service, defaults: appBackendDefaults())
        await account.restore()
        XCTAssertEqual(account.state, .signedOut)
        var asked = false
        let actions = account.profileActions { asked = true; return .available }
        do { _ = try await actions.requestBluetooth(); XCTFail("Signed-out action must fail") }
        catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .notAuthenticated)) }
        do { _ = try await actions.saveInterests(["a"]); XCTFail("Signed-out write must fail") }
        catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .notAuthenticated)) }
        XCTAssertFalse(asked)
        let recorded = await transport.recorded()
        XCTAssertTrue(recorded.isEmpty)
        _ = try await service.listInterests()
        let controlRequests = await transport.recorded()
        XCTAssertEqual(controlRequests.map { $0.url?.lastPathComponent }, ["list_interests"])
    }

    func testEveryScreenActionAndProfileReadCleansUpADeadSession() async throws {
        let operations: [@MainActor (AccountModel) async throws -> Void] = [
            { _ = try await $0.loadOwnProfile() },
            { _ = try await $0.profileActions { .available }.loadInterests() },
            { _ = try await $0.profileActions { .available }.saveProfile("name", "intro", "") },
            { _ = try await $0.profileActions { .available }.saveInterests(["a"]) },
            { _ = try await $0.profileActions { .available }.savePurposes([.discovery]) },
            { _ = try await $0.profileActions { .available }.setDiscovery(false) },
            { _ = try await $0.profileActions { .available }.setMinimumSharedInterests(2) },
            { _ = try await $0.profileActions { .available }.setFieldVisibility(.contactDetail, .private) },
            { _ = try await $0.profileActions { throw BackendError.notAuthenticated }.requestBluetooth() }
        ]
        for operation in operations {
            let transport = AppBackendTransport([appAccountOK(), appNotAuthenticatedResponse(),
                appBackendAuthResponse(), appNotAuthenticatedResponse()])
            let account = try await makePresentationAccount(transport: transport)
            var prepared = 0
            var changed = 0
            account.prepareForSessionChange = { prepared += 1 }
            account.sessionDidChange = { recreate in XCTAssertTrue(recreate); changed += 1 }
            account.onboardingCompletion.finish(appBackendTestUser)
            do { try await operation(account); XCTFail("Dead account action must fail") }
            catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .notAuthenticated)) }
            XCTAssertEqual(account.state, .signedOut)
            XCTAssertNil(account.profile)
            XCTAssertEqual(prepared, 1)
            XCTAssertEqual(changed, 1)
            XCTAssertFalse(account.onboardingCompletion.contains(appBackendTestUser))
            do { _ = try await account.sessions?.session(); XCTFail("Cleanup must clear the session manager") }
            catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        }
    }

    func testCommittedWritesReturnAcceptedFieldsAndRemainStaleUntilReread() async throws {
        let cases: [(String, @MainActor (ProfileActions) async throws -> OwnProfileState, (inout OwnProfileState) -> Void)] = [
            ("update_own_profile", { try await $0.saveProfile("changed", "intro", "contact") }, {
                $0.displayName = "changed"; $0.introduction = "intro"; $0.contactDetail = "contact"
            }),
            ("set_own_interests", { try await $0.saveInterests(["b"]) }, { $0.interestIDs = ["b"] }),
            ("set_own_purposes", { try await $0.savePurposes([.discovery]) }, { $0.purposes = [.discovery] }),
            ("set_discovery", { try await $0.setDiscovery(true) }, { $0.discoveryOn = true }),
            ("set_minimum_shared_interests", { try await $0.setMinimumSharedInterests(5) }, { $0.minimumSharedInterests = 5 }),
            ("set_field_visibility", { try await $0.setFieldVisibility(.contactDetail, .compatibleOnly) }, {
                $0.fieldVisibility[.contactDetail] = .compatibleOnly
            })
        ]
        for (name, operation, apply) in cases {
            var expected = appPresentationProfile()
            apply(&expected)
            let transport = AppBackendTransport([appAccountOK(), appOwnProfileResponse(), appAccountOK(),
                HTTPResponse(data: Data(), statusCode: 503), appOwnProfileResponse(expected)])
            let account = try await makePresentationAccount(transport: transport)
            _ = try await account.loadOwnProfile()
            let saved = try await operation(account.profileActions { .available })
            XCTAssertEqual(saved, expected)
            XCTAssertEqual(account.profile, expected)
            XCTAssertTrue(account.profileIsStale)
            let reread = try await account.loadOwnProfile()
            XCTAssertEqual(reread, expected)
            XCTAssertFalse(account.profileIsStale)
            let paths = await transport.recorded().map { $0.url?.lastPathComponent }
            XCTAssertEqual(paths.filter { $0 == name }.count, 1)
            XCTAssertEqual(paths.filter { $0 == "get_own_profile" }.count, 3)
        }
    }

    func testCommittedWriteWithCancelledReadStillSucceeds() async throws {
        let transport = ControlledAppBackendTransport([
            "register_time_zone": [.response(appAccountOK())],
            "get_own_profile": [.response(appOwnProfileResponse()), .cancelled],
            "set_minimum_shared_interests": [.response(appAccountOK())]
        ])
        let account = try await makePresentationAccount(transport: transport)
        _ = try await account.loadOwnProfile()
        let saved = try await account.profileActions { .available }.setMinimumSharedInterests(5)
        XCTAssertEqual(saved.minimumSharedInterests, 5)
        XCTAssertTrue(account.profileIsStale)
    }

    func testCommittedWriteWithDeadSessionDuringFollowUpReadIsSavedAndSignsOut() async throws {
        let transport = AppBackendTransport([appAccountOK(), appOwnProfileResponse(), appAccountOK(),
            appNotAuthenticatedResponse(), appBackendAuthResponse(), appNotAuthenticatedResponse()])
        let account = try await makePresentationAccount(transport: transport)
        _ = try await account.loadOwnProfile()
        let saved = try await account.profileActions { .available }.setMinimumSharedInterests(5)
        XCTAssertEqual(saved.minimumSharedInterests, 5)
        XCTAssertEqual(account.state, .signedOut)
        XCTAssertNil(account.profile)
        XCTAssertFalse(account.profileIsStale)
    }

    func testCatalogueAndBluetoothSucceedWhenTheirAppendedProfileReadsFail() async throws {
        for dead in [false, true] {
            for bluetooth in [false, true] {
                let catalogue = HTTPResponse(data: Data(#"[{"interest_id":"a","label_ja":"技術","label_en":"Technology","display_order":1}]"#.utf8), statusCode: 200)
                var replies = [appAccountOK()]
                if !bluetooth { replies.append(catalogue) }
                replies.append(dead ? appNotAuthenticatedResponse() : HTTPResponse(data: Data(), statusCode: 503))
                if dead { replies += [appBackendAuthResponse(), appNotAuthenticatedResponse()] }
                let account = try await makePresentationAccount(transport: AppBackendTransport(replies))
                let actions = account.profileActions { .available }
                if bluetooth {
                    let state = try await actions.requestBluetooth()
                    XCTAssertEqual(state, .available)
                } else {
                    let interests = try await actions.loadInterests()
                    XCTAssertEqual(interests.map(\.id), ["a"])
                }
                XCTAssertEqual(account.state, dead ? .signedOut : .signedIn(appBackendTestUser))
            }
        }
    }

    func testOnboardingRetryUsesTheFailedOperationAndReceivesBackendFieldError() async throws {
        let failure = HTTPResponse(data: Data(#"{"message":"invalid_input","details":"display_name"}"#.utf8), statusCode: 400)
        let transport = AppBackendTransport([appAccountOK(), failure, appAccountOK(), appOwnProfileResponse()])
        let account = try await makePresentationAccount(transport: transport)
        let model = OnboardingModel(profile: .init(), actions: account.profileActions { .notRequested },
            onExit: {}, onFinish: { _ in }, onBluetoothRecovery: {})
        model.displayName = "名前"
        model.introduction = "紹介"
        await model.saveBasics()
        XCTAssertEqual(model.failedOperation, .basics)
        XCTAssertEqual(model.actionError, .init(code: .invalidInput, fields: ["display_name"]))
        await model.retry()
        XCTAssertEqual(model.step, .interests)
        XCTAssertNil(model.failedOperation)
        XCTAssertEqual(model.profile, appPresentationProfile())
    }

    #if DEVELOPMENT_BUILD
    func testBothCallerDeclarationsAreRequiredBeforeAnySignInIO() async throws {
        for declaration in [SignInDeclarations(), SignInDeclarations(isAdult: true),
                            SignInDeclarations(acceptsTermsAndPrivacy: true)] {
            let transport = AppBackendTransport()
            let configuration = appBackendTestConfiguration()
            let sessions = SessionManager(configuration: configuration, transport: transport,
                store: InMemorySessionStore(), now: { appBackendTestNow })
            let account = AccountModel(sessions: sessions,
                service: OwnAccountService(client: RemoteProcedureClient(configuration: configuration, transport: transport, sessions: sessions)))
            await account.restore()
            do {
                try await account.signInTemporaryAccount(isAdult: declaration.isAdult,
                    acceptsTermsAndPrivacy: declaration.acceptsTermsAndPrivacy)
                XCTFail("Unchecked declarations must prevent sign-in")
            } catch { XCTAssertEqual(error as? BackendError, .declarationRequired) }
            let recorded = await transport.recorded()
            XCTAssertTrue(recorded.isEmpty)
            XCTAssertEqual(account.state, .signedOut)
        }
    }
    #endif
}

@MainActor
private func makePresentationAccount(transport: any HTTPTransport) async throws -> AccountModel {
    let configuration = appBackendTestConfiguration()
    let sessions = SessionManager(configuration: configuration, transport: transport,
        store: InMemorySessionStore(session: try appBackendTestSession()), now: { appBackendTestNow })
    let service = OwnAccountService(client: RemoteProcedureClient(configuration: configuration, transport: transport, sessions: sessions))
    let account = AccountModel(sessions: sessions, service: service, defaults: appBackendDefaults(), timeZone: { "Asia/Tokyo" })
    await account.restore()
    return account
}

func appAccountOK() -> HTTPResponse { HTTPResponse(data: Data(), statusCode: 204) }

func appNotAuthenticatedResponse() -> HTTPResponse {
    HTTPResponse(data: Data(#"{"message":"not_authenticated"}"#.utf8), statusCode: 400)
}

func appPresentationProfile() -> OwnProfileState {
    OwnProfileState(displayName: "名前", introduction: "紹介", contactDetail: "連絡先", interestIDs: ["a"],
        purposes: [.collaboration], minimumSharedInterests: 3,
        fieldVisibility: [.displayName: .everyoneEligible, .introduction: .compatibleOnly,
            .interests: .everyoneEligible, .purposes: .everyoneEligible, .contactDetail: .private],
        prerequisites: .init(displayName: true, introduction: true, interest: true),
        declarationsRecorded: true, timeZone: "Asia/Tokyo")
}

func appOwnProfileResponse(_ profile: OwnProfileState = appPresentationProfile()) -> HTTPResponse {
    let visibility = Dictionary(uniqueKeysWithValues: profile.fieldVisibility.map { ($0.key.rawValue, $0.value.rawValue) })
    let value: [String: Any] = [
        "display_name": profile.displayName, "introduction": profile.introduction, "contact_detail": profile.contactDetail,
        "interests": profile.interestIDs.sorted(), "purposes": profile.purposes.map(\.rawValue).sorted(),
        "minimum_shared_interests": profile.minimumSharedInterests, "field_visibility": visibility,
        "discovery_on": profile.discoveryOn, "link_count": profile.linkCount,
        "prerequisites": ["display_name": profile.prerequisites.displayName, "introduction": profile.prerequisites.introduction,
            "interest": profile.prerequisites.interest, "link": profile.prerequisites.link],
        "declarations_recorded": profile.declarationsRecorded, "time_zone": profile.timeZone, "moderation_state": profile.moderationState
    ]
    return HTTPResponse(data: try! JSONSerialization.data(withJSONObject: value), statusCode: 200)
}
