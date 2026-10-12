import XCTest
import Foundation
import CryptoKit
import EncounterBackend

private let authorizationURL = "https://github.com/login/oauth/authorize?state=oauth-state"
private let validCallback = URL(string: "engineer-encounters://auth/github?code=auth-code")!
private let otherAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

@MainActor
final class GitHubLinkSessionTests: XCTestCase {
    func testAuthorizationAndPKCEExchangeExactRequestsAndSameAccountInstall() async throws {
        let authJSON = """
        {"access_token":"linked-access","refresh_token":"linked-refresh","token_type":"bearer",
         "expires_in":3600,"user":{"id":"\(testUserID.uuidString)"},
         "provider_token":"never-keep-github-access","provider_refresh_token":"never-keep-github-refresh"}
        """
        let transport = StubTransport([.response(authorizeResponse()), .response(jsonResponse(authJSON))])
        let store = InMemorySessionStore(session: try testSession())
        let manager = testManager(transport: transport, store: store)
        let url = try await manager.beginGitHubLink()
        XCTAssertEqual(url.absoluteString, authorizationURL)
        let before = try await manager.session()
        XCTAssertEqual(before, try testSession())
        let result = try await manager.completeGitHubLink(from: validCallback)
        XCTAssertEqual(result.accessCredential, "linked-access")
        let current = try await manager.session()
        let saved = try await store.load()
        XCTAssertEqual(current, result)
        XCTAssertEqual(saved, result)
        XCTAssertFalse(String(reflecting: result).contains("github-access"))
        XCTAssertTrue(Mirror(reflecting: manager).children.isEmpty)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 2)
        let first = requests[0]
        XCTAssertEqual(first.url?.path, "/base/auth/v1/user/identities/authorize")
        XCTAssertEqual(first.httpMethod, "GET")
        XCTAssertEqual(first.httpBody, Data())
        XCTAssertEqual(first.value(forHTTPHeaderField: "apikey"), "public-key")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(first.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Set(query.map(\.name)), ["provider", "redirect_to", "code_challenge", "code_challenge_method", "skip_http_redirect"])
        XCTAssertEqual(query.first { $0.name == "provider" }?.value, "github")
        XCTAssertEqual(query.first { $0.name == "redirect_to" }?.value, "engineer-encounters://auth/github")
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "s256")
        XCTAssertEqual(query.first { $0.name == "skip_http_redirect" }?.value, "true")
        let second = requests[1]
        XCTAssertEqual(second.url?.absoluteString, "https://backend.example/base/auth/v1/token?grant_type=pkce")
        XCTAssertEqual(second.httpMethod, "POST")
        XCTAssertEqual(second.value(forHTTPHeaderField: "apikey"), "public-key")
        XCTAssertNil(second.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(second.httpBody)) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["auth_code", "code_verifier"])
        XCTAssertEqual(body["auth_code"], "auth-code")
        let verifier = try XCTUnwrap(body["code_verifier"])
        XCTAssertEqual(verifier.utf8.count, 43)
        XCTAssertTrue(verifier.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value, challenge)
        let refusesRedirects = await transport.redirectRefusalCount()
        XCTAssertEqual(refusesRedirects, 1)
        do { _ = try await manager.completeGitHubLink(from: validCallback); XCTFail("Attempt must be consumed") }
        catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        let after = await transport.recorded()
        XCTAssertEqual(after.count, 2)
    }

    func testCallbackAddressCodeAndReturnedStateValidationConsumesAttempt() async throws {
        let rejected = [
            "other://auth/github?code=auth-code", "engineer-encounters://other/github?code=auth-code",
            "engineer-encounters://auth/other?code=auth-code", "engineer-encounters://auth/github/?code=auth-code",
            "engineer-encounters://auth/%67ithub?code=auth-code", "engineer-encounters://auth:443/github?code=auth-code",
            "engineer-encounters://user@auth/github?code=auth-code", "engineer-encounters://auth/github?code=auth-code#fragment",
            "engineer-encounters://auth/github", "engineer-encounters://auth/github?code=",
            "engineer-encounters://auth/github?code=one&code=two", "engineer-encounters://auth/github?error=access_denied",
            "engineer-encounters://auth/github?code=auth-code&state=wrong",
            "engineer-encounters://auth/github?code=auth-code&state=oauth-state&state=oauth-state"
        ]
        for callback in rejected {
            let original = try testSession()
            let store = InMemorySessionStore(session: original)
            let transport = StubTransport([.response(authorizeResponse())])
            let manager = testManager(transport: transport, store: store)
            _ = try await manager.beginGitHubLink()
            do { _ = try await manager.completeGitHubLink(from: XCTUnwrap(URL(string: callback))); XCTFail(callback) }
            catch { XCTAssertEqual(error as? BackendError, .invalidRequest, callback) }
            do { _ = try await manager.completeGitHubLink(from: validCallback); XCTFail("Rejected callback consumes pending verifier") }
            catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
            let saved = try await store.load()
            let current = try await manager.session()
            XCTAssertEqual(saved, original)
            XCTAssertEqual(current, original)
            let requests = await transport.recorded()
            XCTAssertEqual(requests.count, 1)
        }
        let transport = StubTransport([.response(authorizeResponse()), .response(authResponse())])
        let manager = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
        _ = try await manager.beginGitHubLink()
        _ = try await manager.completeGitHubLink(from: URL(string: validCallback.absoluteString + "&state=oauth-state")!)
    }

    func testCodeOnlyFlowAndUnexpectedStateWithoutExpectedState() async throws {
        for includesState in [false, true] {
            let transport = StubTransport([.response(authorizeResponse(url: "https://github.com/login/oauth/authorize")),
                                           .response(authResponse())])
            let manager = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
            _ = try await manager.beginGitHubLink()
            let callback = includesState ? URL(string: validCallback.absoluteString + "&state=unknown")! : validCallback
            do { _ = try await manager.completeGitHubLink(from: callback); XCTAssertFalse(includesState) }
            catch { XCTAssertTrue(includesState); XCTAssertEqual(error as? BackendError, .invalidRequest) }
        }
    }

    func testDifferentAccountResultIsDiscardedWithoutTouchingInitiatingSession() async throws {
        let original = try testSession()
        let store = InMemorySessionStore(session: original)
        let transport = StubTransport([.response(authorizeResponse()), .response(authResponse(userID: otherAccountID))])
        let manager = testManager(transport: transport, store: store)
        _ = try await manager.beginGitHubLink()
        do { _ = try await manager.completeGitHubLink(from: validCallback); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .invalidResponse) }
        let saved = try await store.load()
        let current = try await manager.session()
        XCTAssertEqual(saved, original)
        XCTAssertEqual(current, original)
    }

    func testSignOutAndAccountEstablishmentInvalidatePendingCallback() async throws {
        for signsOut in [true, false] {
            let store = InMemorySessionStore(session: try testSession())
            let transport = StubTransport([.response(authorizeResponse()), .response(authResponse(userID: otherAccountID))])
            let manager = testManager(transport: transport, store: store)
            _ = try await manager.beginGitHubLink()
            if signsOut { try await manager.clear() }
            else { _ = try await manager.establish(using: AuthRequest(path: "provider/session", body: Data("{}".utf8))) }
            do { _ = try await manager.completeGitHubLink(from: validCallback); XCTFail() }
            catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
            let requests = await transport.recorded()
            XCTAssertEqual(requests.count, signsOut ? 1 : 2)
            let saved = try await store.load()
            XCTAssertEqual(saved?.userID, signsOut ? nil : otherAccountID)
        }
    }

    func testOneAttemptBelongsToOneManagerAndFreshVerifierAfterCancellation() async throws {
        let transport = StubTransport([.response(authorizeResponse()), .response(authorizeResponse())])
        let original = try testSession()
        let store = InMemorySessionStore(session: original)
        let manager = testManager(transport: transport, store: store)
        _ = try await manager.beginGitHubLink()
        let unrelated = testManager(transport: transport, store: store)
        do { _ = try await unrelated.completeGitHubLink(from: validCallback); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        do { _ = try await manager.beginGitHubLink(); XCTFail("Only one pending attempt") }
        catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        await manager.cancelGitHubLink()
        do { _ = try await manager.completeGitHubLink(from: validCallback); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        let current = try await manager.session()
        XCTAssertEqual(current, original)
        _ = try await manager.beginGitHubLink()
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 2)
        func challenge(_ request: URLRequest) -> String? {
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code_challenge" }?.value
        }
        XCTAssertNotEqual(challenge(requests[0]), challenge(requests[1]))
    }

    func testAuthorizationAndExchangeFailuresLeaveOriginalSession() async throws {
        for duringExchange in [false, true] {
            for step in [StubTransport.Step.failure, .response(jsonResponse("malformed")),
                         .response(jsonResponse("{}", status: 400)), .response(jsonResponse("{}", status: 401)),
                         .response(jsonResponse("{}", status: 302))] {
                var steps: [StubTransport.Step] = []
                if duringExchange { steps.append(.response(authorizeResponse())) }
                steps.append(step)
                let original = try testSession()
                let store = InMemorySessionStore(session: original)
                let manager = testManager(transport: StubTransport(steps), store: store)
                do {
                    _ = try await manager.beginGitHubLink()
                    if duringExchange { _ = try await manager.completeGitHubLink(from: validCallback) }
                    XCTFail()
                } catch { XCTAssertNotNil(error as? BackendError) }
                let saved = try await store.load()
                let current = try await manager.session()
                XCTAssertEqual(saved, original)
                XCTAssertEqual(current, original)
            }
        }
    }

    func testInFlightBeginAndExchangeAreFencedByCancellationSignOutAndNewSessions() async throws {
        for duringExchange in [false, true] {
            for invalidation in ["cancel", "task-cancel", "sign-out", "establish"] {
                var steps: [StubTransport.Step] = []
                if duringExchange { steps.append(.response(authorizeResponse())) }
                steps.append(.held(duringExchange ? authResponse() : authorizeResponse()))
                if invalidation == "establish" { steps.append(.response(authResponse(access: "replacement", userID: otherAccountID))) }
                let original = try testSession()
                let store = InMemorySessionStore(session: original)
                let transport = StubTransport(steps)
                let manager = testManager(transport: transport, store: store)
                if duringExchange { _ = try await manager.beginGitHubLink() }
                let operation = Task {
                    if duringExchange { _ = try await manager.completeGitHubLink(from: validCallback) }
                    else { _ = try await manager.beginGitHubLink() }
                }
                await transport.waitForRequests(duringExchange ? 2 : 1)
                switch invalidation {
                case "cancel": await manager.cancelGitHubLink()
                case "task-cancel": operation.cancel()
                case "sign-out": try await manager.clear()
                default: _ = try await manager.establish(using: AuthRequest(path: "provider/session", body: Data("{}".utf8)))
                }
                await transport.release()
                do { try await operation.value; XCTFail("Obsolete linking response must fail") }
                catch {
                    if invalidation == "task-cancel" { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertNotNil(error as? BackendError) }
                }
                let saved = try await store.load()
                if invalidation == "sign-out" { XCTAssertNil(saved) }
                else if invalidation == "establish" { XCTAssertEqual(saved?.accessCredential, "replacement") }
                else { XCTAssertEqual(saved, original) }
            }
        }
    }

    func testSuccessfulExchangeSupersedesAnOlderRefresh() async throws {
        for oldResponse in [authResponse(access: "obsolete"), jsonResponse(#"{"error":"invalid_grant"}"#, status: 400)] {
            let transport = StubTransport([.response(authorizeResponse()), .held(oldResponse),
                                           .response(authResponse(access: "linked"))])
            let store = InMemorySessionStore(session: try testSession())
            let manager = testManager(transport: transport, store: store)
            _ = try await manager.beginGitHubLink()
            let refreshing = Task { try await manager.refresh() }
            await transport.waitForRequests(2)
            let linked = try await manager.completeGitHubLink(from: validCallback)
            await transport.release()
            let refreshed = try await refreshing.value
            XCTAssertEqual(refreshed, linked)
            let saved = try await store.load()
            let current = try await manager.session()
            XCTAssertEqual(saved, linked)
            XCTAssertEqual(current, linked)
        }
    }

    func testAccountRequestsHeldAcrossLinkExchangeRemainAuthorized() async throws {
        for edge in [false, true] {
            let transport = StubTransport([.response(authorizeResponse()), .held(jsonResponse(#"{"saved":true}"#)),
                                           .response(authResponse(access: "linked"))])
            let manager = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
            _ = try await manager.beginGitHubLink()
            let request = Task { () throws -> RPCResult in
                if edge {
                    return try await EdgeFunctionClient(configuration: testConfiguration(), transport: transport, sessions: manager)
                        .call("github-links", parameters: RPCParameters(display_name: "Name"))
                }
                return try await RemoteProcedureClient(configuration: testConfiguration(), transport: transport, sessions: manager)
                    .call("get_own_profile", parameters: RPCParameters(display_name: "Name"))
            }
            await transport.waitForRequests(2)
            _ = try await manager.completeGitHubLink(from: validCallback)
            await transport.release()
            let result = try await request.value
            XCTAssertTrue(result.saved)
        }
    }

    func testUnlinkUsesCurrentUserGitHubIdentityAndRetainsCredentials() async throws {
        let identity = "00000000-0000-0000-0000-000000000123"
        let user = jsonResponse("""
        {"id":"\(testUserID.uuidString)","identities":[
          {"identity_id":"00000000-0000-0000-0000-000000000124","provider":"apple"},
          {"identity_id":"\(identity)","provider":"github"}]}
        """)
        for deletion in [jsonResponse("{}", status: 204),
                         jsonResponse(#"{"code":"single_identity_not_deletable"}"#, status: 422),
                         jsonResponse(#"{"code":"unexpected"}"#, status: 500),
                         jsonResponse(#"{"code":"bad_jwt"}"#, status: 401)] {
            let original = try testSession()
            let store = InMemorySessionStore(session: original)
            let transport = StubTransport([.response(user), .response(deletion)])
            let manager = testManager(transport: transport, store: store)
            do {
                let outcome = try await manager.unlinkGitHubIdentity()
                XCTAssertEqual(outcome, deletion.statusCode == 204 ? .unlinked : .lastIdentityRetained)
                XCTAssertTrue([204, 422].contains(deletion.statusCode))
            } catch {
                XCTAssertEqual(error as? BackendError, deletion.statusCode == 401 ? .notAuthenticated : .httpFailure(statusCode: 500))
            }
            let requests = await transport.recorded()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "DELETE"])
            XCTAssertEqual(requests[0].url?.path, "/base/auth/v1/user")
            XCTAssertEqual(requests[1].url?.path, "/base/auth/v1/user/identities/" + identity)
            XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
            let saved = try await store.load()
            let current = try await manager.session()
            XCTAssertEqual(saved, original)
            XCTAssertEqual(current, original)
        }
        let transport = StubTransport([.response(jsonResponse("{\"id\":\"\(testUserID.uuidString)\",\"identities\":[]}"))])
        let manager = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
        let outcome = try await manager.unlinkGitHubIdentity()
        XCTAssertEqual(outcome, .notLinked)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testSecondCallbackWhileFirstExchangeIsPendingSendsNoRequest() async throws {
        let transport = StubTransport([.response(authorizeResponse()), .held(authResponse())])
        let manager = testManager(transport: transport, store: InMemorySessionStore(session: try testSession()))
        _ = try await manager.beginGitHubLink()
        let first = Task { try await manager.completeGitHubLink(from: validCallback) }
        await transport.waitForRequests(2)
        do { _ = try await manager.completeGitHubLink(from: validCallback); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .invalidRequest) }
        await transport.release()
        _ = try await first.value
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 2)
    }
}

private func authorizeResponse(url: String = authorizationURL) -> HTTPResponse {
    jsonResponse("{\"url\":\"\(url)\"}")
}
