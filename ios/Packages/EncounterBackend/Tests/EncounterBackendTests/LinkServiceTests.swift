import XCTest
import Foundation
@testable import EncounterBackend

private let linkID = UUID(uuidString: "abcdefab-cdef-abcd-efab-cdefabcdefab")!
private let repositoryID = "9007199254740993"
private let repositoryJSON = #"{"repository_id":"9007199254740993","repository_name":"project","title":"Project","description":"Description","main_language":null,"tags":["swift"],"url":"https://github.com/owner/project"}"#
private let previewJSON = String(repositoryJSON.dropLast()) + #", "opening_text":"Read me","verification_state":"verified"}"#
private let linkJSON = #"{"link_id":"abcdefab-cdef-abcd-efab-cdefabcdefab","source":"github","source_item_id":"9007199254740993","url":"https://github.com/owner/project","title":"Project","description":"Description","main_language":null,"tags":["swift"],"opening_text":"Read me","visibility":"compatible_only","verification_state":"verified","display_order":0}"#

@MainActor
final class LinkServiceTests: XCTestCase {
    func testAllOwnLinkProceduresAndExactBodies() async throws {
        let transport = StubTransport([
            .response(jsonResponse("[\(linkJSON)]")), .response(jsonResponse(linkJSON)),
            .response(jsonResponse(#"{"deleted":true}"#)), .response(jsonResponse("[\(linkJSON)]")),
            .response(jsonResponse(#"{"connected":true,"handle":null}"#)),
            .response(jsonResponse(#"{"connected":false,"handle":null}"#)),
            .response(jsonResponse("[]")), .response(jsonResponse("[]"))
        ])
        let service = OwnLinkService(client: try serviceClient(transport))
        let links = try await service.listOwnLinks()
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].linkID, linkID)
        XCTAssertEqual(links[0].sourceItemID, repositoryID)
        let updated = try await service.updateOwnLink(linkID: linkID, title: "Edited", description: "",
            mainLanguage: nil, tags: [], openingText: "", visibility: .private)
        XCTAssertEqual(updated, links[0])
        try await service.deleteOwnLink(linkID: linkID)
        let reordered = try await service.reorderOwnLinks(linkIDs: [linkID])
        XCTAssertEqual(reordered, links)
        let connection = try await service.getGitHubConnection()
        XCTAssertTrue(connection.connected)
        XCTAssertNil(connection.handle)
        let disconnected = try await service.disconnectGitHub()
        XCTAssertFalse(disconnected.connected)
        let empty = try await service.listOwnLinks()
        XCTAssertTrue(empty.isEmpty)
        let emptyReorder = try await service.reorderOwnLinks(linkIDs: [])
        XCTAssertTrue(emptyReorder.isEmpty)
        let requests = await transport.recorded()
        let expectations = [
            ("list_own_links", "{}"),
            ("update_own_link", #"{"link_id":"abcdefab-cdef-abcd-efab-cdefabcdefab","title":"Edited","description":"","main_language":null,"tags":[],"opening_text":"","visibility":"private"}"#),
            ("delete_own_link", #"{"link_id":"abcdefab-cdef-abcd-efab-cdefabcdefab"}"#),
            ("reorder_own_links", #"{"link_ids":["abcdefab-cdef-abcd-efab-cdefabcdefab"]}"#),
            ("get_github_connection", "{}"), ("disconnect_github", "{}"),
            ("list_own_links", "{}"), ("reorder_own_links", #"{"link_ids":[]}"#)
        ]
        XCTAssertEqual(requests.count, expectations.count)
        for (request, expected) in zip(requests, expectations) {
            XCTAssertEqual(request.url?.path, "/base/rest/v1/rpc/" + expected.0)
            try assertJSONEqual(XCTUnwrap(request.httpBody), Data(expected.1.utf8))
        }
    }

    func testFiveEdgeActionsAndExactBodies() async throws {
        let transport = StubTransport([
            .response(jsonResponse(#"{"connected":true,"handle":"owner"}"#)),
            .response(jsonResponse("{\"repositories\":[\(repositoryJSON)],\"next_page\":2}")),
            .response(jsonResponse("{\"preview\":\(previewJSON)}")),
            .response(jsonResponse("{\"link\":\(linkJSON)}")),
            .response(jsonResponse("{\"link_id\":\"\(linkID.uuidString.lowercased())\",\"preview\":\(previewJSON)}")),
            .response(jsonResponse(#"{"repositories":[],"next_page":null}"#)),
            .response(jsonResponse("{\"link\":\(linkJSON)}"))
        ])
        let service = try gitHubService(transport)
        let connection = try await service.syncIdentity()
        XCTAssertEqual(connection.handle, "owner")
        let page = try await service.listRepositories(page: 1)
        XCTAssertEqual(page.nextPage, 2)
        XCTAssertEqual(page.repositories[0].repositoryID, repositoryID)
        let preview = try await service.previewRepository(repositoryID: repositoryID, repositoryName: "project")
        XCTAssertEqual(preview.openingText, "Read me")
        let saved = try await service.saveRepository(repositoryID: repositoryID, repositoryName: "project",
            title: "Edited", description: "", mainLanguage: nil, tags: [], openingText: "",
            visibility: .private, replaceExisting: false)
        XCTAssertEqual(saved.linkID, linkID)
        let refreshed = try await service.refreshPreview(linkID: linkID)
        XCTAssertEqual(refreshed.linkID, linkID)
        XCTAssertEqual(refreshed.preview, preview)
        let end = try await service.listRepositories(page: 1000)
        XCTAssertNil(end.nextPage)
        XCTAssertTrue(end.repositories.isEmpty)
        _ = try await service.saveRepository(repositoryID: repositoryID, repositoryName: "project",
            title: "Edited", description: "", mainLanguage: "Swift", tags: ["tag"], openingText: "",
            visibility: .everyoneEligible, replaceExisting: true)
        let expectations = [
            #"{"action":"sync_identity"}"#,
            #"{"action":"list_repositories","page":1}"#,
            #"{"action":"preview_repository","repository_id":"9007199254740993","repository_name":"project"}"#,
            #"{"action":"save_repository","repository_id":"9007199254740993","repository_name":"project","title":"Edited","description":"","main_language":null,"tags":[],"opening_text":"","visibility":"private","replace_existing":false}"#,
            #"{"action":"refresh_preview","link_id":"abcdefab-cdef-abcd-efab-cdefabcdefab"}"#,
            #"{"action":"list_repositories","page":1000}"#,
            #"{"action":"save_repository","repository_id":"9007199254740993","repository_name":"project","title":"Edited","description":"","main_language":"Swift","tags":["tag"],"opening_text":"","visibility":"everyone_eligible","replace_existing":true}"#
        ]
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, expectations.count)
        for (request, expected) in zip(requests, expectations) {
            XCTAssertEqual(request.url?.absoluteString, "https://backend.example/base/functions/v1/github-links")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            try assertJSONEqual(XCTUnwrap(request.httpBody), Data(expected.utf8))
        }
    }

    func testWireRoundTripsRequireNullFieldsAndLosslessIDs() throws {
        try roundTrip(LinkTransfer.self, json: linkJSON)
        try roundTrip(GitHubConnectionTransfer.self, json: #"{"connected":false,"handle":null}"#)
        try roundTrip(GitHubConnectionTransfer.self, json: #"{"connected":true,"handle":"owner"}"#)
        try roundTrip(RepositoryTransfer.self, json: repositoryJSON)
        try roundTrip(RepositoryPreviewTransfer.self, json: previewJSON)
        try roundTrip(RepositoryPageTransfer.self, json: #"{"repositories":[],"next_page":null}"#)
        try roundTrip(LinkTransfer.self, json: linkJSON.replacingOccurrences(of: "null", with: #""Swift""#))
        for json in [linkJSON.replacingOccurrences(of: #""main_language":null,"#, with: ""),
                     linkJSON.replacingOccurrences(of: "abcdefab-cdef-abcd-efab-cdefabcdefab", with: linkID.uuidString),
                     linkJSON.replacingOccurrences(of: #""verified""#, with: #""unverified""#),
                     linkJSON.replacingOccurrences(of: "\"display_order\":0", with: "\"display_order\":-1"),
                     linkJSON.replacingOccurrences(of: #""github""#, with: #""zenn""#)] {
            XCTAssertThrowsError(try JSONDecoder().decode(LinkTransfer.self, from: Data(json.utf8)))
        }
        for id in ["0", "01", "-1", "1.5", "9223372036854775808"] {
            XCTAssertThrowsError(try JSONDecoder().decode(RepositoryTransfer.self,
                from: Data(repositoryJSON.replacingOccurrences(of: repositoryID, with: id).utf8)))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(RepositoryTransfer.self,
            from: Data(repositoryJSON.replacingOccurrences(of: "\"\(repositoryID)\"", with: repositoryID).utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(GitHubConnectionTransfer.self, from: Data(#"{"connected":true}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(GitHubConnectionTransfer.self, from: Data(#"{"connected":false,"handle":"owner"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(RepositoryPageTransfer.self, from: Data(#"{"repositories":[]}"#.utf8)))
    }

    func testDataAPICoercionMapsToFailingLinkParametersInSignatureOrder() async throws {
        struct Update: Encodable, Sendable {
            let link_id = "invalid-uuid"
            let title = "Title"
            let description = ""
            let main_language: String? = nil
            let tags = "not-an-array"
            let opening_text = ""
            let visibility = "private"
        }
        for code in ["22P02", "22003", "42804"] {
            let transport = StubTransport([.response(jsonResponse("{\"code\":\"\(code)\",\"message\":\"unprintable-server-material\"}", status: 400))])
            let client = try serviceClient(transport)
            do { let _: LinkTransfer = try await client.call("update_own_link", parameters: Update()); XCTFail() }
            catch { XCTAssertEqual(error as? BackendError, .invalidInput(fields: ["link_id", "main_language", "tags"])) }
        }
        struct IDs: Encodable, Sendable { let link_ids = ["invalid-uuid"] }
        let transport = StubTransport([.response(jsonResponse(#"{"code":"22P02","message":"malformed UUID"}"#, status: 400))])
        do { let _: [LinkTransfer] = try await serviceClient(transport).call("reorder_own_links", parameters: IDs()); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .invalidInput(fields: ["link_ids"])) }
    }

    func testInvalidSuccessFlagsAreRejected() async throws {
        let transport = StubTransport([.response(jsonResponse(#"{"deleted":false}"#)),
                                       .response(jsonResponse(#"{"connected":true,"handle":null}"#))])
        let service = OwnLinkService(client: try serviceClient(transport))
        do { try await service.deleteOwnLink(linkID: linkID); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .invalidResponse) }
        do { _ = try await service.disconnectGitHub(); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .invalidResponse) }
    }

    private func roundTrip<Value: Codable & Equatable>(_ type: Value.Type, json: String) throws {
        let data = Data(json.utf8)
        let value = try JSONDecoder().decode(type, from: data)
        let encoded = try JSONEncoder().encode(value)
        try assertJSONEqual(encoded, data)
        XCTAssertEqual(try JSONDecoder().decode(type, from: encoded), value)
    }
}

@MainActor
func assertJSONEqual(_ actual: Data, _ expected: Data, file: StaticString = #filePath, line: UInt = #line) throws {
    let actualObject = try JSONSerialization.jsonObject(with: actual) as AnyObject
    let expectedObject = try JSONSerialization.jsonObject(with: expected) as AnyObject
    XCTAssertTrue(actualObject.isEqual(expectedObject), file: file, line: line)
}

func gitHubService(_ transport: StubTransport) throws -> GitHubLinksService {
    let sessions = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
    return GitHubLinksService(client: EdgeFunctionClient(configuration: testConfiguration(), transport: transport, sessions: sessions))
}
