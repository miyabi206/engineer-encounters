import XCTest
import Foundation
import EncounterBackend

@MainActor
final class OwnAccountTests: XCTestCase {
    func testEveryMutationUsesExactFunctionAndParameterKeys() async throws {
        let transport = StubTransport(Array(repeating: .response(jsonResponse("", status: 204)), count: 8))
        let service = OwnAccountService(client: try serviceClient(transport))
        try await service.acceptDeclarations(age18: true, termsVersion: "terms", privacyVersion: "privacy")
        try await service.registerTimeZone("Asia/Tokyo")
        try await service.updateOwnProfile(displayName: " Name ", introduction: "Intro", contactDetail: "Contact")
        try await service.setOwnInterests(["swift", "design"])
        try await service.setOwnPurposes([.discovery, .collaboration])
        try await service.setMinimumSharedInterests(10)
        try await service.setFieldVisibility(field: .contactDetail, level: .compatibleOnly)
        try await service.setDiscovery(enabled: false)
        let expected: [(String, String)] = [
            ("accept_declarations", #"{"age_18":true,"terms_version":"terms","privacy_version":"privacy"}"#),
            ("register_time_zone", #"{"time_zone":"Asia/Tokyo"}"#),
            ("update_own_profile", #"{"display_name":" Name ","introduction":"Intro","contact_detail":"Contact"}"#),
            ("set_own_interests", #"{"interest_ids":["swift","design"]}"#),
            ("set_own_purposes", #"{"purposes":["discovery","collaboration"]}"#),
            ("set_minimum_shared_interests", #"{"value":10}"#),
            ("set_field_visibility", #"{"field":"contact_detail","level":"compatible_only"}"#),
            ("set_discovery", #"{"enabled":false}"#)
        ]
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, expected.count)
        for (request, expected) in zip(requests, expected) {
            XCTAssertEqual(request.url?.lastPathComponent, expected.0)
            let actual = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary
            let body = try JSONSerialization.jsonObject(with: Data(expected.1.utf8)) as? NSDictionary
            XCTAssertEqual(actual, body)
        }
    }

    func testCompleteOwnProfileAndOrderedInterestList() async throws {
        let transport = StubTransport([
            .response(jsonResponse(profileJSON)),
            .response(jsonResponse("""
            [{"interest_id":"swift","label_ja":"スイフト","label_en":"Swift","display_order":2},
             {"interest_id":"design","label_ja":"設計","label_en":"Design","display_order":3}]
            """))
        ])
        let service = OwnAccountService(client: try serviceClient(transport))
        let profile = try await service.getOwnProfile()
        XCTAssertEqual(profile.displayName, "Name")
        XCTAssertEqual(profile.introduction, "Intro")
        XCTAssertEqual(profile.contactDetail, "Contact")
        XCTAssertEqual(profile.interests, ["swift"])
        XCTAssertEqual(profile.purposes, [.discovery, .collaboration])
        XCTAssertEqual(profile.minimumSharedInterests, 3)
        XCTAssertEqual(profile.fieldVisibility[.displayName], .everyoneEligible)
        XCTAssertEqual(profile.fieldVisibility[.introduction], .compatibleOnly)
        XCTAssertEqual(profile.fieldVisibility[.interests], .everyoneEligible)
        XCTAssertEqual(profile.fieldVisibility[.purposes], .compatibleOnly)
        XCTAssertEqual(profile.fieldVisibility[.contactDetail], .private)
        XCTAssertTrue(profile.discoveryOn)
        XCTAssertEqual(profile.linkCount, 2)
        XCTAssertTrue(profile.prerequisites.displayName)
        XCTAssertTrue(profile.prerequisites.introduction)
        XCTAssertTrue(profile.prerequisites.interest)
        XCTAssertTrue(profile.prerequisites.link)
        XCTAssertTrue(profile.declarationsRecorded)
        XCTAssertEqual(profile.timeZone, "Asia/Tokyo")
        XCTAssertEqual(profile.moderationState, .active)
        let interests = try await service.listInterests()
        XCTAssertEqual(interests.map(\.interestID), ["swift", "design"])
        XCTAssertEqual(interests.map(\.id), ["swift", "design"])
        XCTAssertEqual(interests.map(\.labelJA), ["スイフト", "設計"])
        XCTAssertEqual(interests.map(\.labelEN), ["Swift", "Design"])
        XCTAssertEqual(interests.map(\.displayOrder), [2, 3])
        let requests = await transport.recorded()
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["get_own_profile", "list_interests"])
        for request in requests {
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary
            XCTAssertEqual(body, [:])
        }
    }

    func testEmptyProfileBeforeDeclarationsAndEveryModerationState() async throws {
        let empty = """
        {"display_name":"","introduction":"","contact_detail":"","interests":[],"purposes":[],
         "minimum_shared_interests":1,"field_visibility":{"display_name":"everyone_eligible",
         "introduction":"everyone_eligible","interests":"everyone_eligible","purposes":"everyone_eligible",
         "contact_detail":"private"},"discovery_on":false,"link_count":0,
         "prerequisites":{"display_name":false,"introduction":false,"interest":false,"link":false},
         "declarations_recorded":false,"time_zone":null,"moderation_state":null}
        """
        let service = OwnAccountService(client: try serviceClient(StubTransport([.response(jsonResponse(empty))])))
        let profile = try await service.getOwnProfile()
        XCTAssertEqual(profile.displayName, "")
        XCTAssertEqual(profile.introduction, "")
        XCTAssertEqual(profile.contactDetail, "")
        XCTAssertEqual(profile.interests, [])
        XCTAssertEqual(profile.purposes, [])
        XCTAssertEqual(profile.minimumSharedInterests, 1)
        XCTAssertFalse(profile.discoveryOn)
        XCTAssertEqual(profile.linkCount, 0)
        XCTAssertFalse(profile.prerequisites.displayName)
        XCTAssertFalse(profile.prerequisites.introduction)
        XCTAssertFalse(profile.prerequisites.interest)
        XCTAssertFalse(profile.prerequisites.link)
        XCTAssertFalse(profile.declarationsRecorded)
        XCTAssertNil(profile.timeZone)
        XCTAssertNil(profile.moderationState)
        for state in ModerationState.allCases {
            let json = profileJSON.replacingOccurrences(of: #""active""#, with: "\"\(state.rawValue)\"")
            let client = try serviceClient(StubTransport([.response(jsonResponse(json))]))
            let decoded = try await OwnAccountService(client: client).getOwnProfile()
            XCTAssertEqual(decoded.moderationState, state)
        }
    }

    func testEveryVisibilityFieldAndLevelAndEmptySelections() async throws {
        let count = ProfileField.allCases.count * VisibilityLevel.allCases.count + 2
        let transport = StubTransport(Array(repeating: .response(jsonResponse("null")), count: count))
        let service = OwnAccountService(client: try serviceClient(transport))
        for field in ProfileField.allCases {
            for level in VisibilityLevel.allCases { try await service.setFieldVisibility(field: field, level: level) }
        }
        try await service.setOwnInterests([])
        try await service.setOwnPurposes([])
        let requests = await transport.recorded()
        var index = 0
        for field in ProfileField.allCases {
            for level in VisibilityLevel.allCases {
                let body = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[index].httpBody)) as? [String: String]
                XCTAssertEqual(body, ["field": field.rawValue, "level": level.rawValue])
                index += 1
            }
        }
        for (request, key) in zip(requests.suffix(2), ["interest_ids", "purposes"]) {
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: [String]]
            XCTAssertEqual(body, [key: []])
        }
    }

    func testMalformedProfileAndInterestKeysAndEnumsAreSanitized() async throws {
        for json in [
            profileJSON.replacingOccurrences(of: "active", with: "unknown"),
            profileJSON.replacingOccurrences(of: "collaboration", with: "unknown"),
            profileJSON.replacingOccurrences(of: "compatible_only", with: "unknown"),
            profileJSON.replacingOccurrences(of: "display_name", with: "displayName"),
            profileJSON.replacingOccurrences(of: #""link_count":2"#, with: #""link_count":"2""#)
        ] {
            let service = OwnAccountService(client: try serviceClient(StubTransport([.response(jsonResponse(json))])))
            do { _ = try await service.getOwnProfile(); XCTFail("Must reject invalid response") }
            catch { XCTAssertEqual(error as? BackendError, .invalidResponse) }
        }
        let service = OwnAccountService(client: try serviceClient(StubTransport([
            .response(jsonResponse(#"[{"interestID":"swift","label_ja":"ja","label_en":"en","display_order":1}]"#))
        ])))
        do { _ = try await service.listInterests(); XCTFail("Must require interest_id") }
        catch { XCTAssertEqual(error as? BackendError, .invalidResponse) }
    }

    func testOwnAccountPropagatesContractErrors() async throws {
        let cases: [(String, BackendError)] = [
            ("declaration_required", .declarationRequired), ("account_not_ready", .accountNotReady),
            ("invalid_input", .invalidInput(fields: ["display_name"])),
            ("prerequisite_missing", .prerequisiteMissing(fields: ["display_name"])),
            ("rate_limited", .rateLimited), ("not_found", .notFound)
        ]
        for (code, expected) in cases {
            let service = OwnAccountService(client: try serviceClient(StubTransport([.response(jsonResponse(
                "{\"message\":\"\(code)\",\"details\":\"display_name\"}", status: 400
            ))])))
            do { try await service.setDiscovery(enabled: true); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? BackendError, expected) }
        }
    }

    private var profileJSON: String {
        """
        {"display_name":"Name","introduction":"Intro","contact_detail":"Contact","interests":["swift"],
         "purposes":["discovery","collaboration"],"minimum_shared_interests":3,
         "field_visibility":{"display_name":"everyone_eligible","introduction":"compatible_only",
          "interests":"everyone_eligible","purposes":"compatible_only","contact_detail":"private"},
         "discovery_on":true,"link_count":2,
         "prerequisites":{"display_name":true,"introduction":true,"interest":true,"link":true},
         "declarations_recorded":true,"time_zone":"Asia/Tokyo","moderation_state":"active"}
        """
    }
}
