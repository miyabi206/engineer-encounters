#if DEVELOPMENT_BUILD
import EncounterDomain
import Foundation
import XCTest
@testable import EngineerEncounters

final class LocalTestTokenIssuerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_123)

    func testEmptyStoreGetsAlignedContiguousTwelveHourBatch() async throws {
        let store = InMemoryTokenBatchStore()
        let issuer = LocalTestTokenIssuer(store: store)
        try await issuer.replenish(at: now)
        let loaded = try await store.load()
        let batch = try XCTUnwrap(loaded)
        let first = try XCTUnwrap(batch.windows.first)
        let last = try XCTUnwrap(batch.windows.last)
        XCTAssertTrue(first.contains(now))
        XCTAssertGreaterThanOrEqual(last.validUntil.timeIntervalSince(now), 12 * 60 * 60)
        XCTAssertLessThan(last.validUntil.timeIntervalSince(now), 12 * 60 * 60 + 900)
        for window in batch.windows {
            XCTAssertEqual(window.validFrom.timeIntervalSince1970.truncatingRemainder(dividingBy: 900), 0)
            XCTAssertEqual(window.validUntil.timeIntervalSince(window.validFrom), 900)
        }
        for (previous, next) in zip(batch.windows, batch.windows.dropFirst()) {
            XCTAssertEqual(previous.validUntil, next.validFrom)
        }
    }

    func testTopsUpBelowOneHourAndPreservesUnexpiredTokens() async throws {
        let store = InMemoryTokenBatchStore()
        let issuer = LocalTestTokenIssuer(store: store)
        try await issuer.replenish(at: now)
        let originalLoad = try await store.load()
        let original = try XCTUnwrap(originalLoad)
        let end = try XCTUnwrap(original.windows.last).validUntil
        let boundary = end.addingTimeInterval(-3600)
        try await issuer.replenish(at: boundary)
        let unchanged = try await store.load()
        XCTAssertEqual(unchanged, original)

        let later = boundary.addingTimeInterval(1)
        try await issuer.replenish(at: later)
        let updatedLoad = try await store.load()
        let updated = try XCTUnwrap(updatedLoad)
        let retained = original.windows.filter { $0.validUntil > later }
        XCTAssertEqual(Array(updated.windows.prefix(retained.count)), retained)
        XCTAssertTrue(updated.windows.allSatisfy { $0.validUntil > later })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(updated.windows.last).validUntil.timeIntervalSince(later),
                                    12 * 60 * 60)
        for (previous, next) in zip(updated.windows, updated.windows.dropFirst()) {
            XCTAssertEqual(previous.validUntil, next.validFrom)
        }
    }

    func testFullyExpiredBatchStartsAtCurrentQuarterHour() async throws {
        let store = InMemoryTokenBatchStore()
        let issuer = LocalTestTokenIssuer(store: store)
        try await issuer.replenish(at: now)
        let later = now.addingTimeInterval(24 * 60 * 60)
        try await issuer.replenish(at: later)
        let loaded = try await store.load()
        let batch = try XCTUnwrap(loaded)
        XCTAssertTrue(try XCTUnwrap(batch.windows.first).contains(later))
        XCTAssertTrue(batch.windows.allSatisfy { $0.validUntil > later })
    }

    func testClockMovingBackRebuildsAtCurrentQuarterHour() async throws {
        let store = InMemoryTokenBatchStore()
        let issuer = LocalTestTokenIssuer(store: store)
        try await issuer.replenish(at: now)
        let earlier = now.addingTimeInterval(-3600)
        try await issuer.replenish(at: earlier)
        let loaded = try await store.load()
        let windows = try XCTUnwrap(loaded).windows
        XCTAssertTrue(try XCTUnwrap(windows.first).contains(earlier))
        XCTAssertEqual(windows.first?.validFrom.timeIntervalSince1970,
                       floor(earlier.timeIntervalSince1970 / 900) * 900)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(windows.last).validUntil.timeIntervalSince(earlier), 12 * 3600)
    }

    func testStorageFailurePropagates() async {
        let issuer = LocalTestTokenIssuer(store: FailingTokenStore())
        do {
            try await issuer.replenish(at: now)
            XCTFail("Expected the store failure to propagate")
        } catch {
            XCTAssertTrue(error is FailingTokenStore.Failure)
        }
    }
}

private actor FailingTokenStore: TokenBatchStore {
    enum Failure: Error { case save }
    func load() async throws -> TokenBatch? { nil }
    func save(_ batch: TokenBatch) async throws { throw Failure.save }
    func clear() async throws {}
}
#endif
