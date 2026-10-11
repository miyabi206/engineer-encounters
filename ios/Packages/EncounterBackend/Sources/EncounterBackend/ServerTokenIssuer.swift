import Foundation
import EncounterDomain

/// Tops up stored server tokens when contiguous coverage falls below one hour.
public actor ServerTokenIssuer: TokenIssuer {
    private let client: RemoteProcedureClient
    private let store: any TokenBatchStore
    private var inFlight: Task<Void, any Error>?

    public init(client: RemoteProcedureClient, store: any TokenBatchStore) {
        self.client = client
        self.store = store
    }

    public func replenish(at now: Date) async throws {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.replenishStoredBatch(at: now) }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }

    private func replenishStoredBatch(at now: Date) async throws {
        let retained = try await store.load()?.windows.filter { $0.validUntil > now } ?? []
        var coveredUntil: Date?
        for window in retained {
            if let end = coveredUntil {
                guard window.validFrom == end else { break }
            } else {
                guard window.contains(now) else { break }
            }
            coveredUntil = window.validUntil
        }
        if let coveredUntil, coveredUntil.timeIntervalSince(now) >= 3600 { return }
        struct Parameters: Encodable, Sendable { let covered_until: WireSeconds? }
        let response: TokenBatchTransfer = try await client.call("issue_token_batch", parameters: Parameters(
            covered_until: try coveredUntil.map(WireSeconds.init)
        ))
        let returned: TokenBatch
        let merged: TokenBatch
        do {
            returned = try response.domainBatch()
            let additions = returned.windows.filter { window in
                !retained.contains { $0.validFrom == window.validFrom && $0.validUntil == window.validUntil }
            }
            merged = try TokenBatch(windows: (retained + additions).sorted { $0.validFrom < $1.validFrom })
        } catch { throw BackendError.invalidResponse }
        try await store.save(merged)
    }
}
