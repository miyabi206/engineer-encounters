import XCTest
import Foundation
@testable import EncounterBackend

@MainActor
final class Unit4ErrorTests: XCTestCase {
    func testEveryListedProcedureErrorAndDetailPreservesCredentials() async throws {
        for procedure in Unit4Procedure.allCases {
            var failures: [(String, [String], BackendError)] = []
            if procedure.requiresReady { failures.append(("account_not_ready", [], .accountNotReady)) }
            if procedure.requiresDiscovery {
                failures.append(("prerequisite_missing", ["discovery"], .prerequisiteMissing(fields: ["discovery"])))
            }
            if procedure.canRateLimit { failures.append(("rate_limited", [], .rateLimited)) }
            if procedure.canBeNotFound { failures.append(("not_found", [], .notFound)) }
            if !procedure.parameterFields.isEmpty {
                // Signature order and each independently failing parameter both survive sanitization.
                for fields in [procedure.parameterFields] + procedure.parameterFields.map({ [$0] }) {
                    failures.append(("invalid_input", fields, .invalidInput(fields: fields)))
                }
            }
            if procedure == .deleteOwnAccount {
                failures.append(("prerequisite_missing", ["deletion_safety_key"],
                                 .prerequisiteMissing(fields: ["deletion_safety_key"])))
            }
            for (code, fields, expected) in failures {
                let detail = fields.isEmpty ? "null" : "\" \(fields.joined(separator: ", ")) ,untrusted-server-material\""
                let transport = StubTransport([.response(jsonResponse(
                    "{\"code\":\"P0001\",\"message\":\"\(code)\",\"details\":\(detail)}", status: 400))])
                let original = try testSession()
                let store = InMemorySessionStore(session: original)
                let sessions = testManager(transport: transport, store: store)
                let client = RemoteProcedureClient(configuration: testConfiguration(), transport: transport, sessions: sessions)
                do { try await procedure.invoke(client); XCTFail(procedure.rawValue + ": " + code) }
                catch { XCTAssertEqual(error as? BackendError, expected, procedure.rawValue) }
                let retained = try await store.load()
                XCTAssertEqual(retained, original)
                let requests = await transport.recorded()
                XCTAssertEqual(requests.count, 1)
            }
        }
    }

    func testEveryProcedureAuthLossUsesExistingRefreshAndSignsOutOnDeadCredentials() async throws {
        for procedure in Unit4Procedure.allCases {
            let transport = StubTransport([
                .response(jsonResponse(#"{"message":"not_authenticated","details":null}"#, status: 400)),
                .response(jsonResponse(#"{"error":"invalid_grant"}"#, status: 400))
            ])
            let store = InMemorySessionStore(session: try testSession())
            let sessions = testManager(transport: transport, store: store)
            let client = RemoteProcedureClient(configuration: testConfiguration(), transport: transport, sessions: sessions)
            do { try await procedure.invoke(client); XCTFail(procedure.rawValue) }
            catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
            let cleared = try await store.load()
            XCTAssertNil(cleared)
            let requests = await transport.recorded()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[1].url?.path, "/base/auth/v1/token")
        }
    }

    func testEveryProcedureRetriesUnauthorizedWithSameParametersAfterRefresh() async throws {
        for procedure in Unit4Procedure.allCases {
            let transport = StubTransport([
                .response(jsonResponse(#"{"message":"not_authenticated"}"#, status: 401)),
                .response(authResponse()), .response(jsonResponse(procedure.responseJSON))
            ])
            try await procedure.invoke(serviceClient(transport))
            let requests = await transport.recorded()
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(requests[2].url, requests[0].url)
            XCTAssertEqual(requests[2].httpBody, requests[0].httpBody)
            XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        }
    }

    func testEveryProcedureRejectsObsoleteResponsesAfterSignOutOrAccountReplacement() async throws {
        for procedure in Unit4Procedure.allCases {
            for replacement in [false, true] {
                let transport = StubTransport([.held(jsonResponse(procedure.responseJSON)),
                    .response(authResponse(userID: unit4ID))])
                let sessions = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
                let client = RemoteProcedureClient(configuration: testConfiguration(), transport: transport, sessions: sessions)
                let call = Task { try await procedure.invoke(client) }
                await transport.waitForRequests(1)
                if replacement {
                    _ = try await sessions.establish(using: AuthRequest(path: "provider/session", body: Data("{}".utf8)))
                } else { try await sessions.clear() }
                await transport.release()
                do { try await call.value; XCTFail(procedure.rawValue) }
                catch { XCTAssertEqual(error as? BackendError, .notAuthenticated) }
            }
        }
    }

    func testEveryProcedureTransportAndMalformedSuccessFailuresPreserveCredentials() async throws {
        for procedure in Unit4Procedure.allCases {
            for (step, expected) in [(StubTransport.Step.failure, BackendError.transportFailure),
                                     (.response(jsonResponse("{}")), .invalidResponse)] {
                let transport = StubTransport([step])
                let original = try testSession()
                let store = InMemorySessionStore(session: original)
                let client = RemoteProcedureClient(configuration: testConfiguration(), transport: transport,
                                                  sessions: testManager(transport: transport, store: store))
                do { try await procedure.invoke(client); XCTFail(procedure.rawValue) }
                catch { XCTAssertEqual(error as? BackendError, expected) }
                let retained = try await store.load()
                XCTAssertEqual(retained, original)
            }
        }
    }
}
