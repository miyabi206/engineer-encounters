import XCTest
import Foundation
import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport

@MainActor
final class ServerTokenIssuerTests: XCTestCase {
    func testAtLeastOneHourOfContiguousCoverageDoesNothing() async throws {
        for count in [4, 48] {
            let batch = try EncounterSamples.batch(count: count)
            let store = InMemoryTokenBatchStore(batch: batch)
            let transport = StubTransport([])
            let issuer = ServerTokenIssuer(client: try serviceClient(transport), store: store)
            try await issuer.replenish(at: testNow)
            let requests = await transport.recorded()
            let saved = try await store.load()
            XCTAssertTrue(requests.isEmpty)
            XCTAssertEqual(saved, batch)
        }
    }

    func testLessThanOneHourTopsUpAndRemovesExpiredWindowsOnlyAfterSuccess() async throws {
        let stored = try EncounterSamples.batch(start: testNow.addingTimeInterval(-900), count: 5)
        let returned = try EncounterSamples.batch(start: testNow.addingTimeInterval(3600), count: 44)
        let store = InMemoryTokenBatchStore(batch: stored)
        let transport = StubTransport([.response(try batchResponse(returned))])
        let issuer = ServerTokenIssuer(client: try serviceClient(transport), store: store)
        try await issuer.replenish(at: testNow.addingTimeInterval(1))
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.lastPathComponent, "issue_token_batch")
        XCTAssertEqual(try parameters(requests[0].httpBody), ["covered_until": 1_800_003_600])
        let saved = try await store.load()
        XCTAssertEqual(saved?.windows, Array(stored.windows.dropFirst()) + returned.windows)
    }

    func testNoCurrentCoverageOmitsCoveredUntilAndKeepsUnexpiredFutureWindows() async throws {
        let expired = try EncounterSamples.batch(start: testNow.addingTimeInterval(-900), count: 1)
        let future = try EncounterSamples.batch(start: testNow.addingTimeInterval(1800), count: 1)
        let fixtures: [TokenBatch?] = [nil, try TokenBatch(windows: []), expired, future]
        for stored in fixtures {
            let returned = try EncounterSamples.batch(count: 4)
            let store = InMemoryTokenBatchStore(batch: stored)
            let transport = StubTransport([.response(try batchResponse(returned))])
            let issuer = ServerTokenIssuer(client: try serviceClient(transport), store: store)
            try await issuer.replenish(at: testNow)
            let requests = await transport.recorded()
            XCTAssertEqual(try parameters(requests[0].httpBody), [:])
            let saved = try await store.load()
            var expected = returned.windows
            if let stored, stored == future { expected[2] = future.windows[0] }
            XCTAssertEqual(saved?.windows, expected)
        }
    }

    func testCoverageStopsAtFirstGapAndMergePreservesExistingTokens() async throws {
        let current = try EncounterSamples.batch(count: 1)
        let future = try EncounterSamples.batch(start: testNow.addingTimeInterval(1800), count: 8)
        let stored = try TokenBatch(windows: current.windows + future.windows)
        let returned = try EncounterSamples.batch(start: testNow.addingTimeInterval(900), count: 12)
        let transport = StubTransport([.response(try batchResponse(returned))])
        let store = InMemoryTokenBatchStore(batch: stored)
        try await ServerTokenIssuer(client: serviceClient(transport), store: store).replenish(at: testNow)
        let requests = await transport.recorded()
        XCTAssertEqual(try parameters(requests[0].httpBody), ["covered_until": 1_800_000_900])
        let expected = current.windows + [returned.windows[0]] + future.windows + Array(returned.windows.suffix(3))
        let saved = try await store.load()
        XCTAssertEqual(saved?.windows, expected)
    }

    func testFailedCallsNeverChangeStoredBatchAndThrow() async throws {
        let stored = try EncounterSamples.batch(start: testNow.addingTimeInterval(-900), count: 2)
        let cases: [(StubTransport.Step, BackendError)] = [
            (.failure, .transportFailure),
            (.response(jsonResponse(#"{"message":"rate_limited"}"#, status: 429)), .rateLimited),
            (.response(jsonResponse(#"{"message":"account_not_ready"}"#, status: 400)), .accountNotReady),
            (.response(jsonResponse("malformed")), .invalidResponse)
        ]
        for (step, expected) in cases {
            let store = InMemoryTokenBatchStore(batch: stored)
            let issuer = ServerTokenIssuer(client: try serviceClient(StubTransport([step])), store: store)
            do { try await issuer.replenish(at: testNow); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? BackendError, expected) }
            let saved = try await store.load()
            XCTAssertEqual(saved, stored)
        }
    }

    func testInvalidWindowsAndOverlappingMergeLeaveStorageUntouched() async throws {
        let stored = try EncounterSamples.batch(count: 1)
        let validJSON = String(decoding: try JSONEncoder().encode(TokenBatchTransfer(batchID: testUserID, batch: stored)), as: UTF8.self)
        let unaligned = try EncounterSamples.batch(start: testNow.addingTimeInterval(1), count: 1)
        for response in [
            jsonResponse(validJSON.replacingOccurrences(of: "1800000900", with: "1800000899")),
            try batchResponse(unaligned),
            jsonResponse("""
            {"batch_id":"\(testUserID.uuidString)","windows":[
             {"token":"00000000000000000000000000000000","valid_from":1800000000,"valid_until":1800000900},
             {"token":"00000000000000000000000000000000","valid_from":1800000000,"valid_until":1800000900}]}
            """)
        ] {
            let store = InMemoryTokenBatchStore(batch: stored)
            let issuer = ServerTokenIssuer(client: try serviceClient(StubTransport([.response(response)])), store: store)
            do { try await issuer.replenish(at: testNow); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? BackendError, .invalidResponse) }
            let saved = try await store.load()
            XCTAssertEqual(saved, stored)
        }
        let offsetStored = try EncounterSamples.batch(start: testNow.addingTimeInterval(-1), count: 1)
        let store = InMemoryTokenBatchStore(batch: offsetStored)
        let issuer = ServerTokenIssuer(client: try serviceClient(StubTransport([.response(try batchResponse(stored))])), store: store)
        do { try await issuer.replenish(at: testNow); XCTFail("Overlapping merge must fail") }
        catch { XCTAssertEqual(error as? BackendError, .invalidResponse) }
        let saved = try await store.load()
        XCTAssertEqual(saved, offsetStored)
    }

    func testEmptyServerBatchIsValidAndConcurrentTopUpsShareOneCall() async throws {
        let stored = try EncounterSamples.batch(count: 1)
        let store = InMemoryTokenBatchStore(batch: stored)
        let transport = StubTransport([.held(try batchResponse(TokenBatch(windows: [])))])
        let issuer = ServerTokenIssuer(client: try serviceClient(transport), store: store)
        let first = Task { try await issuer.replenish(at: testNow) }
        await transport.waitForRequests(1)
        let second = Task { try await issuer.replenish(at: testNow) }
        // Both callers can enter the actor while the transport is suspended.
        await Task.yield()
        await transport.release()
        try await first.value
        try await second.value
        let saved = try await store.load()
        let requests = await transport.recorded()
        XCTAssertEqual(saved, stored)
        XCTAssertEqual(requests.count, 1)
    }

    func testStoreReadAndWriteErrorsPropagate() async throws {
        for readFails in [true, false] {
            let transport = StubTransport([.response(try batchResponse(EncounterSamples.batch(count: 1)))])
            let store = FailingBatchStore(readFails: readFails)
            let issuer = ServerTokenIssuer(client: try serviceClient(transport), store: store)
            do { try await issuer.replenish(at: testNow); XCTFail("Must propagate store error") }
            catch { XCTAssertEqual(error as? BackendError, .storageFailure) }
            let requests = await transport.recorded()
            XCTAssertEqual(requests.count, readFails ? 0 : 1)
        }
    }

    private func batchResponse(_ batch: TokenBatch) throws -> HTTPResponse {
        HTTPResponse(data: try JSONEncoder().encode(TokenBatchTransfer(batchID: testUserID, batch: batch)), statusCode: 200)
    }

    private func parameters(_ data: Data?) throws -> [String: Int] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Int])
    }
}

private actor FailingBatchStore: TokenBatchStore {
    let readFails: Bool
    init(readFails: Bool) { self.readFails = readFails }
    func load() async throws -> TokenBatch? {
        if readFails { throw BackendError.storageFailure }
        return nil
    }
    func save(_ batch: TokenBatch) async throws { throw BackendError.storageFailure }
    func clear() async throws {}
}
