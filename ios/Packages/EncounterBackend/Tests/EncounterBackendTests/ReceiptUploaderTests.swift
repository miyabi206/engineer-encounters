import XCTest
import Foundation
import EncounterBackend
import EncounterDomain
import EncounterDomainTestSupport

@MainActor
final class ReceiptUploaderTests: XCTestCase {
    func testOnlyFinalUnexpiredReceiptsInQueueOrderWithFiftyPerCall() async throws {
        let queue = InMemoryReceiptQueue(wallTime: { testNow })
        let nonfinal = EncounterSamples.receipt(1)
        let expired = finalReceipt(2, observedAt: testNow.addingTimeInterval(-EncounterProtocol.receiptLifetime))
        try await queue.enqueue(nonfinal)
        try await queue.enqueue(expired)
        let finals = (3...62).map { finalReceipt($0) }
        for receipt in finals { try await queue.enqueue(receipt) }
        let before = try await queue.pending()
        let transport = StubTransport([.response(jsonResponse("[]"))])
        let uploader = try makeUploader(transport, queue: queue)
        let outcome = try await uploader.upload(at: testNow)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.lastPathComponent, "submit_receipts")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["receipts"])
        let rows = try XCTUnwrap(root["receipts"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 50)
        XCTAssertEqual(rows.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) },
                       Array(finals.prefix(50)).map(\.id))
        XCTAssertTrue(rows.allSatisfy { $0["is_final_evidence"] as? Bool == true })
        let after = try await queue.pending()
        XCTAssertEqual(after, before)
        XCTAssertEqual(outcome.settledCount, 0)
        XCTAssertEqual(outcome.nextAttemptAt, testNow.addingTimeInterval(5))
        XCTAssertNil(outcome.error)
    }

    func testCandidateUpdatesAndEveryTerminalStatusAcknowledgesWhileMissingAnswersRemain() async throws {
        let queue = InMemoryReceiptQueue(wallTime: { testNow })
        let receipts = (1...6).map { finalReceipt($0) }
        for receipt in receipts { try await queue.enqueue(receipt) }
        let statuses: [ReceiptStatusTransfer] = [
            .init(id: receipts[0].id, status: .candidate), .init(id: receipts[1].id, status: .resolved),
            .init(id: receipts[2].id, status: .consumed), .init(id: receipts[3].id, status: .rejected),
            .init(id: receipts[4].id, status: .expired), .init(id: UUID(), status: .resolved)
        ]
        let transport = StubTransport([.response(try statusResponse(statuses.reversed()))])
        let outcome = try await makeUploader(transport, queue: queue).upload(at: testNow)
        let pending = try await queue.pending()
        var candidate = receipts[0]
        candidate.uploadStatus = .acceptedAsCandidate
        XCTAssertEqual(pending, [candidate, receipts[5]])
        XCTAssertEqual(outcome.settledCount, 4)
        XCTAssertEqual(outcome.nextAttemptAt, testNow.addingTimeInterval(5))
        XCTAssertNil(outcome.error)
    }

    func testAcceptedCandidateIsResubmittedAndBackoffGrowsUntilTerminalProgress() async throws {
        let queue = InMemoryReceiptQueue(wallTime: { testNow })
        var receipt = finalReceipt(1)
        receipt.uploadStatus = .acceptedAsCandidate
        let other = finalReceipt(2)
        try await queue.enqueue(receipt)
        try await queue.enqueue(other)
        let candidate = try statusResponse([.init(id: receipt.id, status: .candidate)])
        let terminal = try statusResponse([.init(id: receipt.id, status: .resolved)])
        let transport = StubTransport([.response(candidate), .response(candidate), .response(candidate), .response(terminal)])
        let uploader = try makeUploader(transport, queue: queue)
        for delay in [5.0, 10, 20] {
            let outcome = try await uploader.upload(at: testNow)
            XCTAssertEqual(outcome.settledCount, 0)
            XCTAssertEqual(outcome.nextAttemptAt, testNow.addingTimeInterval(delay))
        }
        let progressed = try await uploader.upload(at: testNow)
        XCTAssertEqual(progressed.settledCount, 1)
        XCTAssertEqual(progressed.nextAttemptAt, testNow.addingTimeInterval(5))
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [other])
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 4)
        let bodies = try requests.prefix(3).map {
            try JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? NSDictionary
        }
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(bodies[1], bodies[2])
    }

    func testFirstCandidateAcceptanceResetsAfterFailuresButRepeatedCandidatesDoNot() async throws {
        let queue = InMemoryReceiptQueue(wallTime: { testNow })
        let receipt = finalReceipt(1)
        try await queue.enqueue(receipt)
        let candidate = try statusResponse([.init(id: receipt.id, status: .candidate)])
        let transport = StubTransport([.failure, .failure, .response(candidate), .response(candidate)])
        let uploader = try makeUploader(transport, queue: queue)
        for delay in [5.0, 10, 5, 10] {
            let outcome = try await uploader.upload(at: testNow)
            XCTAssertEqual(outcome.nextAttemptAt, testNow.addingTimeInterval(delay))
            XCTAssertEqual(outcome.settledCount, 0)
        }
    }

    func testRateLimitAndTransportFailureLeaveEntireQueueUnchanged() async throws {
        let queue = InMemoryReceiptQueue(wallTime: { testNow })
        let expired = finalReceipt(1, observedAt: testNow.addingTimeInterval(-EncounterProtocol.receiptLifetime - 1))
        var candidate = finalReceipt(2)
        candidate.uploadStatus = .acceptedAsCandidate
        for receipt in [expired, candidate, finalReceipt(3), EncounterSamples.receipt(4)] {
            try await queue.enqueue(receipt)
        }
        let before = try await queue.pending()
        let transport = StubTransport([
            .response(jsonResponse(#"{"message":"rate_limited"}"#, status: 429)), .failure
        ])
        let uploader = try makeUploader(transport, queue: queue)
        for (expected, delay) in [(BackendError.rateLimited, 5.0), (.transportFailure, 10)] {
            let outcome = try await uploader.upload(at: testNow)
            XCTAssertEqual(outcome.error, expected)
            XCTAssertEqual(outcome.settledCount, 0)
            XCTAssertEqual(outcome.nextAttemptAt, testNow.addingTimeInterval(delay))
            let pending = try await queue.pending()
            XCTAssertEqual(pending, before)
        }
    }

    func testEmptyOrIneligibleQueueSendsNothingAndResetsSchedule() async throws {
        let queue = InMemoryReceiptQueue(wallTime: { testNow })
        let transport = StubTransport([.failure, .failure])
        let uploader = try makeUploader(transport, queue: queue)
        let empty = try await uploader.upload(at: testNow)
        XCTAssertEqual(empty.settledCount, 0)
        XCTAssertNil(empty.nextAttemptAt)
        let receipt = finalReceipt(1)
        try await queue.enqueue(receipt)
        _ = try await uploader.upload(at: testNow)
        try await queue.acknowledge(receipt.id)
        try await queue.enqueue(EncounterSamples.receipt(2))
        try await queue.enqueue(finalReceipt(3, observedAt: testNow.addingTimeInterval(-EncounterProtocol.receiptLifetime)))
        let ineligible = try await uploader.upload(at: testNow)
        XCTAssertNil(ineligible.nextAttemptAt)
        try await queue.enqueue(finalReceipt(4))
        let restarted = try await uploader.upload(at: testNow)
        XCTAssertEqual(restarted.nextAttemptAt, testNow.addingTimeInterval(5))
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 2)
    }

    func testSettlingLastReceiptReturnsNoNextAttempt() async throws {
        let queue = InMemoryReceiptQueue(wallTime: { testNow })
        let receipt = finalReceipt(1)
        try await queue.enqueue(receipt)
        let transport = StubTransport([.response(try statusResponse([.init(id: receipt.id, status: .resolved)]))])
        let outcome = try await makeUploader(transport, queue: queue).upload(at: testNow)
        XCTAssertEqual(outcome.settledCount, 1)
        XCTAssertNil(outcome.nextAttemptAt)
        let pending = try await queue.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCandidatePreservesEngineChangesMadeWhileUploadIsInFlight() async throws {
        let queue = InMemoryReceiptQueue(wallTime: { testNow })
        var receipt = finalReceipt(1)
        try await queue.enqueue(receipt)
        let transport = StubTransport([.held(try statusResponse([.init(id: receipt.id, status: .candidate)]))])
        let uploader = try makeUploader(transport, queue: queue)
        let upload = Task { try await uploader.upload(at: testNow) }
        await transport.waitForRequests(1)
        receipt.checkpoint = ReceiptTokenPair(ownToken: receipt.start.ownToken, peerToken: receipt.start.peerToken,
                                            observedAt: testNow.addingTimeInterval(120))
        receipt.observedDuration = 120
        receipt.sessionFlag = true
        try await queue.update(receipt)
        await transport.release()
        let outcome = try await upload.value
        XCTAssertEqual(outcome.settledCount, 0)
        receipt.uploadStatus = .acceptedAsCandidate
        let pending = try await queue.pending()
        XCTAssertEqual(pending, [receipt])
    }

    func testRemovalDuringFlightAndMissingIdentityFromEitherWriteAreTolerated() async throws {
        for status in [ReceiptStatus.candidate, .resolved] {
            let queue = InMemoryReceiptQueue(wallTime: { testNow })
            let receipt = finalReceipt(1)
            try await queue.enqueue(receipt)
            let transport = StubTransport([.held(try statusResponse([.init(id: receipt.id, status: status)]))])
            let uploader = try makeUploader(transport, queue: queue)
            let upload = Task { try await uploader.upload(at: testNow) }
            await transport.waitForRequests(1)
            try await queue.acknowledge(receipt.id)
            await transport.release()
            let outcome = try await upload.value
            XCTAssertNil(outcome.nextAttemptAt)
            let pending = try await queue.pending()
            XCTAssertTrue(pending.isEmpty)

            let racing = MissingIdentityQueue()
            try await racing.enqueue(receipt)
            let immediate = StubTransport([.response(try statusResponse([.init(id: receipt.id, status: status)]))])
            let missed = try await makeUploader(immediate, queue: racing).upload(at: testNow)
            XCTAssertEqual(missed.settledCount, 0)
            XCTAssertNil(missed.nextAttemptAt)
            let remaining = try await racing.pending()
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testMalformedAnswerAndNonretryableErrorDoNotMutateQueue() async throws {
        for (json, status, expected) in [
            ("malformed", 200, BackendError.invalidResponse),
            (#"[{"id":"00000000-0000-0000-0000-000000000001","status":"unknown"}]"#, 200, .invalidResponse),
            (#"{"message":"account_not_ready"}"#, 400, .accountNotReady)
        ] {
            let queue = InMemoryReceiptQueue(wallTime: { testNow })
            let receipt = finalReceipt(1)
            try await queue.enqueue(receipt)
            let uploader = try makeUploader(StubTransport([.response(jsonResponse(json, status: status))]), queue: queue)
            do { _ = try await uploader.upload(at: testNow); XCTFail("Must throw") }
            catch { XCTAssertEqual(error as? BackendError, expected) }
            let pending = try await queue.pending()
            XCTAssertEqual(pending, [receipt])
        }
    }

    func testRetryScheduleGrowsCapsJittersAndResetsAfterProgress() {
        var schedule = ReceiptRetrySchedule(random: { 0.5 })
        for expected in [5.0, 10, 20, 40, 80, 160, 320, 640, 900, 900] {
            XCTAssertEqual(schedule.nextAttempt(after: testNow, madeProgress: false), testNow.addingTimeInterval(expected))
        }
        XCTAssertEqual(schedule.nextAttempt(after: testNow, madeProgress: true), testNow.addingTimeInterval(5))
        XCTAssertEqual(schedule.nextAttempt(after: testNow, madeProgress: false), testNow.addingTimeInterval(10))
        schedule.reset()
        XCTAssertEqual(schedule.nextAttempt(after: testNow, madeProgress: false), testNow.addingTimeInterval(5))
        for sample in [0.0, 1, -1, 2, Double.nan, Double.infinity] {
            var jitter = ReceiptRetrySchedule(random: { sample })
            for _ in 0..<20 {
                let seconds = jitter.nextAttempt(after: testNow, madeProgress: false).timeIntervalSince(testNow)
                XCTAssertGreaterThanOrEqual(seconds, 5)
                XCTAssertLessThanOrEqual(seconds, 900)
            }
        }
        var low = ReceiptRetrySchedule(random: { 0 })
        var high = ReceiptRetrySchedule(random: { 1 })
        _ = low.nextAttempt(after: testNow, madeProgress: false)
        _ = high.nextAttempt(after: testNow, madeProgress: false)
        XCTAssertEqual(low.nextAttempt(after: testNow, madeProgress: false), testNow.addingTimeInterval(8))
        XCTAssertEqual(high.nextAttempt(after: testNow, madeProgress: false), testNow.addingTimeInterval(12))
    }

    private func finalReceipt(_ index: Int, observedAt: Date = testNow) -> EncounterReceipt {
        var receipt = EncounterSamples.receipt(index, observedAt: observedAt)
        receipt.isFinalEvidence = true
        return receipt
    }

    private func makeUploader(_ transport: StubTransport, queue: any ReceiptQueue) throws -> ReceiptUploader {
        ReceiptUploader(client: try serviceClient(transport), queue: queue, schedule: ReceiptRetrySchedule(random: { 0.5 }))
    }

    private func statusResponse(_ statuses: [ReceiptStatusTransfer]) throws -> HTTPResponse {
        HTTPResponse(data: try JSONEncoder().encode(statuses), statusCode: 200)
    }
}

private actor MissingIdentityQueue: ReceiptQueue {
    private let base = InMemoryReceiptQueue(wallTime: { testNow })
    func enqueue(_ receipt: EncounterReceipt) async throws { try await base.enqueue(receipt) }
    func pending() async throws -> [EncounterReceipt] { try await base.pending() }
    func update(_ receipt: EncounterReceipt) async throws {
        try await base.acknowledge(receipt.id)
        throw ReceiptQueueError.missingIdentity(receipt.id)
    }
    func acknowledge(_ identity: UUID) async throws {
        try await base.acknowledge(identity)
        throw ReceiptQueueError.missingIdentity(identity)
    }
    func removeExpired(asOf time: Date) async throws { try await base.removeExpired(asOf: time) }
    func removeAll() async throws { try await base.removeAll() }
}
