import Foundation
import XCTest
import EncounterDomain
import EncounterDomainTestSupport

@MainActor
final class TokenProviderTests: XCTestCase {
    func testHalfOpenWindowAndExactBoundaryRotationPrunesOldWindow() async throws {
        let start = EncounterSamples.observationTime
        let batch = try EncounterSamples.batch(start: start, count: 2)
        let store = InMemoryTokenBatchStore(batch: batch)
        let provider = TokenProvider(store: store)
        let before = try await provider.token(at: start.addingTimeInterval(-0.001))
        XCTAssertNil(before)
        let atStart = try await provider.token(at: start)
        XCTAssertEqual(atStart, batch.windows[0].token)
        let beforeBoundary = try await provider.token(at: start.addingTimeInterval(899.999))
        XCTAssertEqual(beforeBoundary, batch.windows[0].token)
        let atBoundary = try await provider.token(at: start.addingTimeInterval(900))
        XCTAssertEqual(atBoundary, batch.windows[1].token)
        let stored = try await store.load()
        XCTAssertEqual(stored?.windows, [batch.windows[1]])
        let beforeEnd = try await provider.token(at: start.addingTimeInterval(1799.999))
        XCTAssertEqual(beforeEnd, batch.windows[1].token)
        let exhausted = try await provider.token(at: start.addingTimeInterval(1800))
        XCTAssertNil(exhausted)
        let cleared = try await store.load()
        XCTAssertNil(cleared)
        let later = try await provider.token(at: start.addingTimeInterval(100_000))
        XCTAssertNil(later)
    }

    func testGapsNeverExtendPreviousWindow() async throws {
        let start = EncounterSamples.observationTime
        let first = try EncounterSamples.batch(start: start, count: 1).windows[0]
        let second = try EncounterSamples.batch(start: start.addingTimeInterval(1800), count: 1).windows[0]
        let store = InMemoryTokenBatchStore(batch: try TokenBatch(windows: [first, second]))
        let provider = TokenProvider(store: store)
        for offset in [900.0, 1000, 1799.999] {
            let token = try await provider.token(at: start.addingTimeInterval(offset))
            XCTAssertNil(token)
        }
        let retained = try await store.load()
        XCTAssertEqual(retained?.windows, [second])
        let available = try await provider.token(at: second.validFrom)
        XCTAssertEqual(available, second.token)
    }

    func testNoBatchAndEmptyBatch() async throws {
        let absent = TokenProvider(store: InMemoryTokenBatchStore())
        let absentToken = try await absent.token(at: EncounterSamples.observationTime)
        XCTAssertNil(absentToken)
        let empty = TokenProvider(store: InMemoryTokenBatchStore(batch: try TokenBatch(windows: [])))
        let emptyToken = try await empty.token(at: EncounterSamples.observationTime)
        XCTAssertNil(emptyToken)
    }

    func testExpiredWindowsCannotReturnAfterClockMovesBackward() async throws {
        let batch = try EncounterSamples.batch(count: 2)
        let provider = TokenProvider(store: InMemoryTokenBatchStore(batch: batch))
        _ = try await provider.token(at: batch.windows[1].validFrom)
        let token = try await provider.token(at: batch.windows[0].validFrom)
        XCTAssertNil(token)
    }

    func testWindowAndBatchValidation() throws {
        let start = EncounterSamples.observationTime
        for duration in [-900.0, 0, 899, 901, .infinity, .nan] {
            XCTAssertThrowsError(try TokenWindow(token: EncounterSamples.token(), validFrom: start,
                                                 validUntil: start.addingTimeInterval(duration))) {
                XCTAssertEqual($0 as? TokenWindowError, .invalidDuration)
            }
        }
        let first = try EncounterSamples.batch(count: 1).windows[0]
        let overlap = try TokenWindow(token: EncounterSamples.token(seed: 2), validFrom: start.addingTimeInterval(899),
                                       validUntil: start.addingTimeInterval(1799))
        XCTAssertThrowsError(try TokenBatch(windows: [first, overlap])) {
            XCTAssertEqual($0 as? TokenWindowError, .overlappingWindows)
        }
        XCTAssertThrowsError(try TokenBatch(windows: [first, first])) {
            XCTAssertEqual($0 as? TokenWindowError, .overlappingWindows)
        }
        let contiguous = try EncounterSamples.batch(count: 2)
        XCTAssertThrowsError(try TokenBatch(windows: contiguous.windows.reversed())) {
            XCTAssertEqual($0 as? TokenWindowError, .unorderedWindows)
        }
        XCTAssertEqual(try JSONDecoder().decode(TokenBatch.self, from: JSONEncoder().encode(contiguous)), contiguous)
        let invalidWindow = Data("{\"token\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],\"validFrom\":0,\"validUntil\":899}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TokenWindow.self, from: invalidWindow)) {
            XCTAssertEqual($0 as? TokenWindowError, .invalidDuration)
        }
        let invalidBatch = Data("{\"windows\":[\(String(decoding: try JSONEncoder().encode(first), as: UTF8.self)),\(String(decoding: try JSONEncoder().encode(first), as: UTF8.self))]}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TokenBatch.self, from: invalidBatch)) {
            XCTAssertEqual($0 as? TokenWindowError, .overlappingWindows)
        }
    }

    func testDefaultSampleBatchCoversTwelveHours() throws {
        let batch = try EncounterSamples.batch()
        XCTAssertEqual(batch.windows.count, 48)
        XCTAssertEqual(batch.windows.last!.validUntil.timeIntervalSince(batch.windows.first!.validFrom),
                       EncounterProtocol.batchCoverage)
        XCTAssertEqual(batch, try EncounterSamples.batch())
    }

    func testStoreLoadSaveClearAndFailurePropagation() async throws {
        let store = InMemoryTokenBatchStore()
        let batch = try EncounterSamples.batch(count: 2)
        try await store.save(batch)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, batch)
        try await store.clear()
        let cleared = try await store.load()
        XCTAssertNil(cleared)
        for operation in FailingStore.Operation.allCases {
            let failing = FailingStore(batch: batch, operation: operation)
            let time = operation == .clear ? batch.windows.last!.validUntil : batch.windows[1].validFrom
            do {
                _ = try await TokenProvider(store: failing).token(at: time)
                XCTFail("Expected \(operation) storage failure")
            } catch {
                XCTAssertEqual(error as? FailingStore.Operation, operation)
            }
        }
    }
}

private actor FailingStore: TokenBatchStore {
    enum Operation: Error, CaseIterable { case load, save, clear }
    let batch: TokenBatch
    let operation: Operation

    init(batch: TokenBatch, operation: Operation) {
        self.batch = batch
        self.operation = operation
    }

    func load() async throws -> TokenBatch? {
        if operation == .load { throw operation }
        return batch
    }

    func save(_ batch: TokenBatch) async throws { throw operation }
    func clear() async throws { throw operation }
}
