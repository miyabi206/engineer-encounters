import EncounterDomain
import EncounterBackend
import EncounterStorage
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class LinkAdapterTests: XCTestCase {
    func testUnauthorizedLinkActionsSignOutWhenRefreshClearsCredentialsAndReadiness() async throws {
        let actions: [@MainActor (LinkActions) async throws -> Void] = [
            { _ = try await $0.loadLinks() }, { _ = try await $0.listRepositories(1) },
            { _ = try await $0.connectGitHub() }]
        for action in actions {
            let store = InMemorySessionStore(session: try appBackendTestSession())
            let transport = AppBackendTransport([appAccountOK(), HTTPResponse(data: Data(), statusCode: 401),
                linkResponse(["code": 400, "error_code": "refresh_token_not_found"], status: 400)])
            let composition = try linkComposition(transport: transport, store: store)
            await composition.waitForRestoration()
            XCTAssertTrue(composition.account.canRefreshSession())
            do { try await action(composition.linkAdapter.actions()); XCTFail("Dead refresh must reject action") }
            catch { XCTAssertEqual(error as? LinkActionError, .init(code: .unavailable, details: ["not_authenticated"])) }
            XCTAssertEqual(composition.account.state, .signedOut)
            let saved = try await store.load()
            XCTAssertNil(saved)
            let requests = await transport.recorded()
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(requests.last?.url?.lastPathComponent, "token")
        }
    }

    func testAllActionsMapWireValuesAndSendOnlyContractParameters() async throws {
        let transport = AppBackendTransport([appAccountOK(), linkResponse([linkJSON()]),
            linkResponse(connectionJSON()), linkResponse(["repositories": [repositoryJSON()], "next_page": 2]),
            linkResponse(["preview": previewJSON()]), linkResponse(["link": linkJSON()]),
            appOwnProfileResponse(appLinkedPresentationProfile()), linkResponse(linkJSON()),
            appOwnProfileResponse(appLinkedPresentationProfile()), linkResponse([linkJSON()]),
            linkResponse(["link_id": linkTestID, "preview": previewJSON()]),
            linkResponse(["deleted": true]), appOwnProfileResponse(), linkResponse([])])
        let composition = try linkComposition(transport: transport)
        await composition.waitForRestoration()
        let actions = composition.linkAdapter.actions()
        let links = try await actions.loadLinks()
        let link = try XCTUnwrap(links.first)
        XCTAssertEqual(link.id, linkTestID)
        XCTAssertEqual(link.source, .github)
        XCTAssertEqual(link.sourceItemID, "42")
        XCTAssertEqual(link.repositoryName, "repo")
        XCTAssertEqual(link.sourceLabel, "GitHub")
        XCTAssertEqual(link.url.absoluteString, "https://github.com/owner/repo")
        XCTAssertEqual(link.visibility, .private)
        XCTAssertTrue(link.verified)
        XCTAssertEqual(link.title, "Repo")
        XCTAssertEqual(link.description, "Description")
        XCTAssertEqual(link.mainLanguage, "Swift")
        XCTAssertEqual(link.tags, ["ios"])
        XCTAssertEqual(link.openingText, "Opening")
        XCTAssertEqual(link.displayOrder, 0)
        let connection = try await actions.loadConnection()
        XCTAssertEqual(connection, .connected(handle: "owner"))
        let page = try await actions.listRepositories(1)
        XCTAssertEqual(page.nextPage, 2)
        let repository = try XCTUnwrap(page.repositories.first)
        XCTAssertEqual(repository.repositoryID, "42")
        XCTAssertEqual(repository.repositoryName, "repo")
        let draft = try await actions.previewRepository(repository)
        XCTAssertNil(draft.visibility)
        XCTAssertNil(draft.existingLinkID)
        XCTAssertTrue(draft.verified)
        XCTAssertEqual(draft.openingText, "Opening")
        let saved = try await actions.saveRepository(draft, .private, true)
        XCTAssertEqual(saved, link)
        let updated = try await actions.updateLink(link.id, draft, .compatibleOnly)
        XCTAssertEqual(updated, link)
        let reordered = try await actions.reorderLinks([link.id])
        XCTAssertEqual(reordered, links)
        let refresh = try await actions.refreshPreview(LinkPreviewDraft(link: link))
        XCTAssertEqual(refresh, draft)
        let remaining = try await actions.deleteLink(link.id)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(composition.account.profile?.linkCount, 0)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["register_time_zone", "list_own_links",
            "get_github_connection", "github-links", "github-links", "github-links", "get_own_profile",
            "update_own_link", "get_own_profile", "reorder_own_links", "github-links", "delete_own_link",
            "get_own_profile", "list_own_links"])
        let metadata: [String: Any] = ["title": "Repo", "description": "Description", "main_language": "Swift",
            "tags": ["ios"], "opening_text": "Opening", "visibility": "private"]
        var save = metadata
        save.merge(["action": "save_repository", "repository_id": "42", "repository_name": "repo", "replace_existing": true]) { _, rhs in rhs }
        var update = metadata
        update["visibility"] = "compatible_only"; update["link_id"] = linkTestID
        let expected: [(Int, [String: Any])] = [
            (1, [:]), (2, [:]), (3, ["action": "list_repositories", "page": 1]),
            (4, ["action": "preview_repository", "repository_id": "42", "repository_name": "repo"]),
            (5, save), (7, update), (9, ["link_ids": [linkTestID]]),
            (10, ["action": "refresh_preview", "link_id": linkTestID]), (11, ["link_id": linkTestID])]
        for (index, value) in expected {
            let actual = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[index].httpBody)) as? NSDictionary
            XCTAssertEqual(actual, value as NSDictionary)
        }
    }

    func testErrorsPreserveCodesDetailsAndEditableFieldNames() async throws {
        let errors: [(BackendError, LinkActionError)] = [
            (.invalidInput(fields: ["title", "main_language", "opening_text", "tags", "visibility", "link_id"]),
             .init(code: .invalidInput, fields: [.title, .mainLanguage, .openingText, .tags, .visibility],
                   details: ["title", "main_language", "opening_text", "tags", "visibility", "link_id"])),
            (.prerequisiteMissing(fields: ["link"]), .init(code: .prerequisiteMissing, details: ["link"])),
            (.prerequisiteMissing(fields: ["github"]), .init(code: .prerequisiteMissing, details: ["github"])),
            (.prerequisiteMissing(fields: ["github_reader"]), .init(code: .prerequisiteMissing, details: ["github_reader"])),
            (.prerequisiteMissing(fields: ["refresh_confirmation"]), .init(code: .prerequisiteMissing, details: ["refresh_confirmation"])),
            (.rateLimited, .init(code: .unavailable, details: ["rate_limited"])),
            (.notFound, .init(code: .unavailable, details: ["not_found"])),
            (.notAuthenticated, .init(code: .unavailable, details: ["not_authenticated"])),
            (.transportFailure, .init(code: .unavailable, details: ["transport_failure"])),
            (.storageFailure, .init(code: .unavailable, details: ["storage_failure"]))]
        for (error, expected) in errors { XCTAssertEqual(LinkAdapter.presentationError(error), expected) }
        for detail in ["link", "github", "github_reader", "refresh_confirmation"] {
            let transport = AppBackendTransport([appAccountOK(), linkResponse(["error": ["code": "prerequisite_missing", "details": [detail]]], status: 400)])
            let composition = try linkComposition(transport: transport)
            await composition.waitForRestoration()
            do { _ = try await composition.linkAdapter.actions().listRepositories(1); XCTFail("Expected refusal") }
            catch { XCTAssertEqual(error as? LinkActionError, .init(code: .prerequisiteMissing, details: [detail])) }
        }
    }

    func testEveryActionMapsItsBackendFailureWithoutPublishingGuessedResults() async throws {
        let wire = try JSONDecoder().decode(LinkTransfer.self, from: linkResponse(linkJSON()).data)
        let link = try LinkAdapter.present(wire)
        let draft = LinkPreviewDraft(link: link)
        let repository = GitHubRepositoryChoice(repositoryID: "42", repositoryName: "repo", title: "Repo", url: link.url)
        let actions: [@MainActor (LinkActions) async throws -> Void] = [
            { _ = try await $0.loadLinks() }, { _ = try await $0.loadConnection() },
            { _ = try await $0.listRepositories(1) }, { _ = try await $0.previewRepository(repository) },
            { _ = try await $0.saveRepository(draft, .private, false) },
            { _ = try await $0.updateLink(link.id, draft, .private) },
            { _ = try await $0.deleteLink(link.id) }, { _ = try await $0.reorderLinks([link.id]) },
            { _ = try await $0.refreshPreview(draft) }]
        for action in actions {
            for code in ["invalid_input", "prerequisite_missing", "rate_limited", "not_found", "not_authenticated"] {
                let details = code == "invalid_input" ? ["title"] : code == "prerequisite_missing" ? ["github_reader"] : []
                let rpc = linkResponse(["message": code, "details": details.joined(separator: ",")], status: 400)
                let edge = linkResponse(["error": ["code": code, "details": details]], status: 400)
                // Both clients accept their own error envelope; select it from the requested endpoint.
                let transport = LinkFailureTransport(rpc: rpc, edge: edge)
                let composition = try linkComposition(transport: transport)
                await composition.waitForRestoration()
                do { try await action(composition.linkAdapter.actions()); XCTFail("Expected action failure") }
                catch {
                    let expected: LinkActionError
                    switch code {
                    case "invalid_input": expected = .init(code: .invalidInput, fields: [.title], details: details)
                    case "prerequisite_missing": expected = .init(code: .prerequisiteMissing, details: details)
                    default: expected = .init(code: .unavailable, details: [code])
                    }
                    XCTAssertEqual(error as? LinkActionError, expected)
                }
                XCTAssertNil(composition.linkAdapter.links)
                XCTAssertNil(composition.account.profile)
                XCTAssertEqual(composition.account.state, code == "not_authenticated" ? .signedOut : .signedIn(appBackendTestUser))
            }
        }
    }

    func testServicesRebuildForNewSessionAndOldActionsCannotReachTheBackend() async throws {
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        let transport = AppBackendTransport([appAccountOK(), linkResponse([linkJSON()]),
            appBackendAuthResponse(userID: second), appAccountOK(), appAccountOK(), linkResponse([])])
        let composition = try linkComposition(transport: transport)
        await composition.waitForRestoration()
        let obsolete = composition.linkAdapter.actions()
        _ = try await obsolete.loadLinks()
        try await composition.account.signOut()
        try await composition.account.signIn(using: AuthRequest(path: "signin", body: Data()),
            isAdult: true, acceptsTermsAndPrivacy: true, termsVersion: "fixture", privacyVersion: "fixture")
        let before = await transport.recorded().count
        do { _ = try await obsolete.loadLinks(); XCTFail("Old closure must fail") }
        catch { XCTAssertEqual(error as? LinkActionError, .init(code: .unavailable, details: ["not_authenticated"])) }
        do { _ = try await obsolete.connectGitHub(); XCTFail("Old connection closure must fail") }
        catch { XCTAssertEqual(error as? LinkActionError, .init(code: .unavailable, details: ["not_authenticated"])) }
        XCTAssertEqual(composition.linkAdapter.connection, .notConnected)
        XCTAssertNil(composition.linkAdapter.connectionError)
        let after = await transport.recorded().count
        XCTAssertEqual(before, after)
        let fresh = try await composition.linkAdapter.actions().loadLinks()
        XCTAssertTrue(fresh.isEmpty)
        XCTAssertEqual(composition.account.state, .signedIn(second))
        XCTAssertEqual(composition.linkAdapter.links, [])
    }

    func testObsoleteBackendResponseCannotPublishOwnedLinks() async throws {
        let transport = ControlledAppBackendTransport(["register_time_zone": [.response(appAccountOK())], "list_own_links": [.held]])
        let composition = try linkComposition(transport: transport)
        await composition.waitForRestoration()
        let loading = Task { try await composition.linkAdapter.actions().loadLinks() }
        try await appBackendEventually { await transport.isHeld("list_own_links") }
        let generation = UUID()
        composition.account.bindingGeneration = { generation }
        await transport.release("list_own_links", with: linkResponse([linkJSON()]))
        do { _ = try await loading.value; XCTFail("Old backend response must fail") }
        catch { XCTAssertEqual(error as? LinkActionError, .init(code: .unavailable, details: ["not_authenticated"])) }
        XCTAssertNil(composition.linkAdapter.links)
    }

    func testConnectionSuccessSyncsThenReloadsWithoutSwitchingAccounts() async throws {
        let runner = FakeGitHubWebAuthenticationRunner()
        let transport = AppBackendTransport([appAccountOK(), missingGitHubResponse(), authorizationResponse(), appBackendAuthResponse(),
            linkResponse(connectionJSON()), linkResponse(connectionJSON())])
        let composition = try linkComposition(transport: transport, runner: runner)
        await composition.waitForRestoration()
        let result = try await composition.linkAdapter.actions().connectGitHub()
        XCTAssertEqual(result, .connected(handle: "owner"))
        XCTAssertEqual(composition.linkAdapter.connection, result)
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        XCTAssertEqual(runner.scheme, "engineer-encounters")
        XCTAssertEqual(runner.address?.host, "github.com")
        let requests = await transport.recorded()
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["register_time_zone", "github-links", "authorize", "token", "github-links", "get_github_connection"])
        let sync = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[4].httpBody)) as? NSDictionary
        XCTAssertEqual(sync, ["action": "sync_identity"] as NSDictionary)
    }

    func testConnectionCancellationFailureAndForeignAccountKeepInitiatingSession() async throws {
        for outcome in [FakeGitHubWebAuthenticationRunner.Outcome.cancelled, .failed, .callback] {
            let runner = FakeGitHubWebAuthenticationRunner(outcome: outcome)
            let store = InMemorySessionStore(session: try appBackendTestSession())
            let foreign = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
            let transport = AppBackendTransport([appAccountOK(), missingGitHubResponse(), authorizationResponse(), appBackendAuthResponse(userID: foreign)])
            let composition = try linkComposition(transport: transport, runner: runner, store: store)
            await composition.waitForRestoration()
            let original = try await store.load()
            do {
                let result = try await composition.linkAdapter.actions().connectGitHub()
                XCTAssertEqual(outcome, .cancelled)
                XCTAssertEqual(result, .notConnected)
                XCTAssertNil(composition.linkAdapter.connectionError)
            } catch {
                XCTAssertNotEqual(outcome, .cancelled)
                XCTAssertEqual(composition.linkAdapter.connection, .failed)
                XCTAssertEqual(error as? LinkActionError, .init(code: .unavailable, details: ["transport_failure"]))
            }
            XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
            let retained = try await store.load()
            XCTAssertEqual(retained?.userID, original?.userID)
            XCTAssertEqual(retained?.accessCredential, original?.accessCredential)
            let requests = await transport.recorded()
            XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "github-links" }.count, 1)
        }
    }

    func testSecondAttemptIsRefusedAndSignOutCancelsPendingBrowser() async throws {
        let runner = FakeGitHubWebAuthenticationRunner(outcome: .held)
        let store = InMemorySessionStore(session: try appBackendTestSession())
        let transport = AppBackendTransport([appAccountOK(), missingGitHubResponse(), authorizationResponse()])
        let composition = try linkComposition(transport: transport, runner: runner, store: store)
        await composition.waitForRestoration()
        let actions = composition.linkAdapter.actions()
        let first = Task { try await actions.connectGitHub() }
        try await appBackendEventually { runner.isHeld }
        do { _ = try await actions.connectGitHub(); XCTFail("Second attempt must fail") }
        catch { XCTAssertEqual(error as? LinkActionError, .init(code: .unavailable, details: ["pending"])) }
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        XCTAssertEqual(composition.linkAdapter.connection, .connecting)
        try await composition.account.signOut()
        do { _ = try await first.value; XCTFail("Signed-out attempt must fail") }
        catch { XCTAssertEqual(error as? LinkActionError, .init(code: .unavailable, details: ["not_authenticated"])) }
        XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertEqual(composition.linkAdapter.connection, .notConnected)
        let retained = try await store.load()
        XCTAssertNil(retained)
        let paths = await transport.recorded().map { $0.url?.lastPathComponent }
        XCTAssertEqual(paths, ["register_time_zone", "github-links", "authorize"])
        do { _ = try await actions.loadLinks(); XCTFail("Old actions must fail") }
        catch { XCTAssertEqual(error as? LinkActionError, .init(code: .unavailable, details: ["not_authenticated"])) }
    }

    func testSignOutDuringExchangeRefusesLateSameAccountResponse() async throws {
        let transport = ControlledAppBackendTransport(["register_time_zone": [.response(appAccountOK())],
            "github-links": [.response(missingGitHubResponse())],
            "authorize": [.response(authorizationResponse())], "token": [.held]])
        let composition = try linkComposition(transport: transport, runner: FakeGitHubWebAuthenticationRunner())
        await composition.waitForRestoration()
        let connecting = Task { try await composition.linkAdapter.actions().connectGitHub() }
        try await appBackendEventually { await transport.isHeld("token") }
        try await composition.account.signOut()
        await transport.release("token", with: appBackendAuthResponse())
        do { _ = try await connecting.value; XCTFail("Obsolete exchange must fail") }
        catch { XCTAssertEqual(error as? LinkActionError, .init(code: .unavailable, details: ["not_authenticated"])) }
        XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertEqual(composition.linkAdapter.connection, .notConnected)
    }

    func testLinkWritesRefreshEveryProfileConsumerAndDisconnectedLinks() async throws {
        let transport = AppBackendTransport([appAccountOK(), appOwnProfileResponse(), linkResponse([linkJSON()]),
            linkResponse(linkJSON()), appOwnProfileResponse(appLinkedPresentationProfile()),
            linkResponse(["deleted": true]), appOwnProfileResponse(), linkResponse([]),
            linkResponse(["link": linkJSON()]), appOwnProfileResponse(appLinkedPresentationProfile()),
            linkResponse(connectionJSON(connected: false)), linkResponse([]), linkResponse(connectionJSON(connected: false)),
            appOwnProfileResponse(), authUserResponse(), linkResponse([:], status: 204)])
        let composition = try linkComposition(transport: transport)
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        let onboarding = try XCTUnwrap(flow.onboarding)
        let settings = try XCTUnwrap(flow.settings)
        let actions = composition.linkAdapter.actions()
        let loaded = try await actions.loadLinks()
        let link = try XCTUnwrap(loaded.first)
        _ = try await actions.updateLink(link.id, LinkPreviewDraft(link: link), .private)
        XCTAssertEqual(composition.account.profile?.linkCount, 1)
        XCTAssertTrue(onboarding.profile.prerequisites.link)
        XCTAssertTrue(settings.profile.prerequisites.link)
        _ = try await actions.deleteLink(link.id)
        XCTAssertEqual(settings.profile.linkCount, 0)
        XCTAssertFalse(onboarding.profile.prerequisites.link)
        let fresh = try LinkAdapter.present(JSONDecoder().decode(RepositoryPreviewTransfer.self, from: linkResponse(previewJSON()).data))
        _ = try await actions.saveRepository(fresh, .private, false)
        XCTAssertEqual(settings.profile.linkCount, 1)
        try await composition.linkAdapter.disconnectGitHub()
        XCTAssertEqual(composition.linkAdapter.links, [])
        XCTAssertEqual(composition.linkAdapter.connection, .notConnected)
        XCTAssertEqual(settings.profile.linkCount, 0)
    }

    func testConfirmedSaveSurvivesRefreshFailureAndMarksProfileStale() async throws {
        let transport = AppBackendTransport([appAccountOK(), appOwnProfileResponse(), linkResponse([]),
            linkResponse(["link": linkJSON()])])
        let composition = try linkComposition(transport: transport)
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        let actions = composition.linkAdapter.actions()
        _ = try await actions.loadLinks()
        let draft = try LinkAdapter.present(JSONDecoder().decode(RepositoryPreviewTransfer.self, from: linkResponse(previewJSON()).data))
        _ = try await actions.saveRepository(draft, .private, false)
        XCTAssertTrue(composition.account.profileIsStale)
        XCTAssertEqual(composition.account.profile?.linkCount, 1)
        XCTAssertTrue(flow.settings?.profile.prerequisites.link == true)
        XCTAssertTrue(flow.savedWithStaleProfile)
    }

    func testLastLinkRefusalPreservesProfileAndOwnedLinks() async throws {
        var profile = appLinkedPresentationProfile(); profile.discoveryOn = true
        let refusal = linkResponse(["message": "prerequisite_missing", "details": "link"], status: 400)
        let transport = AppBackendTransport([appAccountOK(), appOwnProfileResponse(profile), linkResponse([linkJSON()]), refusal])
        let composition = try linkComposition(transport: transport)
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        let actions = composition.linkAdapter.actions()
        _ = try await actions.loadLinks()
        do { _ = try await actions.deleteLink(linkTestID); XCTFail("Last link must be refused") }
        catch { XCTAssertTrue((error as? LinkActionError)?.isLastLink == true) }
        XCTAssertEqual(composition.account.profile, profile)
        XCTAssertEqual(composition.linkAdapter.links?.count, 1)
    }

    func testLateDisconnectFailureCannotPublishAfterSignOut() async throws {
        let transport = ControlledAppBackendTransport(["register_time_zone": [.response(appAccountOK())], "disconnect_github": [.held]])
        let composition = try linkComposition(transport: transport)
        await composition.waitForRestoration()
        let disconnecting = Task { try await composition.linkAdapter.disconnectGitHub() }
        try await appBackendEventually { await transport.isHeld("disconnect_github") }
        try await composition.account.signOut()
        await transport.release("disconnect_github", with: linkResponse(["message": "prerequisite_missing", "details": "link"], status: 400))
        do { try await disconnecting.value; XCTFail("Obsolete disconnect must fail") } catch { }
        XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertEqual(composition.linkAdapter.connection, .notConnected)
        XCTAssertNil(composition.linkAdapter.disconnectError)
    }

    func testPendingSessionGuardsKeepCredentialsAndDoNotSendLinkRequests() async throws {
        let store = InMemorySessionStore(session: try appBackendTestSession())
        let transport = ControlledAppBackendTransport(["register_time_zone": [.held]])
        let composition = try linkComposition(transport: transport, store: store)
        try await appBackendEventually { await transport.isHeld("register_time_zone") }
        XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
        let actions = composition.linkAdapter.actions()
        do { _ = try await actions.loadLinks(); XCTFail("Pending actions must refuse locally") } catch { }
        do { _ = try await actions.connectGitHub(); XCTFail("Pending actions must refuse locally") } catch { }
        do { try await composition.linkAdapter.disconnectGitHub(); XCTFail() } catch { }
        let retained = try await store.load()
        XCTAssertEqual(retained, try appBackendTestSession())
        XCTAssertEqual(composition.account.state, .signedInPending(appBackendTestUser))
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 1)
        await transport.release("register_time_zone", with: appAccountOK())
        await composition.waitForRestoration()
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
    }

    func testExistingIdentityConnectSyncsWithoutBrowserAuthorization() async throws {
        let runner = FakeGitHubWebAuthenticationRunner()
        let transport = AppBackendTransport([appAccountOK(), linkResponse(connectionJSON()), linkResponse(connectionJSON())])
        let composition = try linkComposition(transport: transport, runner: runner)
        await composition.waitForRestoration()
        let result = try await composition.linkAdapter.actions().connectGitHub()
        XCTAssertEqual(result, .connected(handle: "owner"))
        XCTAssertNil(runner.address)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["register_time_zone", "github-links", "get_github_connection"])
    }

    func testFailedSyncAfterExchangeRetriesWithoutSecondAuthorization() async throws {
        let runner = FakeGitHubWebAuthenticationRunner()
        let transport = AppBackendTransport([appAccountOK(), missingGitHubResponse(), authorizationResponse(), appBackendAuthResponse(),
            linkResponse([:], status: 503), linkResponse(connectionJSON(connected: false)),
            linkResponse(connectionJSON()), linkResponse(connectionJSON())])
        let composition = try linkComposition(transport: transport, runner: runner)
        await composition.waitForRestoration()
        do { _ = try await composition.linkAdapter.actions().connectGitHub(); XCTFail() } catch { }
        XCTAssertTrue(composition.linkAdapter.needsGitHubSync)
        XCTAssertEqual(composition.linkAdapter.connection, .connected(handle: nil))
        XCTAssertNotNil(composition.linkAdapter.connectionError)
        _ = try await composition.linkAdapter.actions().loadConnection()
        XCTAssertEqual(composition.linkAdapter.connection, .connected(handle: nil))
        let result = try await composition.linkAdapter.actions().connectGitHub()
        XCTAssertEqual(result, .connected(handle: "owner"))
        XCTAssertFalse(composition.linkAdapter.needsGitHubSync)
        XCTAssertNil(composition.linkAdapter.connectionError)
        XCTAssertEqual(runner.authorizationCount, 1)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "authorize" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "token" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "github-links" }.count, 3)
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
    }

    func testDisconnectAttemptsBothReadsAndAuthEvenWhenOneReadFails() async throws {
        for failedRead in ["list_own_links", "get_github_connection"] {
            let transport = ControlledAppBackendTransport([
                "register_time_zone": [.response(appAccountOK())],
                "disconnect_github": [.response(linkResponse(connectionJSON(connected: false)))],
                "list_own_links": [failedRead == "list_own_links" ? .failure : .response(linkResponse([]))],
                "get_github_connection": [failedRead == "get_github_connection" ? .failure : .response(linkResponse(connectionJSON(connected: false)))],
                "get_own_profile": [.failure], "user": [.response(authUserResponse())],
                authGitHubIdentity: [.response(linkResponse([:], status: 204))]
            ])
            let composition = try linkComposition(transport: transport)
            await composition.waitForRestoration()
            do { try await composition.linkAdapter.disconnectGitHub(); XCTFail("Read failure remains visible") } catch { }
            let requests = await transport.recorded()
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["register_time_zone", "disconnect_github", "list_own_links",
                "get_github_connection", "get_own_profile", "user", authGitHubIdentity])
            XCTAssertEqual(requests.last?.httpMethod, "DELETE")
            XCTAssertNotNil(composition.linkAdapter.disconnectError)
            XCTAssertNil(composition.linkAdapter.connectionError)
            XCTAssertEqual(composition.linkAdapter.connection, .notConnected)
            XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
        }
    }

    func testDisconnectLastAuthIdentityRefusalIsScreenSuccessAndKeepsConnectErrorSeparate() async throws {
        let transport = AppBackendTransport([appAccountOK(), linkResponse([:], status: 503),
            linkResponse(connectionJSON(connected: false)), linkResponse([]), linkResponse(connectionJSON(connected: false)),
            appOwnProfileResponse(), authUserResponse(),
            linkResponse(["code": "single_identity_not_deletable"], status: 422)])
        let composition = try linkComposition(transport: transport)
        await composition.waitForRestoration()
        do { _ = try await composition.linkAdapter.actions().connectGitHub(); XCTFail() } catch { }
        let connectError = composition.linkAdapter.connectionError
        XCTAssertNotNil(connectError)
        try await composition.linkAdapter.disconnectGitHub()
        XCTAssertNil(composition.linkAdapter.disconnectError)
        XCTAssertEqual(composition.linkAdapter.connectionError, connectError)
        XCTAssertEqual(composition.account.state, .signedIn(appBackendTestUser))
    }

    func testOnboardingGoesThroughBasicsSelectionsFirstLinkAndPermissions() async throws {
        let transport = AppBackendTransport([appAccountOK(), appOwnProfileResponse(.init()),
            appAccountOK(), appOwnProfileResponse(appPresentationProfile()),
            linkResponse([]), linkResponse(["link": linkJSON()]), appOwnProfileResponse(appLinkedPresentationProfile())])
        let composition = try linkComposition(transport: transport)
        let flow = AccountFlowModel(composition: composition)
        await flow.start()
        let model = try XCTUnwrap(flow.onboarding)
        XCTAssertEqual(model.step, .basics)
        model.displayName = "名前"; model.introduction = "紹介"
        await model.saveBasics()
        XCTAssertEqual(model.step, .interests)
        // Supply the confirmed catalogue without introducing another networking action into the order test.
        let ordered = OnboardingModel(profile: model.profile, interests: [.init(id: "a", labelJapanese: "技術", labelEnglish: "Technology")],
            bluetooth: .available, actions: composition.account.profileActions { .available }, onExit: {}, onFinish: { _ in },
            onBluetoothRecovery: {}, linkActions: composition.linkAdapter.actions())
        ordered.edit(.interest)
        await ordered.saveSelections()
        XCTAssertEqual(ordered.step, .firstLink)
        let links = try XCTUnwrap(ordered.linkModel)
        await links.loadLinks()
        XCTAssertFalse(ordered.canContinueFirstLink)
        let draft = try LinkAdapter.present(JSONDecoder().decode(RepositoryPreviewTransfer.self, from: linkResponse(previewJSON()).data))
        links.draft = draft; links.draft?.visibility = .private
        let saved = await links.save()
        XCTAssertTrue(saved)
        XCTAssertTrue(ordered.canContinueFirstLink)
        ordered.continueFirstLink()
        XCTAssertEqual(ordered.step, .permissions)
        XCTAssertTrue(ordered.canEnableDiscovery)
        ordered.back()
        XCTAssertEqual(ordered.step, .firstLink)
    }
}

func appLinkedPresentationProfile() -> OwnProfileState {
    var profile = appPresentationProfile()
    profile.linkCount = 1; profile.prerequisites.link = true
    return profile
}

private let linkTestID = "00000000-0000-0000-0000-000000000333"
private func linkJSON() -> [String: Any] {
    ["link_id": linkTestID, "source": "github", "source_item_id": "42", "url": "https://github.com/owner/repo",
     "title": "Repo", "description": "Description", "main_language": "Swift", "tags": ["ios"],
     "opening_text": "Opening", "visibility": "private", "verification_state": "verified", "display_order": 0]
}
private func repositoryJSON() -> [String: Any] {
    ["repository_id": "42", "repository_name": "repo", "title": "Repo", "description": "Description",
     "main_language": "Swift", "tags": ["ios"], "url": "https://github.com/owner/repo"]
}
private func previewJSON() -> [String: Any] {
    var value = repositoryJSON(); value["opening_text"] = "Opening"; value["verification_state"] = "verified"
    return value
}
private func connectionJSON(connected: Bool = true) -> [String: Any] {
    ["connected": connected, "handle": connected ? "owner" as Any : NSNull()]
}
private func linkResponse(_ value: Any, status: Int = 200) -> HTTPResponse {
    HTTPResponse(data: try! JSONSerialization.data(withJSONObject: value), statusCode: status)
}
private func authorizationResponse() -> HTTPResponse {
    linkResponse(["url": "https://github.com/login/oauth/authorize?state=fixture-state"])
}

@MainActor
private func linkComposition(transport: any HTTPTransport, runner: (any GitHubWebAuthenticationRunning)? = nil,
                             store: (any SessionStore)? = nil) throws -> AppComposition {
    AppComposition(configuration: appBackendTestConfiguration(), defaults: appBackendDefaults(), transport: transport,
        keychain: AppMemoryKeychain(), sessionStore: try store ?? InMemorySessionStore(session: appBackendTestSession()),
        serverTokenStore: InMemoryTokenBatchStore(), signedOutTokenStore: InMemoryTokenBatchStore(),
        queueOpener: { InMemoryReceiptQueue() }, now: { appBackendTestNow }, webAuthenticationRunner: runner,
        timeZone: { "Asia/Tokyo" })
}

@MainActor
private final class FakeGitHubWebAuthenticationRunner: GitHubWebAuthenticationRunning {
    enum Outcome: Equatable { case callback, cancelled, failed, held }
    private let outcome: Outcome
    private(set) var authorizationCount = 0
    private(set) var address: URL?
    private(set) var scheme: String?
    private var waiting: CheckedContinuation<URL, any Error>?
    var isHeld: Bool { waiting != nil }
    init(outcome: Outcome = .callback) { self.outcome = outcome }
    func authenticate(at address: URL, callbackScheme: String) async throws -> URL {
        authorizationCount += 1
        self.address = address; scheme = callbackScheme
        switch outcome {
        case .callback: return URL(string: "engineer-encounters://auth/github?code=fixture-code&state=fixture-state")!
        case .cancelled: throw CancellationError()
        case .failed: throw GitHubWebAuthenticationError.failed
        case .held: return try await withCheckedThrowingContinuation { waiting = $0 }
        }
    }
    func cancel() { waiting?.resume(throwing: CancellationError()); waiting = nil }
}

/// Exercise both public error envelopes and their single unauthorized retry.
private actor LinkFailureTransport: HTTPTransport {
    let rpc: HTTPResponse
    let edge: HTTPResponse
    init(rpc: HTTPResponse, edge: HTTPResponse) { self.rpc = rpc; self.edge = edge }
    func sendWithoutRedirects(_ request: URLRequest) async throws -> HTTPResponse { try await send(request) }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        switch request.url?.lastPathComponent {
        case "register_time_zone": return appAccountOK()
        case "token": return appBackendAuthResponse()
        case "github-links": return edge
        default: return rpc
        }
    }
}

private let authGitHubIdentity = "00000000-0000-0000-0000-000000000444"
private func authUserResponse() -> HTTPResponse {
    linkResponse(["id": appBackendTestUser.uuidString, "identities": [
        ["provider": "github", "identity_id": authGitHubIdentity],
        ["provider": "apple", "identity_id": "00000000-0000-0000-0000-000000000445"]]])
}
private func missingGitHubResponse() -> HTTPResponse {
    linkResponse(["error": ["code": "prerequisite_missing", "details": ["github"]]], status: 400)
}
