import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport
import EncounterStorage
import EncounterUI
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class SettingsSafetyAdapterTests: XCTestCase {
    func testReportSettingsPreservePreferencesAndUseExactParameters() async throws {
        let transport = productTransport([
            "get_report_settings": [.response(settingsReport())],
            "set_report_time": [.response(settingsReport(hour: 8, minute: 45))],
            "set_notifications_enabled": [.response(settingsReport(enabled: false))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let actions = composition.settingsSafetyAdapter.reportSettingsActions()
        let loaded = try await actions.load()
        XCTAssertEqual(loaded, .init(time: .init(hour: 21, minute: 0), timeZone: "Asia/Tokyo", notificationsEnabled: true))
        let time = try await actions.saveTime(.init(hour: 8, minute: 45))
        XCTAssertEqual(time.time, .init(hour: 8, minute: 45))
        let disabled = try await actions.setNotifications(false)
        XCTAssertFalse(disabled.notificationsEnabled)
        let permission = try await actions.requestPermission()
        XCTAssertEqual(permission, .unavailable)
        let requests = await transport.recorded()
        XCTAssertEqual(try settingsBody(requests[2]), ["hour": 8, "minute": 45] as NSDictionary)
        XCTAssertEqual(try settingsBody(requests[3]), ["enabled": false] as NSDictionary)
    }

    func testOwnCardUsesOwnProfileVisibilityAndOwnLinks() async throws {
        var profile = appLinkedPresentationProfile()
        profile.fieldVisibility[.displayName] = .everyoneEligible
        profile.fieldVisibility[.introduction] = .compatibleOnly
        profile.fieldVisibility[.contactDetail] = .private
        let transport = productTransport(["get_own_profile": [.response(appOwnProfileResponse(profile))],
            "list_own_links": [.response(productResponse([settingsOwnLink()]))],
            "list_interests": [.response(productResponse([["interest_id": "swift", "label_ja": "Swift", "label_en": "Swift", "display_order": 0]]))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let data = try await composition.settingsSafetyAdapter.myCardActions(openOriginal: { _ in }).load()
        let everyone = MyCardPreview(data: data, audience: .everyoneEligible)
        let compatible = MyCardPreview(data: data, audience: .compatibleOnly)
        XCTAssertEqual(everyone.displayName, profile.displayName); XCTAssertNil(everyone.introduction)
        XCTAssertNil(everyone.contactDetail); XCTAssertTrue(everyone.links.isEmpty)
        XCTAssertEqual(compatible.introduction, profile.introduction); XCTAssertEqual(compatible.links.count, 1)
        XCTAssertNil(compatible.contactDetail)
        let paths = await transport.recorded().compactMap { $0.url?.lastPathComponent }
        XCTAssertEqual(paths, ["register_time_zone", "get_own_profile", "list_own_links", "list_interests"])
    }

    func testBlockListUnblockReportAndBlockMapOpaqueReferencesAndReason() async throws {
        let transport = productTransport([
            "list_blocks": [.response(productResponse(["blocks": [["block_id": settingsBlockID, "placed_day": "2026-10-13"]], "truncated": true]))],
            "unblock": [.response(productResponse(["unblocked": true]))],
            "report_encounter_person": [.response(productResponse(["report_id": settingsBlockID, "status": "open"])),
                .response(productResponse(["report_id": settingsBlockID, "status": "open"]))],
            "block_encounter_person": [.response(productResponse(["block_id": settingsBlockID, "placed_day": "2026-10-13"]))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let blocked = composition.settingsSafetyAdapter.blockedActions()
        let list = try await blocked.load()
        XCTAssertTrue(list.truncated)
        XCTAssertEqual(list.blocks, [.init(id: settingsBlockID, placedDay: .init(year: 2026, month: 10, day: 13))])
        try await blocked.unblock(settingsBlockID.uppercased())
        let report = composition.settingsSafetyAdapter.reportActions(encounterID: productEncounterID)
        try await report.report(XCTUnwrap(SafetyReportRequest(encounterID: productEncounterID, reason: .spam, link: nil)))
        try await report.report(XCTUnwrap(SafetyReportRequest(encounterID: productEncounterID, reason: .impersonation,
                                                             link: .init(id: productLinkID))))
        try await report.block(productEncounterID)
        let requests = await transport.recorded()
        XCTAssertEqual(try settingsBody(requests[2]), ["block_id": settingsBlockID] as NSDictionary)
        XCTAssertEqual(try settingsBody(requests[3]), ["encounter_id": productEncounterID, "reason": "spam", "link_id": NSNull()] as NSDictionary)
        XCTAssertEqual(try settingsBody(requests[4]), ["encounter_id": productEncounterID, "reason": "impersonation", "link_id": productLinkID] as NSDictionary)
        XCTAssertEqual(try settingsBody(requests[5]), ["encounter_id": productEncounterID] as NSDictionary)
    }

    func testEveryNewServiceActionMapsErrorsAndOnlyAuthenticationSignsOut() async throws {
        let operations: [(String, @MainActor (AppComposition) async throws -> Void)] = [
            ("get_report_settings", { _ = try await $0.settingsSafetyAdapter.reportSettingsActions().load() }),
            ("set_report_time", { _ = try await $0.settingsSafetyAdapter.reportSettingsActions().saveTime(.init()) }),
            ("set_notifications_enabled", { _ = try await $0.settingsSafetyAdapter.reportSettingsActions().setNotifications(false) }),
            ("list_blocks", { _ = try await $0.settingsSafetyAdapter.blockedActions().load() }),
            ("unblock", { try await $0.settingsSafetyAdapter.blockedActions().unblock(settingsBlockID) }),
            ("report_encounter_person", { try await $0.settingsSafetyAdapter.reportActions(encounterID: productEncounterID).report(
                XCTUnwrap(SafetyReportRequest(encounterID: productEncounterID, reason: .other, link: nil))) }),
            ("block_encounter_person", { try await $0.settingsSafetyAdapter.reportActions(encounterID: productEncounterID).block(productEncounterID) }),
            ("delete_encounter", { try await XCTUnwrap($0.discoverAdapter.actions().deleteEncounter)(productEncounterID) }),
            ("disconnect_github", { _ = try await $0.settingsSafetyAdapter.accountActions().disconnectGitHub() }),
            ("delete_own_account", { _ = try await $0.settingsSafetyAdapter.accountActions().deleteAccount() })]
        let failures: [(String, String, ProfileActionError)] = [
            ("prerequisite_missing", "deletion_safety_key", .init(code: .prerequisiteMissing, fields: ["deletion_safety_key"])),
            ("invalid_input", "link_id", .init(code: .invalidInput, fields: ["link_id"])),
            ("account_not_ready", "", .init(code: .accountNotReady)),
            ("declaration_required", "", .init(code: .declarationRequired)),
            ("rate_limited", "", .init(code: .rateLimited)), ("not_found", "", .init(code: .notFound)),
            ("not_authenticated", "", .init(code: .notAuthenticated))]
        for (path, operation) in operations {
            for (code, details, expected) in failures {
                let reply = ControlledAppBackendTransport.Reply.response(productError(code, details: details))
                let transport = productTransport([path: code == "not_authenticated" ? [reply, reply] : [reply],
                                                  "token": [.response(appBackendAuthResponse())]])
                let composition = try productComposition(transport)
                await composition.waitForRestoration(); productAuthorize(composition)
                let alreadyDeleted = ["delete_encounter", "report_encounter_person", "block_encounter_person"].contains(path) && code == "not_found"
                do { try await operation(composition); if !alreadyDeleted { XCTFail("Expected failure: \(path)") } }
                catch {
                    XCTAssertFalse(alreadyDeleted)
                    XCTAssertEqual(error as? ProfileActionError, expected, path)
                }
                XCTAssertEqual(composition.account.state == .signedOut, code == "not_authenticated", path)
            }
            let composition = try productComposition(productTransport([path: [.failure]]))
            await composition.waitForRestoration(); productAuthorize(composition)
            do { try await operation(composition); XCTFail("Expected transport failure") }
            catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .unavailable), path) }
            XCTAssertTrue(composition.account.state.isSignedIn)
        }
    }

    func testAccountLoadDisconnectRefreshAndLastLinkRefusal() async throws {
        var profile = appLinkedPresentationProfile(); profile.discoveryOn = false
        let disconnected = productResponse(["connected": false, "handle": NSNull()])
        let transport = productTransport([
            "get_own_profile": [.response(appOwnProfileResponse(profile)), .response(appOwnProfileResponse(profile)),
                .response(appOwnProfileResponse(profile))],
            "get_github_connection": [.response(productResponse(["connected": true, "handle": "owner"])),
                .response(disconnected), .response(disconnected)],
            "list_own_links": [.response(productResponse([settingsOwnLink()])), .response(productResponse([])),
                .response(productResponse([]))], "disconnect_github": [.response(disconnected)],
            "user": [.response(productResponse(["id": appBackendTestUser.uuidString.lowercased(), "identities": [
                ["identity_id": settingsBlockID, "provider": "github"]]]))],
            settingsBlockID: [.response(productResponse(["error_code": "single_identity_not_deletable"], status: 422))],
            "get_encounter_feed": [.response(productFeed()), .response(productResponse(["cards": [], "truncated": false]))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let discover = try XCTUnwrap(composition.discoverAdapter.model)
        await discover.loadFeed()
        let actions = composition.settingsSafetyAdapter.accountActions()
        let initial = try await actions.load()
        XCTAssertTrue(initial.githubConnected); XCTAssertEqual(initial.githubHandle, "owner")
        XCTAssertEqual(initial.githubRepositoryCount, 1); XCTAssertEqual(initial.linkCount, 1)
        let fresh = try await actions.disconnectGitHub()
        XCTAssertFalse(fresh.githubConnected); XCTAssertEqual(fresh.linkCount, 0)
        XCTAssertTrue(composition.account.state.isSignedIn)
        let requests = await transport.recorded()
        let disconnect = try XCTUnwrap(requests.first { $0.url?.lastPathComponent == "disconnect_github" })
        XCTAssertEqual(try settingsBody(disconnect), [:] as NSDictionary)
        let unlink = try XCTUnwrap(requests.first { $0.url?.lastPathComponent == settingsBlockID })
        XCTAssertEqual(unlink.httpMethod, "DELETE")
        let refusal = AccountSettingsModel(data: .init(githubConnected: true, discoveryOn: true, linkCount: 1,
            githubRepositoryCount: 1), actions: actions, navigation: .init(back: {}, signedOut: {}, discovery: {}))
        await refusal.disconnect()
        XCTAssertTrue(refusal.lastLinkRefused)
        let calls = await transport.count("disconnect_github"); XCTAssertEqual(calls, 1)
    }

    func testOldSettingsActionsAreFencedAfterSignOutAndAccountReplacement() async throws {
        let transport = productTransport([:])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let report = composition.settingsSafetyAdapter.reportSettingsActions()
        let blocks = composition.settingsSafetyAdapter.blockedActions()
        let safety = composition.settingsSafetyAdapter.reportActions(encounterID: productEncounterID)
        let account = composition.settingsSafetyAdapter.accountActions()
        try await composition.account.signOut()
        let count = await transport.recorded().count
        let operations: [@MainActor () async throws -> Void] = [
            { _ = try await report.load() }, { _ = try await blocks.load() },
            { try await safety.block(productEncounterID) }, { _ = try await account.deleteAccount() }]
        for operation in operations {
            do { try await operation(); XCTFail("Obsolete action must not run") }
            catch { XCTAssertEqual(error as? ProfileActionError, .init(code: .notAuthenticated)) }
        }
        let after = await transport.recorded().count; XCTAssertEqual(after, count)
    }

    func testFailedReportConcealsAllCachedCopiesRetainsReasonAndCanRetry() async throws {
        let transport = productTransport(["get_encounter_feed": [.response(productFeed()), .response(productFeed()), .response(productFeed())],
            "get_encounter_card": [.response(productResponse(productCard(detail: true)))],
            "list_encounter_favorites": [.response(productFeed()), .response(productFeed()), .response(productFeed())],
            "report_encounter_person": [.failure, .response(productResponse(["report_id": settingsBlockID, "status": "open"]))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let discover = try XCTUnwrap(composition.discoverAdapter.model)
        await discover.loadFeed(); await discover.loadFavorites(); await discover.loadCard(productEncounterID)
        composition.settingsSafetyAdapter.presentReport(productEncounterID, linkID: productLinkID, completed: {})
        let model = try XCTUnwrap(composition.settingsSafetyAdapter.sheet?.model)
        await model.submit()
        XCTAssertEqual(model.error?.code, .unavailable)
        XCTAssertEqual(model.state.retry, .report(try XCTUnwrap(SafetyReportRequest(encounterID: productEncounterID,
            reason: .impersonation, link: .init(id: productLinkID)))))
        XCTAssertNil(discover.card); XCTAssertTrue(discover.feed.isEmpty); XCTAssertTrue(discover.favorites.isEmpty)
        await discover.loadFeed(); await discover.loadCard(productEncounterID)
        XCTAssertTrue(discover.feed.isEmpty); XCTAssertNil(discover.card)
        await model.retry()
        XCTAssertNil(composition.settingsSafetyAdapter.sheet)
        let reports = await transport.count("report_encounter_person")
        XCTAssertEqual(reports, 2)
    }

    func testReportBlockAndUnblockRefreshRequestedCards() async throws {
        for action in ["report", "block", "unblock"] {
            let transport = productTransport(["get_encounter_feed": [.response(productFeed()), .response(productResponse(["cards": [], "truncated": false]))],
                "get_encounter_card": [.response(productResponse(productCard(detail: true))), .response(productError("not_found"))],
                "report_encounter_person": [.response(productResponse(["report_id": settingsBlockID, "status": "open"]))],
                "block_encounter_person": [.response(productResponse(["block_id": settingsBlockID, "placed_day": "2026-10-13"]))],
                "unblock": [.response(productResponse(["unblocked": true]))]])
            let composition = try productComposition(transport)
            await composition.waitForRestoration(); productAuthorize(composition)
            let discover = try XCTUnwrap(composition.discoverAdapter.model)
            await discover.loadFeed(); await discover.loadCard(productEncounterID)
            let actions = composition.settingsSafetyAdapter.reportActions(encounterID: productEncounterID)
            if action == "report" {
                try await actions.report(XCTUnwrap(SafetyReportRequest(encounterID: productEncounterID, reason: .spam, link: nil)))
            } else if action == "block" { try await actions.block(productEncounterID) }
            else { try await composition.settingsSafetyAdapter.blockedActions().unblock(settingsBlockID) }
            XCTAssertTrue(discover.feed.isEmpty); XCTAssertNil(discover.card)
            try await appBackendEventually { await transport.count("get_encounter_feed") == 2 }
        }
    }

    func testCancellingFailedReportReloadsAuthorizedCardAndRequestedLists() async throws {
        let saved = productResponse(["links": [["encounter_id": productEncounterID,
            "day": "2026-10-13", "kind": "session", "link": productLink()]], "truncated": false])
        let transport = productTransport(["get_encounter_feed": [.response(productFeed()), .response(productFeed()), .response(productFeed())],
            "list_encounter_favorites": [.response(productFeed()), .response(productFeed()), .response(productFeed())],
            "list_saved_links": [.response(saved), .response(saved), .response(saved)],
            "get_encounter_card": [.response(productResponse(productCard(detail: true))), .response(productResponse(productCard(detail: true)))],
            "report_encounter_person": [.failure]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let discover = try XCTUnwrap(composition.discoverAdapter.model)
        await discover.loadFeed(); await discover.loadFavorites(); await discover.loadSavedLinks()
        await discover.loadCard(productEncounterID)
        composition.settingsSafetyAdapter.presentReport(productEncounterID, linkID: nil, completed: {})
        let model = try XCTUnwrap(composition.settingsSafetyAdapter.sheet?.model)
        model.reason = .spam; await model.submit()
        XCTAssertNil(discover.card)
        await model.cancel()
        XCTAssertNil(composition.settingsSafetyAdapter.sheet)
        XCTAssertEqual(discover.card?.card.id, productEncounterID)
        XCTAssertEqual(discover.feed.first?.id, productEncounterID)
        XCTAssertEqual(discover.favorites.first?.id, productEncounterID)
        XCTAssertEqual(discover.savedLinks.first?.encounterID, productEncounterID)
    }

    func testVisibilityWriteDropsCardsBeforeItsFollowUpProfileReadCompletes() async throws {
        var fresh = appLinkedPresentationProfile(); fresh.discoveryOn = true
        fresh.fieldVisibility[.displayName] = .private
        let transport = productTransport(["get_encounter_feed": [.response(productFeed()), .held,
            .response(productResponse(["cards": [], "truncated": false]))],
            "set_field_visibility": [.response(appAccountOK())], "get_own_profile": [.held]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let discover = try XCTUnwrap(composition.discoverAdapter.model)
        await discover.loadFeed()
        let actions = composition.account.profileActions(requestBluetooth: { .notRequested })
        let write = Task { try await actions.setFieldVisibility(.displayName, .private) }
        try await appBackendEventually { await transport.isHeld("get_own_profile") }
        XCTAssertTrue(discover.feed.isEmpty)
        try await appBackendEventually { await transport.isHeld("get_encounter_feed") }
        await transport.release("get_own_profile", with: appOwnProfileResponse(fresh))
        _ = try await write.value
        await transport.release("get_encounter_feed", with: productFeed())
        XCTAssertTrue(discover.feed.isEmpty)
    }

    func testEncounterDeletionHasConfirmationAndRefreshesCards() async throws {
        let transport = productTransport(["get_encounter_feed": [.response(productFeed()), .response(productResponse(["cards": [], "truncated": false]))],
            "get_encounter_card": [.response(productResponse(productCard(detail: true))), .response(productError("not_found"))],
            "delete_encounter": [.response(productResponse(["deleted": true]))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let model = try XCTUnwrap(composition.discoverAdapter.model)
        await model.loadFeed(); await model.loadCard(productEncounterID)
        composition.productNavigation.push(.favorites, in: .discover)
        composition.productNavigation.push(.encounter(productEncounterID), in: .discover)
        model.requestDeletion(productEncounterID)
        XCTAssertEqual(model.deletion, .confirming(productEncounterID))
        let before = await transport.count("delete_encounter"); XCTAssertEqual(before, 0)
        _ = await model.confirmDeletion()
        try await appBackendEventually { await transport.count("get_encounter_feed") == 2 }
        XCTAssertTrue(model.feed.isEmpty); XCTAssertNil(model.card)
        XCTAssertEqual(composition.productNavigation.discover, [.favorites])
    }

    func testDeletionPendingFencesProtectedReadsAndFailureNamesMissingKey() async throws {
        let transport = productTransport(["delete_own_account": [.held], "get_encounter_feed": [.held],
            "get_own_profile": [.response(appOwnProfileResponse(appLinkedPresentationProfile()))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        let discover = try XCTUnwrap(composition.discoverAdapter.model)
        let read = Task { await discover.loadFeed() }
        try await appBackendEventually { await transport.isHeld("get_encounter_feed") }
        let model = settingsAccountModel(composition)
        let deletion = Task { await model.deleteAccount() }
        try await appBackendEventually { await transport.isHeld("delete_own_account") }
        XCTAssertEqual(model.deletion, .pending); XCTAssertTrue(composition.account.deletionSuspended)
        do { _ = try await composition.sessionAdapter.actions().startSession(); XCTFail("Session must be suspended") }
        catch { }
        do { _ = try await composition.qrAdapter.actions().issueCode(); XCTFail("QR must be suspended") }
        catch { }
        do { _ = try await composition.settingsSafetyAdapter.reportSettingsActions().load(); XCTFail("Settings must be suspended") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(composition.account.state.isSignedIn)
        let starts = await transport.count("start_session"); XCTAssertEqual(starts, 0)
        let codes = await transport.count("issue_qr_code"); XCTAssertEqual(codes, 0)
        let readsBefore = await transport.count("get_encounter_feed")
        await discover.loadFeed(); await composition.refresh()
        let readsAfter = await transport.count("get_encounter_feed"); XCTAssertEqual(readsBefore, readsAfter)
        await transport.release("get_encounter_feed", with: productFeed()); await read.value
        XCTAssertTrue(discover.feed.isEmpty)
        await transport.release("delete_own_account", with: productError("prerequisite_missing", details: "deletion_safety_key"))
        await deletion.value
        XCTAssertEqual(model.deletion, .configurationRequired)
        XCTAssertEqual(model.error, .init(code: .prerequisiteMissing, fields: ["deletion_safety_key"]))
        XCTAssertTrue(composition.account.state.isSignedIn); XCTAssertTrue(composition.account.deletionSuspended)
        await model.cancelDeletion()
        XCTAssertEqual(model.deletion, .idle); XCTAssertFalse(composition.account.deletionSuspended)
    }

    func testSignOutAndDeletionClearAccountLocalStateKeepSampleAndSalt() async throws {
        for deleted in [false, true] {
            let defaults = appBackendDefaults()
            let salt = defaults.data(forKey: InstallationStorageSalt.key)
            let transport = productTransport(["get_encounter_feed": [.response(productFeed())],
                "get_encounter_card": [.response(productResponse(productCard(detail: true)))],
                "delete_own_account": [.response(productResponse(["deleted": true]))]])
            let queue = InMemoryReceiptQueue()
            let tokens = InMemoryTokenBatchStore()
            let store = InMemorySessionStore(session: try appBackendTestSession())
            let composition = settingsComposition(transport, defaults: defaults, queue: queue, tokens: tokens, store: store)
            await composition.waitForRestoration(); productAuthorize(composition)
            try await queue.enqueue(appBackendFinalReceipt())
            try await tokens.save(EncounterSamples.batch())
            let discover = try XCTUnwrap(composition.discoverAdapter.model)
            await discover.loadFeed(); await discover.loadCard(productEncounterID)
            composition.sampleEncounter.dismiss()
            composition.settingsSafetyAdapter.presentReport(productEncounterID, linkID: nil, completed: {})
            let owner = try XCTUnwrap(composition.sessionServices?.owner)
            try PendingSessionStopStore(defaults: defaults).save(.init(sessionID: UUID(), expiresAt: appBackendTestNow), owner: owner)
            #if DEVELOPMENT_BUILD || INTERNAL_BUILD
            composition.demoSwitch.isEnabled = true
            composition.trialRecorder.beginIfNeeded(metadata: composition.trialMetadata)
            XCTAssertFalse(composition.trialLog.records.isEmpty)
            #endif
            await composition.setParticipation(true)
            XCTAssertTrue(composition.isParticipating)
            if deleted { _ = try await composition.settingsSafetyAdapter.accountActions().deleteAccount() }
            else { try await composition.account.signOut() }
            XCTAssertEqual(composition.account.state, .signedOut); XCTAssertNil(composition.account.profile)
            XCTAssertNil(composition.discoverAdapter.model); XCTAssertTrue(discover.feed.isEmpty); XCTAssertNil(discover.card)
            XCTAssertNil(composition.settingsSafetyAdapter.sheet); XCTAssertFalse(composition.isParticipating)
            XCTAssertFalse(composition.deletionSuspended)
            let session = try await store.load(); XCTAssertNil(session)
            let savedTokens = try await tokens.load(); XCTAssertNil(savedTokens)
            let pendingReceipts = try await queue.pending(); XCTAssertTrue(pendingReceipts.isEmpty)
            XCTAssertNil(try PendingSessionStopStore(defaults: defaults).load(owner: owner))
            XCTAssertTrue(defaults.bool(forKey: InstallationSampleDismissalStore.key))
            XCTAssertEqual(defaults.data(forKey: InstallationStorageSalt.key), salt)
            #if DEVELOPMENT_BUILD || INTERNAL_BUILD
            XCTAssertFalse(composition.demoSwitch.isEnabled); XCTAssertTrue(composition.trialLog.records.isEmpty)
            XCTAssertFalse(DemoSwitchSetting(defaults: defaults).isEnabled)
            #endif
            if deleted {
                let before = await transport.recorded().count
                await composition.refresh(); await composition.account.restore()
                let after = await transport.recorded().count; XCTAssertEqual(before, after)
                XCTAssertTrue(composition.account.accountWasDeleted)
            }
        }
    }

    func testDeletedAccountNeverRestoresWhenCredentialDeletionFails() async throws {
        let defaults = appBackendDefaults()
        let keychain = AppMemoryKeychain()
        let configuration = appBackendTestConfiguration()
        let store = KeychainSessionStore(backendIdentity: BackendStorageBinding.identity(configuration), client: keychain)
        try await store.save(appBackendTestSession())
        await keychain.setSessionDeletionFailure(true)
        let transport = productTransport(["delete_own_account": [.response(productResponse(["deleted": true]))]])
        let composition = settingsComposition(transport, defaults: defaults, keychain: keychain, store: store)
        await composition.waitForRestoration(); productAuthorize(composition)
        let deleted = try await composition.settingsSafetyAdapter.accountActions().deleteAccount()
        XCTAssertTrue(deleted); XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertTrue(defaults.bool(forKey: SessionCleanupMarker.key))
        let replacement = settingsComposition(productTransport([:]), defaults: defaults, keychain: keychain, store: store)
        await replacement.waitForRestoration()
        XCTAssertEqual(replacement.account.state, .signedOut)
        XCTAssertTrue(defaults.bool(forKey: SessionCleanupMarker.key))
        XCTAssertNotNil(defaults.data(forKey: InstallationStorageSalt.key))
    }

    func testDeletedAccountCredentialCleanupCanRetryThroughFlowWithoutRelaunch() async throws {
        let defaults = appBackendDefaults()
        let store = FailingAppSessionStore(session: try appBackendTestSession(), failClear: true)
        let transport = productTransport(["delete_own_account": [.response(productResponse(["deleted": true]))],
            "get_own_profile": [.response(appOwnProfileResponse(appLinkedPresentationProfile()))],
            "signup": [.response(appBackendAuthResponse())], "accept_declarations": [.response(appAccountOK())]])
        let composition = settingsComposition(transport, defaults: defaults, store: store)
        let flow = AccountFlowModel(composition: composition)
        await flow.start(); productAuthorize(composition)
        let deleted = try await composition.settingsSafetyAdapter.accountActions().deleteAccount()
        XCTAssertTrue(deleted)
        XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertFalse(composition.deletionSuspended)
        XCTAssertTrue(composition.account.sessionCleanupFailed)
        await store.recover()
        await flow.refresh()
        XCTAssertFalse(composition.account.sessionCleanupFailed)
        XCTAssertFalse(defaults.bool(forKey: SessionCleanupMarker.key))
        #if DEVELOPMENT_BUILD
        try await composition.account.signInTemporaryAccount(isAdult: true, acceptsTermsAndPrivacy: true)
        XCTAssertTrue(composition.account.state.isSignedIn)
        XCTAssertFalse(composition.deletionSuspended)
        #endif
    }

    func testSuccessfulDeletionKeepsQuarantineUntilFailedLocalPurgeCanBeRetried() async throws {
        let defaults = appBackendDefaults()
        let tokens = SettingsPurgeTokenStore()
        let transport = productTransport(["delete_own_account": [.response(productResponse(["deleted": true]))],
            "get_own_profile": [.response(appOwnProfileResponse(appLinkedPresentationProfile()))]])
        let composition = settingsComposition(transport, defaults: defaults, tokens: tokens,
            store: InMemorySessionStore(session: try appBackendTestSession()))
        let flow = AccountFlowModel(composition: composition)
        await flow.start(); productAuthorize(composition)
        try await tokens.save(EncounterSamples.batch())
        await tokens.setFailClearing(true)
        let deleted = try await composition.settingsSafetyAdapter.accountActions().deleteAccount()
        XCTAssertTrue(deleted); XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertTrue(defaults.bool(forKey: SessionCleanupMarker.key))
        XCTAssertTrue(composition.account.accountWasDeleted)
        XCTAssertFalse(composition.deletionSuspended)
        await tokens.setFailClearing(false)
        await flow.refresh()
        XCTAssertFalse(defaults.bool(forKey: SessionCleanupMarker.key))
        let remaining = try await tokens.load(); XCTAssertNil(remaining)
        XCTAssertEqual(composition.account.state, .signedOut)
        let calls = await transport.count("delete_own_account"); XCTAssertEqual(calls, 1)
    }

    func testDestroyedAccountScreenKeepsFailedDeletionBlockedUntilVerifiedResumeAndRestartsRadio() async throws {
        let transport = productTransport(["delete_own_account": [.held],
            "get_own_profile": [.failure, .response(appOwnProfileResponse(appLinkedPresentationProfile()))],
            "get_report_settings": [.response(settingsReport())]])
        let tokens = InMemoryTokenBatchStore()
        let clock = ManualEncounterClock()
        var radios: [FakeBluetoothTransport] = []
        let composition = settingsComposition(transport, defaults: appBackendDefaults(), tokens: tokens,
            store: InMemorySessionStore(session: try appBackendTestSession()), transportFactory: {
                let radio = await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
                radios.append(radio)
                return radio
            })
        await composition.waitForRestoration(); productAuthorize(composition)
        try await tokens.save(EncounterSamples.batch())
        await composition.setParticipation(true)
        XCTAssertTrue(composition.isParticipating)
        let firstRadio = try XCTUnwrap(radios.first)
        try await appBackendEventually { await firstRadio.commands().contains(.startDiscovery) }
        var screen: AccountSettingsModel? = settingsAccountModel(composition)
        weak let destroyedScreen = screen
        let deletion = Task { await screen?.deleteAccount() }
        try await appBackendEventually { await transport.isHeld("delete_own_account") }
        XCTAssertTrue(composition.deletionSuspended)
        XCTAssertFalse(composition.isParticipating)
        let pendingCommands = await firstRadio.commands()
        XCTAssertEqual(pendingCommands.last, .stopDiscovery)
        await transport.release("delete_own_account", with: HTTPResponse(data: Data(), statusCode: 503))
        await deletion.value
        XCTAssertEqual(composition.deletionState, .failed)
        screen = nil
        XCTAssertNil(destroyedScreen)
        await composition.checkAccountAndResume()
        XCTAssertTrue(composition.account.state.isSignedIn)
        XCTAssertTrue(composition.deletionSuspended)
        XCTAssertEqual(composition.deletionError, .init(code: .unavailable))
        XCTAssertEqual(composition.deletionState, .failed)
        XCTAssertFalse(composition.isParticipating)
        let failedCommands = await firstRadio.commands()
        XCTAssertEqual(failedCommands.last, .stopDiscovery)
        XCTAssertEqual(failedCommands.filter { $0 == .startDiscovery }.count,
                       pendingCommands.filter { $0 == .startDiscovery }.count)
        XCTAssertEqual(radios.count, 1)
        await composition.checkAccountAndResume()
        XCTAssertFalse(composition.deletionSuspended)
        XCTAssertTrue(composition.isParticipating)
        XCTAssertTrue(composition.account.state.isSignedIn)
        let resumedRadio = try XCTUnwrap(radios.last)
        XCTAssertEqual(radios.count, 2)
        try await appBackendEventually { await resumedRadio.commands().contains(.startDiscovery) }
        _ = try await composition.settingsSafetyAdapter.reportSettingsActions().load()
        await composition.setParticipation(false)
    }

    func testLostDeletionAnswerThenExpiredAuthorizationOnCheckOrRetrySignsOutAndClearsSuspension() async throws {
        for retryDeletion in [false, true] {
            let expired = ControlledAppBackendTransport.Reply.response(productError("not_authenticated"))
            let transport = productTransport(["delete_own_account": retryDeletion ? [.failure, expired, expired] : [.failure],
                "get_own_profile": retryDeletion ? [] : [expired, expired],
                "token": [.response(appBackendAuthResponse())]])
            let composition = try productComposition(transport)
            await composition.waitForRestoration(); productAuthorize(composition)
            await composition.retryAccountDeletion()
            XCTAssertEqual(composition.deletionState, .failed)
            XCTAssertTrue(composition.account.state.isSignedIn)
            if retryDeletion { await composition.retryAccountDeletion() }
            else { await composition.checkAccountAndResume() }
            XCTAssertEqual(composition.account.state, .signedOut)
            XCTAssertFalse(composition.deletionSuspended)
            XCTAssertEqual(composition.deletionState, .idle)
            XCTAssertFalse(composition.isParticipating)
            let before = await transport.recorded().count
            let flow = AccountFlowModel(composition: composition)
            await flow.start(); await flow.refresh()
            XCTAssertEqual(flow.root, .welcome)
            let after = await transport.recorded().count
            XCTAssertEqual(before, after)
        }
    }

    func testAccountCheckFindingGoneCompletesDeletionWithoutResuming() async throws {
        let transport = productTransport(["delete_own_account": [.failure],
            "get_own_profile": [.response(productError("not_found"))]])
        let composition = try productComposition(transport)
        await composition.waitForRestoration(); productAuthorize(composition)
        await composition.retryAccountDeletion()
        await composition.checkAccountAndResume()
        XCTAssertEqual(composition.account.state, .signedOut)
        XCTAssertTrue(composition.account.accountWasDeleted)
        XCTAssertFalse(composition.deletionSuspended)
        XCTAssertFalse(composition.isParticipating)
    }

    func testReportAndBlockLostAnswersThenNotFoundCompleteSafetyFlow() async throws {
        for block in [false, true] {
            let path = block ? "block_encounter_person" : "report_encounter_person"
            let transport = productTransport([path: [.failure, .response(productError("not_found"))]])
            let composition = try productComposition(transport)
            await composition.waitForRestoration(); productAuthorize(composition)
            var completed = 0
            let model = SafetyReportModel(encounterID: productEncounterID,
                actions: composition.settingsSafetyAdapter.reportActions(encounterID: productEncounterID),
                navigation: .init(completed: { completed += 1 }, reopenEncounter: {}))
            if block { await model.block() }
            else { model.reason = .other; await model.submit() }
            XCTAssertEqual(completed, 0)
            XCTAssertNotNil(model.error)
            await model.retry()
            XCTAssertEqual(completed, 1)
            XCTAssertNil(model.error)
            let calls = await transport.count(path)
            XCTAssertEqual(calls, 2)
            XCTAssertTrue(composition.account.state.isSignedIn)
        }
    }

    func testLegalConfigurationIncludesOnlyValidConfiguredDestinations() {
        let data = SettingsSafetyAdapter.legalData(info: ["TermsURL": "https://example.org/terms",
            "PrivacyURL": "http://example.org/privacy", "SupportURL": "https://example.org/support",
            "ModerationContact": "support@example.org", "CFBundleShortVersionString": "1.0"])
        XCTAssertEqual(data.entries, [.terms, .support]); XCTAssertEqual(data.contact, "support@example.org")
        XCTAssertEqual(data.version, "1.0"); XCTAssertNil(data.privacy)
        XCTAssertFalse(SettingsSafetyAdapter.hasSupport(info: ["SupportURL": "", "ModerationContact": ""]))
        XCTAssertFalse(SettingsSafetyAdapter.hasSupport(info: ["SupportURL": "$(SupportURL)", "ModerationContact": "$(ModerationContact)"]))
        XCTAssertTrue(SettingsSafetyAdapter.hasSupport(info: ["ModerationContact": "support@example.org"]))
    }
}

let settingsBlockID = "00000000-0000-0000-0000-000000000fed"
func settingsReport(hour: Int = 21, minute: Int = 0, enabled: Bool = true) -> HTTPResponse {
    productResponse(["report_hour": hour, "report_minute": minute, "time_zone": "Asia/Tokyo", "notifications_enabled": enabled])
}
func settingsOwnLink() -> [String: Any] {
    ["link_id": productLinkID, "source": "github", "url": "https://github.com/person/work", "title": "Work",
     "description": "Description", "main_language": "Swift", "tags": ["ios"], "opening_text": "Opening",
     "verification_state": "verified", "visibility": "compatible_only", "display_order": 0, "source_item_id": "42"]
}
func settingsBody(_ request: URLRequest) throws -> NSDictionary {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary)
}
@MainActor
func settingsAccountModel(_ composition: AppComposition) -> AccountSettingsModel {
    AccountSettingsModel(data: .init(), actions: composition.settingsSafetyAdapter.accountActions(),
        navigation: .init(back: {}, signedOut: {}, discovery: {}, support: {}))
}
@MainActor
func settingsComposition(_ transport: any HTTPTransport, defaults: UserDefaults,
                         queue: InMemoryReceiptQueue = InMemoryReceiptQueue(),
                         tokens: any TokenBatchStore = InMemoryTokenBatchStore(),
                         keychain: AppMemoryKeychain = AppMemoryKeychain(), store: any SessionStore,
                         center: TestLocalNotificationCenter = TestLocalNotificationCenter(),
                         transportFactory: (@MainActor () async -> any BluetoothTransport)? = nil) -> AppComposition {
    let clock = ManualEncounterClock()
    return AppComposition(configuration: appBackendTestConfiguration(), defaults: defaults, notificationCenter: center,
        trialLogURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("trial.json"),
        transport: transport, keychain: keychain, sessionStore: store, serverTokenStore: tokens,
        signedOutTokenStore: InMemoryTokenBatchStore(), queueOpener: { queue }, transportFactory: transportFactory ?? {
            await FakeBluetoothTransport(phone: .first, link: FakeBluetoothLink(), clock: clock)
        }, clock: clock, uploadScheduler: ManualReceiptUploadScheduler(), now: { appBackendTestNow },
        sessionNetwork: SessionNetworkAvailability(monitorsSystemPath: false), timeZone: { "Asia/Tokyo" })
}


private actor SettingsPurgeTokenStore: TokenBatchStore {
    private var batch: TokenBatch?
    private var failClearing = false
    func setFailClearing(_ value: Bool) { failClearing = value }
    func load() async throws -> TokenBatch? { batch }
    func save(_ batch: TokenBatch) async throws { self.batch = batch }
    func clear() async throws {
        if failClearing { throw BackendError.storageFailure }
        batch = nil
    }
}
