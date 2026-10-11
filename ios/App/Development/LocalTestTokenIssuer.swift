#if DEVELOPMENT_BUILD
import EncounterDomain
import Foundation

/// Local test tokens never ship in Internal or Release artifacts.
actor LocalTestTokenIssuer {
    private let store: any TokenBatchStore

    init(store: any TokenBatchStore) { self.store = store }

    func replenish(at now: Date) async throws {
        let duration = EncounterProtocol.tokenWindowDuration
        var windows = try await store.load()?.windows.filter { $0.validUntil > now } ?? []
        if let current = windows.first, current.contains(now),
           let end = windows.last?.validUntil, end.timeIntervalSince(now) >= 60 * 60 {
            return
        }
        var next = windows.last?.validUntil ?? Date(
            timeIntervalSince1970: floor(now.timeIntervalSince1970 / duration) * duration
        )
        let horizon = now.addingTimeInterval(12 * 60 * 60)
        var generator = SystemRandomNumberGenerator()
        while next < horizon {
            let end = next.addingTimeInterval(duration)
            let token = TemporaryToken(using: &generator)
            windows.append(try TokenWindow(token: token, validFrom: next, validUntil: end))
            next = end
        }
        try await store.save(TokenBatch(windows: windows))
    }
}
#endif
