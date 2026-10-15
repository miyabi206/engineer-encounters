import XCTest
import Foundation
@testable import EncounterBackend

@MainActor
final class Unit4ServiceTests: XCTestCase {
    func testEveryProcedureUsesExactRequestPathAndBody() async throws {
        for procedure in Unit4Procedure.allCases {
            let transport = StubTransport([.response(jsonResponse(procedure.responseJSON))])
            try await procedure.invoke(serviceClient(transport))
            let requests = await transport.recorded()
            XCTAssertEqual(requests.count, 1, procedure.rawValue)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.absoluteString, "https://backend.example/base/rest/v1/rpc/" + procedure.rawValue)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            try assertJSONEqual(XCTUnwrap(request.httpBody), Data(procedure.requestJSON.utf8))
        }
    }

    func testSessionsDecodeFullAcknowledgementsAndNull() async throws {
        let transport = StubTransport([
            .response(jsonResponse(unit4SessionJSON)), .response(jsonResponse(unit4SessionJSON)),
            .response(jsonResponse(unit4SessionJSON)), .response(jsonResponse("null")), .response(jsonResponse("null"))
        ])
        let service = EncounterSessionService(client: try serviceClient(transport))
        let start = try await service.startSession()
        let current = try await service.getOwnSession()
        let stop = try await service.stopSession()
        XCTAssertEqual(start.sessionID, unit4ID)
        XCTAssertEqual(start.startsAt.unixSeconds, 1_800_000_000)
        XCTAssertEqual(start.expiresAt.unixSeconds, 1_800_007_200)
        XCTAssertEqual(start.serverTime.unixSeconds, 1_800_000_001)
        XCTAssertEqual(current, start)
        XCTAssertEqual(stop, start)
        let absent = try await service.getOwnSession()
        let stopped = try await service.stopSession()
        XCTAssertNil(absent)
        XCTAssertNil(stopped)
    }

    func testQRDecodingAndExactScannerPayload() async throws {
        let transport = StubTransport([
            .response(jsonResponse(Unit4Procedure.issueQRCode.responseJSON)),
            .response(jsonResponse(Unit4Procedure.cancelQRCode.responseJSON)),
            .response(jsonResponse(Unit4Procedure.redeemQRCode.responseJSON))
        ])
        let service = QRService(client: try serviceClient(transport))
        let issued = try await service.issueQRCode()
        XCTAssertEqual(issued.code, unit4Code)
        XCTAssertEqual(issued.expiresAt.unixSeconds, 1_800_000_120)
        XCTAssertEqual(issued.payload, "EEQR1:" + unit4Code)
        let cancelled = try await service.cancelQRCode()
        XCTAssertTrue(cancelled.cancelled)
        let redeemed = try await service.redeemQRCode(payload: issued.payload)
        XCTAssertEqual(redeemed.encounterID, unit4ID)
        let requests = await transport.recorded()
        try assertJSONEqual(XCTUnwrap(requests.last?.httpBody), Data(Unit4Procedure.redeemQRCode.requestJSON.utf8))
        for payload in [unit4Code, "https://example.com/" + issued.payload, issued.payload + "\n",
                        issued.payload + "x", "eeqr1:" + unit4Code, "EEQR1:" + unit4Code.uppercased(),
                        "EEQR1:" + String(unit4Code.dropLast()), "EEQR1:" + String(repeating: "é", count: 32)] {
            do { _ = try await service.redeemQRCode(payload: payload); XCTFail(payload) }
            catch { XCTAssertEqual(error as? BackendError, .invalidInput(fields: ["code"])) }
        }
        let after = await transport.recorded()
        XCTAssertEqual(after.count, 3)
    }

    func testDetailOwnStateAndAllAuthorizedCardFields() async throws {
        let service = EncounterService(client: try serviceClient(StubTransport([.response(jsonResponse(unit4DetailJSON))])))
        let result = try await service.getEncounterCard(encounterID: unit4ID)
        XCTAssertTrue(result.favorite)
        XCTAssertEqual(result.savedLinkIDs, [unit4LinkID])
        let card = result.card
        XCTAssertEqual(card.encounterID, unit4ID)
        XCTAssertEqual(card.kind, .session)
        XCTAssertEqual(card.day.rawValue, "2026-10-12")
        XCTAssertEqual(card.displayName, "Name")
        XCTAssertEqual(card.introduction, "Intro")
        XCTAssertEqual(card.contactDetail, "Contact")
        XCTAssertEqual(card.interests, ["swift"])
        XCTAssertEqual(card.purposes, [.discovery, .collaboration])
        XCTAssertNil(card.shell)
        let link = try XCTUnwrap(card.links?.first)
        XCTAssertEqual(link.linkID, unit4LinkID)
        XCTAssertEqual(link.source, "github")
        XCTAssertEqual(link.url, "https://github.com/owner/project")
        XCTAssertEqual(link.title, "Project")
        XCTAssertEqual(link.description, "Description")
        XCTAssertNil(link.mainLanguage)
        XCTAssertEqual(link.tags, ["swift"])
        XCTAssertEqual(link.openingText, "Read me")
        XCTAssertEqual(link.verificationState, .unverified)
    }

    func testShellAndPartiallyAuthorizedDetailsAndEmptyOwnState() async throws {
        for base in [unit4ShellJSON,
                     "{\"encounter_id\":\"\(unit4IDString)\",\"kind\":\"qr\",\"day\":\"2026-10-12\",\"display_name\":\"Name\"}"] {
            let json = String(base.dropLast()) + #", "favorite":false,"saved_link_ids":[]}"#
            let service = EncounterService(client: try serviceClient(StubTransport([.response(jsonResponse(json))])))
            let result = try await service.getEncounterCard(encounterID: unit4ID)
            XCTAssertFalse(result.favorite)
            XCTAssertEqual(result.savedLinkIDs, [])
            XCTAssertNil(result.card.introduction)
            XCTAssertNil(result.card.contactDetail)
            XCTAssertNil(result.card.interests)
            XCTAssertNil(result.card.purposes)
            XCTAssertNil(result.card.links)
            if base == unit4ShellJSON {
                XCTAssertTrue(result.card.shell == true)
                XCTAssertNil(result.card.displayName)
            } else {
                XCTAssertNil(result.card.shell)
                XCTAssertEqual(result.card.displayName, "Name")
            }
        }
    }

    func testEveryFeedResponseEmptyCollectionsShellAndTruncation() async throws {
        let shell = String(unit4ShellJSON.dropLast()) + #", "favorite":false}"#
        let noOverlap = unit4FeedCardJSON.replacingOccurrences(of: #""shared_interest_ids":["swift"]"#, with: #""shared_interest_ids":[]"#)
        for procedure in [Unit4Procedure.getEncounterFeed, .listEncounterFavorites, .revealAmbientNow] {
            for (cards, truncated) in [("[]", false), ("[\(unit4FeedCardJSON)]", true), ("[\(shell),\(noOverlap)]", false)] {
                let transport = StubTransport([.response(jsonResponse("{\"cards\":\(cards),\"truncated\":\(truncated)}"))])
                let client = try serviceClient(transport)
                let result: EncounterFeedTransfer
                switch procedure {
                case .getEncounterFeed: result = try await EncounterService(client: client).getEncounterFeed()
                case .listEncounterFavorites: result = try await EncounterService(client: client).listEncounterFavorites()
                default: result = try await ReportService(client: client).revealAmbientNow()
                }
                XCTAssertEqual(result.truncated, truncated)
                if cards == "[]" { XCTAssertTrue(result.cards.isEmpty) }
                else if truncated {
                    XCTAssertEqual(result.cards.count, 1)
                    XCTAssertTrue(result.cards[0].favorite)
                    XCTAssertEqual(result.cards[0].sharedInterestIDs, ["swift"])
                } else {
                    XCTAssertEqual(result.cards.count, 2)
                    XCTAssertTrue(result.cards[0].card.shell == true)
                    XCTAssertFalse(result.cards[0].favorite)
                    XCTAssertNil(result.cards[0].sharedInterestIDs)
                    XCTAssertEqual(result.cards[1].sharedInterestIDs, [])
                }
            }
        }
    }

    func testFavoritesSavedReferencesAndEncounterDeletion() async throws {
        for favorite in [true, false] {
            let json = "{\"encounter_id\":\"\(unit4IDString)\",\"favorite\":\(favorite)}"
            let transport = StubTransport([.response(jsonResponse(json))])
            let result = try await EncounterService(client: serviceClient(transport))
                .setEncounterFavorite(encounterID: unit4ID, favorite: favorite)
            XCTAssertEqual(result.encounterID, unit4ID)
            XCTAssertEqual(result.favorite, favorite)
            let requests = await transport.recorded()
            try assertJSONEqual(XCTUnwrap(requests.first?.httpBody), Data(json.utf8))
        }
        let transport = StubTransport([
            .response(jsonResponse(Unit4Procedure.saveLink.responseJSON)),
            .response(jsonResponse(Unit4Procedure.unsaveLink.responseJSON)),
            .response(jsonResponse(Unit4Procedure.listSavedLinks.responseJSON)),
            .response(jsonResponse(#"{"links":[],"truncated":false}"#)),
            .response(jsonResponse(#"{"deleted":true}"#))
        ])
        let service = EncounterService(client: try serviceClient(transport))
        let saved = try await service.saveLink(encounterID: unit4ID, linkID: unit4LinkID)
        XCTAssertEqual(saved.encounterID, unit4ID)
        XCTAssertEqual(saved.linkID, unit4LinkID)
        XCTAssertTrue(saved.saved)
        let unsaved = try await service.unsaveLink(encounterID: unit4ID, linkID: unit4LinkID)
        XCTAssertEqual(unsaved.encounterID, unit4ID)
        XCTAssertEqual(unsaved.linkID, unit4LinkID)
        XCTAssertFalse(unsaved.saved)
        let references = try await service.listSavedLinks()
        XCTAssertTrue(references.truncated)
        XCTAssertEqual(references.links.count, 1)
        XCTAssertEqual(references.links[0].encounterID, unit4ID)
        XCTAssertEqual(references.links[0].day.rawValue, "2026-10-12")
        XCTAssertEqual(references.links[0].kind, .qr)
        XCTAssertEqual(references.links[0].link.linkID, unit4LinkID)
        let empty = try await service.listSavedLinks()
        XCTAssertEqual(empty.links, [])
        XCTAssertFalse(empty.truncated)
        let deleted = try await service.deleteEncounter(encounterID: unit4ID)
        XCTAssertTrue(deleted.deleted)
    }

    func testReportSettingsWritesAndDailyReportShapes() async throws {
        let transport = StubTransport([
            .response(jsonResponse(unit4SettingsJSON)), .response(jsonResponse(unit4SettingsJSON)),
            .response(jsonResponse(unit4SettingsJSON.replacingOccurrences(of: "false", with: "true"))),
            .response(jsonResponse(Unit4Procedure.getDailyReport.responseJSON)),
            .response(jsonResponse(#"{"report_day":null,"cards":[],"truncated":false}"#)),
            .response(jsonResponse(#"{"report_day":"2026-10-12","cards":[],"truncated":false}"#))
        ])
        let service = ReportService(client: try serviceClient(transport))
        let settings = try await service.getReportSettings()
        XCTAssertEqual(settings.reportHour, 21)
        XCTAssertEqual(settings.reportMinute, 30)
        XCTAssertEqual(settings.timeZone, "Asia/Tokyo")
        XCTAssertFalse(settings.notificationsEnabled)
        let changedTime = try await service.setReportTime(hour: 21, minute: 30)
        XCTAssertEqual(changedTime, settings)
        let changedNotifications = try await service.setNotificationsEnabled(enabled: true)
        XCTAssertTrue(changedNotifications.notificationsEnabled)
        let daily = try await service.getDailyReport()
        XCTAssertEqual(daily.reportDay?.rawValue, "2026-10-12")
        XCTAssertEqual(daily.cards.count, 1)
        XCTAssertEqual(daily.cards[0].card.kind, .ambient)
        XCTAssertTrue(daily.truncated)
        let absent = try await service.getDailyReport()
        XCTAssertNil(absent.reportDay)
        XCTAssertEqual(absent.cards, [])
        XCTAssertFalse(absent.truncated)
        let closedEmpty = try await service.getDailyReport()
        XCTAssertEqual(closedEmpty.reportDay?.rawValue, "2026-10-12")
        XCTAssertEqual(closedEmpty.cards, [])
        XCTAssertFalse(closedEmpty.truncated)
        let requests = await transport.recorded()
        try assertJSONEqual(XCTUnwrap(requests[2].httpBody), Data(#"{"enabled":true}"#.utf8))
    }

    func testBlocksReportsEveryReasonAndHardAccountDeletion() async throws {
        let transport = StubTransport([
            .response(jsonResponse(unit4BlockJSON)),
            .response(jsonResponse(Unit4Procedure.listBlocks.responseJSON)),
            .response(jsonResponse(#"{"blocks":[],"truncated":false}"#)),
            .response(jsonResponse(#"{"unblocked":true}"#))
        ] + EncounterReportReason.allCases.map { _ in .response(jsonResponse(Unit4Procedure.reportEncounterPerson.responseJSON)) }
          + [.response(jsonResponse(#"{"deleted":true}"#))])
        let client = try serviceClient(transport)
        let service = SafetyService(client: client)
        let block = try await service.blockEncounterPerson(encounterID: unit4ID)
        XCTAssertEqual(block.blockID, unit4ID)
        XCTAssertEqual(block.placedDay.rawValue, "2026-10-12")
        let blocks = try await service.listBlocks()
        XCTAssertEqual(blocks.blocks, [block])
        XCTAssertTrue(blocks.truncated)
        let empty = try await service.listBlocks()
        XCTAssertTrue(empty.blocks.isEmpty)
        XCTAssertFalse(empty.truncated)
        let unblocked = try await service.unblock(blockID: unit4ID)
        XCTAssertTrue(unblocked.unblocked)
        for reason in EncounterReportReason.allCases {
            let result = try await service.reportEncounterPerson(encounterID: unit4ID, reason: reason,
                linkID: reason == .impersonation ? unit4LinkID : nil)
            XCTAssertEqual(result.reportID, unit4ID)
            XCTAssertEqual(result.status, .open)
        }
        let deleted = try await AccountDeletionService(client: client).deleteOwnAccount()
        XCTAssertTrue(deleted.deleted)
        let requests = await transport.recorded()
        for (index, reason) in EncounterReportReason.allCases.enumerated() {
            let link = reason == .impersonation ? "\"\(unit4LinkIDString)\"" : "null"
            let expected = "{\"encounter_id\":\"\(unit4IDString)\",\"reason\":\"\(reason.rawValue)\",\"link_id\":\(link)}"
            try assertJSONEqual(XCTUnwrap(requests[index + 4].httpBody), Data(expected.utf8))
        }
    }
}
