import XCTest
import Foundation
@testable import EncounterBackend

@MainActor
final class EdgeFunctionTests: XCTestCase {
    func testUnauthorizedRetriesTheSameBodyOnce() async throws {
        let transport = StubTransport([.response(edgeFailure("not_authenticated", status: 401)),
            .response(authResponse()), .response(jsonResponse(#"{"connected":true,"handle":null}"#))])
        let connection = try await gitHubService(transport).syncIdentity()
        XCTAssertTrue(connection.connected)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].url?.path, "/base/auth/v1/token")
        XCTAssertEqual(requests[0].url, requests[2].url)
        XCTAssertEqual(requests[0].httpBody, requests[2].httpBody)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
    }

    func testRepeatedUnauthorizedAndRefreshAccountChangeCannotReplay() async throws {
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        for changesAccount in [false, true] {
            let unauthorized = edgeFailure("not_authenticated", status: 401)
            var steps: [StubTransport.Step] = [.response(unauthorized),
                .response(authResponse(userID: changesAccount ? otherID : testUserID))]
            if !changesAccount { steps.append(.response(unauthorized)) }
            let transport = StubTransport(steps)
            let store = InMemorySessionStore(session: try testSession())
            let manager = testManager(transport: transport, store: store)
            let service = GitHubLinksService(client: EdgeFunctionClient(configuration: testConfiguration(), transport: transport, sessions: manager))
            do { _ = try await service.syncIdentity(); XCTFail() }
            catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
            let requests = await transport.recorded()
            XCTAssertEqual(requests.count, changesAccount ? 2 : 3)
            if changesAccount {
                let saved = try await store.load()
                XCTAssertNil(saved, "A refresh for another account must never be installed")
            }
        }
    }

    func testObsoleteAnswersAndUnauthorizedCannotUseANewerBinding() async throws {
        for response in [jsonResponse(#"{"connected":true,"handle":null}"#), edgeFailure("not_authenticated", status: 401)] {
            let transport = StubTransport([.held(response), .response(authResponse())])
            let sessions = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
            let service = GitHubLinksService(client: EdgeFunctionClient(configuration: testConfiguration(), transport: transport, sessions: sessions))
            let call = Task { try await service.syncIdentity() }
            await transport.waitForRequests(1)
            _ = try await sessions.establish(using: AuthRequest(path: "provider/session", body: Data("{}".utf8)))
            await transport.release()
            do { _ = try await call.value; XCTFail() }
            catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
            let requests = await transport.recorded()
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testEveryStableEdgeCodeAndHTTPStatus() async throws {
        let cases: [(String, Int, [String], BackendError)] = [
            ("not_authenticated", 401, [], .notAuthenticated),
            ("account_not_ready", 400, [], .accountNotReady),
            ("declaration_required", 400, [], .declarationRequired),
            ("invalid_input", 400, ["title", "main_language", "private-credential"], .invalidInput(fields: ["title", "main_language"])),
            ("prerequisite_missing", 400, ["github_reader"], .prerequisiteMissing(fields: ["github_reader"])),
            ("not_found", 404, [], .notFound), ("rate_limited", 429, [], .rateLimited)
        ]
        for (code, status, details, expected) in cases {
            let response = edgeFailure(code, details: details, status: status)
            let steps: [StubTransport.Step] = code == "not_authenticated"
                ? [.response(response), .response(authResponse()), .response(response)] : [.response(response)]
            do { _ = try await gitHubService(StubTransport(steps)).syncIdentity(); XCTFail(code) }
            catch { XCTAssertEqual(error as? BackendError, expected, code) }
        }
        for (status, expected) in [(404, BackendError.notFound), (429, .rateLimited),
                                   (400, .httpFailure(statusCode: 400)), (408, .httpFailure(statusCode: 408)),
                                   (500, .httpFailure(statusCode: 500)), (502, .httpFailure(statusCode: 502))] {
            do { _ = try await gitHubService(StubTransport([.response(jsonResponse("secret-body", status: status))])).syncIdentity(); XCTFail() }
            catch { XCTAssertEqual(error as? BackendError, expected) }
        }
        let transport = StubTransport([.response(jsonResponse("malformed", status: 401)),
            .response(authResponse()), .response(jsonResponse("malformed", status: 401))])
        do { _ = try await gitHubService(transport).syncIdentity(); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
    }

    func testContractDetailsAreAcceptedByBothErrorFormats() throws {
        let fields = ["link_id", "link_ids", "title", "description", "main_language", "tags", "opening_text",
                      "visibility", "refresh_confirmation", "method", "body", "action", "page", "repository_id",
                      "repository_name", "replace_existing", "github_reader", "github", "discovery", "code",
                      "favorite", "hour", "minute", "block_id", "reason", "deletion_safety_key", "encounter_id"]
        for code in ["invalid_input", "prerequisite_missing"] {
            let expected: BackendError = code == "invalid_input" ? .invalidInput(fields: fields) : .prerequisiteMissing(fields: fields)
            let rpc = jsonResponse("{\"message\":\"\(code)\",\"details\":\"\(fields.joined(separator: ","))\"}", status: 400)
            XCTAssertEqual(BackendError.response(rpc), expected)
            XCTAssertEqual(BackendError.edgeResponse(edgeFailure(code, details: fields, status: 400)), expected)
        }
    }

    func testMismatchedBackendCannotReceiveSessionCredentials() async throws {
        let transport = StubTransport([])
        let client = EdgeFunctionClient(configuration: BackendConfiguration(address: "https://another-backend.example", publicClientKey: "other-key")!,
            transport: transport, sessions: testManager(transport: transport, store: InMemorySessionStore(session: try testSession())))
        do { let _: RPCResult = try await client.call("github-links", parameters: RPCParameters(display_name: "Name")); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        let requests = await transport.recorded()
        XCTAssertTrue(requests.isEmpty)
    }

    func testInvalidNamesSignedOutMalformedAndTransportFailures() async throws {
        let transport = StubTransport([.failure, .response(jsonResponse("not-json"))])
        let client = EdgeFunctionClient(configuration: testConfiguration(), transport: transport,
            sessions: testManager(transport: transport, store: InMemorySessionStore(session: try testSession())))
        for name in ["", "../github-links", "github-links?secret=value", "a/b", "a%2fb"] {
            do { let _: RPCResult = try await client.call(name, parameters: RPCParameters(display_name: "Name")); XCTFail() }
            catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        }
        let before = await transport.recorded()
        XCTAssertTrue(before.isEmpty)
        for expected in [BackendError.transportFailure, .invalidResponse] {
            do { let _: RPCResult = try await client.call("github-links", parameters: RPCParameters(display_name: "Name")); XCTFail() }
            catch { XCTAssertEqual(error as? BackendError, expected) }
        }
        let emptyTransport = StubTransport([])
        let signedOut = EdgeFunctionClient(configuration: testConfiguration(), transport: emptyTransport,
            sessions: testManager(transport: emptyTransport, store: InMemorySessionStore()))
        do { let _: RPCResult = try await signedOut.call("github-links", parameters: RPCParameters(display_name: "Name")); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        let requests = await emptyTransport.recorded()
        XCTAssertTrue(requests.isEmpty)
    }
}

func edgeFailure(_ code: String, details: [String] = [], status: Int) -> HTTPResponse {
    struct Detail: Encodable { let code: String; let details: [String] }
    struct Failure: Encodable { let error: Detail }
    return HTTPResponse(data: try! JSONEncoder().encode(Failure(error: Detail(code: code, details: details))), statusCode: status)
}
