import XCTest
import Foundation
@testable import EncounterBackend

@MainActor
final class Unit4WireTests: XCTestCase {
    func testProtectedFieldsRejectNullAndShellMustAgreeWithAuthorizedFields() async throws {
        for field in ["display_name", "introduction", "contact_detail", "interests", "purposes", "links"] {
            let json = try replacing(unit4DetailJSON, field: field, value: NSNull())
            try await assertInvalid(.getEncounterCard, json: json)
        }
        let shellDetail = String(unit4ShellJSON.dropLast()) + #", "favorite":false,"saved_link_ids":[]}"#
        for json in [try replacing(shellDetail, field: "shell", value: false),
                     try replacing(shellDetail, field: "shell", value: NSNull()),
                     try replacing(shellDetail, field: "shell", value: nil),
                     try replacing(unit4DetailJSON, field: "shell", value: true),
                     try replacing(unit4DetailJSON, field: "links", value: [])] {
            try await assertInvalid(.getEncounterCard, json: json)
        }
    }

    func testRequiredOwnStateAndUUIDsAreStrict() async throws {
        for field in ["favorite", "saved_link_ids"] {
            for value: Any? in [nil, NSNull()] {
                try await assertInvalid(.getEncounterCard, json: replacing(unit4DetailJSON, field: field, value: value))
            }
        }
        try await assertInvalid(.getEncounterCard, json: replacing(unit4DetailJSON, field: "saved_link_ids", value: [unit4LinkID.uuidString]))
        try await assertInvalid(.getEncounterCard, json: replacing(unit4DetailJSON, field: "saved_link_ids", value: [unit4IDString]))
        for procedure in [Unit4Procedure.startSession, .getOwnSession, .stopSession, .redeemQRCode,
                          .getEncounterCard, .setEncounterFavorite, .saveLink, .unsaveLink, .listSavedLinks,
                          .blockEncounterPerson, .listBlocks, .reportEncounterPerson] {
            try await assertInvalid(procedure, json: procedure.responseJSON.replacingOccurrences(of: unit4IDString, with: unit4ID.uuidString))
        }
        for procedure in [Unit4Procedure.getEncounterCard, .saveLink, .unsaveLink, .listSavedLinks] {
            try await assertInvalid(procedure, json: procedure.responseJSON.replacingOccurrences(of: unit4LinkIDString, with: unit4LinkID.uuidString))
        }
    }

    func testDatesUseValidYYYYMMDDWithoutTimestamps() async throws {
        for day in ["2026-2-03", "2026-02-29", "2026-04-31", "2026-00-12", "2026-13-12",
                    "2026-10-00", "0000-01-01", "2026-10-12T00:00:00Z", "２０２６-１０-１２"] {
            for procedure in [Unit4Procedure.getEncounterCard, .listSavedLinks, .getDailyReport,
                              .blockEncounterPerson, .listBlocks] {
                try await assertInvalid(procedure, json: procedure.responseJSON.replacingOccurrences(of: "2026-10-12", with: day))
            }
        }
        XCTAssertNotNil(WireDay(rawValue: "2024-02-29"))
        XCTAssertNotNil(WireDay(rawValue: "2000-02-29"))
        XCTAssertNil(WireDay(rawValue: "1900-02-29"))
        let day = try XCTUnwrap(WireDay(rawValue: "2026-10-12"))
        XCTAssertEqual(try JSONEncoder().encode(day), Data(#""2026-10-12""#.utf8))
    }

    func testSessionAndQRRequireWholeSecondsAndNonNullKeys() async throws {
        for field in ["starts_at", "expires_at", "server_time"] {
            for value: Any? in [nil, NSNull(), 1_800_000_000.5, "1800000000"] {
                try await assertInvalid(.startSession, json: replacing(unit4SessionJSON, field: field, value: value))
            }
        }
        for value: Any? in [nil, NSNull(), 1_800_000_120.5, "1800000120"] {
            try await assertInvalid(.issueQRCode, json: replacing(Unit4Procedure.issueQRCode.responseJSON, field: "expires_at", value: value))
        }
        try await assertInvalid(.startSession, json: "null")
        for code in ["", unit4Code.uppercased(), unit4Code + "0", String(repeating: "g", count: 32)] {
            try await assertInvalid(.issueQRCode, json: replacing(Unit4Procedure.issueQRCode.responseJSON, field: "code", value: code))
        }
    }

    func testFeedOnlyExposesSharedIDsWhenInterestsAreAuthorized() async throws {
        let shell = String(unit4ShellJSON.dropLast()) + #", "favorite":false,"shared_interest_ids":[]}"#
        for card in [shell,
                     try replacing(unit4FeedCardJSON, field: "shared_interest_ids", value: NSNull()),
                     try replacing(unit4FeedCardJSON, field: "favorite", value: nil),
                     try replacing(unit4FeedCardJSON, field: "favorite", value: NSNull())] {
            try await assertInvalid(.getEncounterFeed, json: "{\"cards\":[\(card)],\"truncated\":false}")
        }
        for procedure in [Unit4Procedure.getEncounterFeed, .listEncounterFavorites, .listSavedLinks,
                          .getDailyReport, .revealAmbientNow, .listBlocks] {
            for value: Any? in [nil, NSNull(), "true"] {
                try await assertInvalid(procedure, json: replacing(procedure.responseJSON, field: "truncated", value: value))
            }
        }
        let omitted = try replacing(unit4FeedCardJSON, field: "shared_interest_ids", value: nil)
        let service = EncounterService(client: try serviceClient(StubTransport([
            .response(jsonResponse("{\"cards\":[\(omitted)],\"truncated\":false}"))
        ])))
        let result = try await service.getEncounterFeed()
        XCTAssertEqual(result.cards[0].card.interests, ["swift"])
        XCTAssertNil(result.cards[0].sharedInterestIDs)
    }

    func testVisibleLinkNullableLanguageEnumsAndFutureSources() async throws {
        for replacement in [#""main_language":"Swift""#, #""main_language":null"#] {
            let json = unit4DetailJSON.replacingOccurrences(of: #""main_language":null"#, with: replacement)
                .replacingOccurrences(of: #""unverified""#, with: #""verified""#)
                .replacingOccurrences(of: #""source":"github""#, with: #""source":"future_source""#)
            let service = EncounterService(client: try serviceClient(StubTransport([.response(jsonResponse(json))])))
            let result = try await service.getEncounterCard(encounterID: unit4ID)
            let link = try XCTUnwrap(result.card.links?.first)
            XCTAssertEqual(link.source, "future_source")
            XCTAssertEqual(link.verificationState, .verified)
            XCTAssertEqual(link.mainLanguage, replacement.contains("Swift") ? "Swift" : nil)
        }
        for json in [unit4DetailJSON.replacingOccurrences(of: #""main_language":null,"#, with: ""),
                     unit4DetailJSON.replacingOccurrences(of: "unverified", with: "unknown"),
                     unit4DetailJSON.replacingOccurrences(of: "collaboration", with: "unknown"),
                     try replacing(unit4DetailJSON, field: "kind", value: "unknown")] {
            try await assertInvalid(.getEncounterCard, json: json)
        }
    }

    func testWriteAcknowledgementsRejectFalseFlagsAndWrongStates() async throws {
        for procedure in [Unit4Procedure.cancelQRCode, .deleteEncounter, .deleteOwnAccount, .unblock] {
            try await assertInvalid(procedure, json: procedure.responseJSON.replacingOccurrences(of: "true", with: "false"))
        }
        try await assertInvalid(.saveLink, json: Unit4Procedure.saveLink.responseJSON.replacingOccurrences(of: "true", with: "false"))
        try await assertInvalid(.unsaveLink, json: Unit4Procedure.unsaveLink.responseJSON.replacingOccurrences(of: "false", with: "true"))
        try await assertInvalid(.reportEncounterPerson, json: Unit4Procedure.reportEncounterPerson.responseJSON.replacingOccurrences(of: "open", with: "resolved"))
    }

    func testReportSettingsBoundsAndRequiredNullableReportDay() async throws {
        for (field, value) in [("report_hour", -1), ("report_hour", 24), ("report_minute", -1), ("report_minute", 60)] {
            try await assertInvalid(.getReportSettings, json: replacing(unit4SettingsJSON, field: field, value: value))
        }
        for (hour, minute) in [(0, 0), (23, 59)] {
            let json = try replacing(replacing(unit4SettingsJSON, field: "report_hour", value: hour), field: "report_minute", value: minute)
            let service = ReportService(client: try serviceClient(StubTransport([.response(jsonResponse(json))])))
            let result = try await service.getReportSettings()
            XCTAssertEqual(result.reportHour, hour)
            XCTAssertEqual(result.reportMinute, minute)
        }
        try await assertInvalid(.getDailyReport, json: replacing(Unit4Procedure.getDailyReport.responseJSON, field: "report_day", value: nil))
        try await assertInvalid(.getDailyReport, json: replacing(Unit4Procedure.getDailyReport.responseJSON, field: "report_day", value: NSNull()))
    }

    private func assertInvalid(_ procedure: Unit4Procedure, json: String,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let client = try serviceClient(StubTransport([.response(jsonResponse(json))]))
        do { try await procedure.invoke(client); XCTFail(procedure.rawValue, file: file, line: line) }
        catch { XCTAssertEqual(error as? BackendError, .invalidResponse, procedure.rawValue, file: file, line: line) }
    }

    private func replacing(_ json: String, field: String, value: Any?) throws -> String {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object[field] = value
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
