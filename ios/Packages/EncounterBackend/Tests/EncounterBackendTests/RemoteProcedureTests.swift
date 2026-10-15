import XCTest
import Foundation
import EncounterBackend

@MainActor
final class RemoteProcedureTests: XCTestCase {
    func testExactRemoteProcedureRequest() async throws {
        let transport = StubTransport([.response(jsonResponse(#"{"saved":true}"#))])
        let sessions = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
        let client = RemoteProcedureClient(configuration: testConfiguration(), transport: transport, sessions: sessions)
        let result: RPCResult = try await client.call("update_own_profile", parameters: RPCParameters(display_name: "Name"))
        XCTAssertEqual(result, RPCResult(saved: true))
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://backend.example/base/rest/v1/rpc/update_own_profile")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["display_name": "Name"])
    }

    func testUnauthorizedRefreshesAndRetriesIdenticalProcedureOnce() async throws {
        let transport = StubTransport([
            .response(jsonResponse(#"{"message":"expired credential"}"#, status: 401)),
            .response(authResponse()), .response(jsonResponse(#"{"saved":true}"#))
        ])
        let client = try makeClient(transport)
        let result: RPCResult = try await client.call("update_own_profile", parameters: RPCParameters(display_name: "Name"))
        XCTAssertTrue(result.saved)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].url?.path, "/base/auth/v1/token")
        XCTAssertEqual(requests[0].url, requests[2].url)
        XCTAssertEqual(requests[0].httpMethod, requests[2].httpMethod)
        XCTAssertEqual(requests[0].httpBody, requests[2].httpBody)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
    }

    func testSecondUnauthorizedIsNotRetried() async throws {
        let unauthorized = jsonResponse(#"{"message":"not_authenticated"}"#, status: 401)
        let transport = StubTransport([.response(unauthorized), .response(authResponse()), .response(unauthorized)])
        let client = try makeClient(transport)
        do { try await client.call("procedure", parameters: RPCParameters(display_name: "Name")); XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 3)
    }

    func testUnauthorizedIsNotRetriedWithAnotherAccountsRefreshedSession() async throws {
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let transport = StubTransport([
            .response(jsonResponse("{}", status: 401)), .response(authResponse(userID: otherID))
        ])
        let client = try makeClient(transport)
        do { try await client.call("procedure", parameters: RPCParameters(display_name: "Name")); XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 2)
    }

    func testUnauthorizedCannotReplayUnderAnInterleavedEstablishedAccount() async throws {
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let transport = StubTransport([.held(jsonResponse("{}", status: 401)), .response(authResponse(userID: otherID))])
        let manager = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
        let client = RemoteProcedureClient(configuration: testConfiguration(), transport: transport, sessions: manager)
        let rpc = Task { try await client.call("procedure", parameters: RPCParameters(display_name: "Name")) }
        await transport.waitForRequests(1)
        _ = try await manager.establish(using: AuthRequest(path: "provider/session", body: Data("{}".utf8)))
        await transport.release()
        do { try await rpc.value; XCTFail("Must not retry under another account") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 2)
    }

    func testObsoleteSuccessIsDiscardedAfterSignOutOrSessionReplacement() async throws {
        for signsOut in [true, false] {
            let transport = StubTransport([.held(jsonResponse(#"{"saved":true}"#)), .response(authResponse())])
            let manager = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
            let client = RemoteProcedureClient(configuration: testConfiguration(), transport: transport, sessions: manager)
            let call = Task { try await client.call("update_own_profile", parameters: RPCParameters(display_name: "Name"), as: RPCResult.self) }
            await transport.waitForRequests(1)
            if signsOut { try await manager.clear() }
            else { _ = try await manager.establish(using: AuthRequest(path: "provider/session", body: Data("{}".utf8))) }
            await transport.release()
            do { _ = try await call.value; XCTFail("Obsolete response must be discarded") }
            catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        }
    }

    func testEveryContractCodeAndFieldDetails() async throws {
        let mappings: [(String, BackendError)] = [
            ("not_authenticated", .notAuthenticated), ("account_not_ready", .accountNotReady),
            ("declaration_required", .declarationRequired),
            ("invalid_input", .invalidInput(fields: ["display_name", "introduction", "interest"])),
            ("prerequisite_missing", .prerequisiteMissing(fields: ["display_name", "introduction", "interest"])),
            ("rate_limited", .rateLimited), ("not_found", .notFound)
        ]
        for (code, expected) in mappings {
            let failure = jsonResponse("""
            {"code":"P0001","message":"\(code)","details":" display_name, introduction,, interest "}
            """, status: 400)
            let steps: [StubTransport.Step] = code == "not_authenticated"
                ? [.response(failure), .response(authResponse()), .response(failure)] : [.response(failure)]
            let transport = StubTransport(steps)
            let client = try makeClient(transport)
            do { try await client.call("procedure", parameters: RPCParameters(display_name: "Name")); XCTFail(code) }
            catch { XCTAssertEqual(error as? BackendError, expected, code) }
        }
    }

    func testErrorsNeverRetainUnknownResponseOrTransportMaterial() async throws {
        let failures: [(StubTransport.Step, BackendError)] = [
            (.response(jsonResponse(#"{"message":"secret-token-value","details":"secret-refresh-value"}"#, status: 500)), .httpFailure(statusCode: 500)),
            (.response(jsonResponse("secret-response-body", status: 502)), .httpFailure(statusCode: 502)),
            (.response(jsonResponse(#"{"message":"invalid_input","details":"display_name, 0123456789abcdef0123456789abcdef, credential-secret"}"#, status: 400)), .invalidInput(fields: ["display_name"])),
            (.response(jsonResponse(#"{"message":"prerequisite_missing"}"#, status: 400)), .prerequisiteMissing(fields: [])),
            (.failure, .transportFailure)
        ]
        for (step, expected) in failures {
            let client = try makeClient(StubTransport([step]))
            do { try await client.call("procedure", parameters: RPCParameters(display_name: "Name")); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? BackendError, expected) }
        }
    }

    func testMalformedResponseAndInvalidFunctionName() async throws {
        let transport = StubTransport([.response(jsonResponse("sensitive-malformed-json"))])
        let client = try makeClient(transport)
        for name in ["", "../procedure", "procedure?credential=secret", "a/b", "a%2fb"] {
            do { try await client.call(name, parameters: RPCParameters(display_name: "Name")); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        }
        let before = await transport.recorded()
        XCTAssertTrue(before.isEmpty)
        do {
            let _: RPCResult = try await client.call("procedure", parameters: RPCParameters(display_name: "Name"))
            XCTFail("Malformed response must fail")
        } catch { XCTAssertEqual(error as? BackendError, .invalidResponse) }
    }

    func testSignedOutCallSendsNoRequestAndVoidCallAcceptsEmptyBody() async throws {
        let transport = StubTransport([.response(jsonResponse("", status: 204))])
        let sessions = testManager(transport: transport, store: InMemorySessionStore())
        let signedOut = RemoteProcedureClient(configuration: testConfiguration(), transport: transport, sessions: sessions)
        do { try await signedOut.call("procedure", parameters: RPCParameters(display_name: "Name")); XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
        let before = await transport.recorded()
        XCTAssertTrue(before.isEmpty)
        try await makeClient(transport).call("procedure", parameters: RPCParameters(display_name: "Name"))
        let after = await transport.recorded()
        XCTAssertEqual(after.count, 1)
    }

    private func makeClient(_ transport: StubTransport) throws -> RemoteProcedureClient {
        let sessions = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
        return RemoteProcedureClient(configuration: testConfiguration(), transport: transport, sessions: sessions)
    }
}
