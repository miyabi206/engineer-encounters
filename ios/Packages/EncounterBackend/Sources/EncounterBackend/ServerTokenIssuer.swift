import Foundation
import EncounterDomain

/// Tops up stored server tokens when contiguous coverage falls below one hour.
public actor ServerTokenIssuer: TokenIssuer {
    private let client: RemoteProcedureClient
    private let store: any TokenBatchStore
    private var inFlight: (id: UUID, task: Task<Void, any Error>)?
    private var saving: Task<Void, any Error>?
    private var generation = UUID()

    public init(client: RemoteProcedureClient, store: any TokenBatchStore) {
        self.client = client
        self.store = store
    }

    public func replenish(at now: Date) async throws {
        if let inFlight { return try await inFlight.task.value }
        let epoch = generation
        let id = UUID()
        let task = Task {
            defer { if self.inFlight?.id == id { self.inFlight = nil } }
            do { try await self.replenishStoredBatch(at: now, epoch: epoch) }
            catch { if epoch == self.generation { throw error } }
        }
        inFlight = (id, task)
        try await task.value
    }

    /// Discards outstanding results and drains a save already started before returning.
    /// The caller owns clearing token storage after awaiting invalidation.
    public func invalidate() async {
        generation = UUID()
        inFlight = nil
        _ = await saving?.result
    }

    private func replenishStoredBatch(at now: Date, epoch: UUID) async throws {
        guard epoch == generation else { return }
        let retained = try await store.load()?.windows.filter { $0.validUntil > now } ?? []
        guard epoch == generation else { return }
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
        let alignedEnd = coveredUntil.flatMap { end in
            end.timeIntervalSince1970.truncatingRemainder(dividingBy: 900) == 0 ? end : nil
        }
        let response: TokenBatchTransfer = try await client.call("issue_token_batch", parameters: Parameters(
            covered_until: try alignedEnd.map(WireSeconds.init)
        ))
        guard epoch == generation else { return }
        let returned: TokenBatch
        do { returned = try response.domainBatch() }
        catch { throw BackendError.invalidResponse }
        _ = await saving?.result
        guard epoch == generation else { return }
        let fresh = try await store.load()?.windows.filter { $0.validUntil > now } ?? []
        guard epoch == generation else { return }
        let merged: TokenBatch
        do {
            let additions = returned.windows.filter { window in
                !fresh.contains { $0.validFrom == window.validFrom && $0.validUntil == window.validUntil }
            }
            merged = try TokenBatch(windows: (fresh + additions).sorted { $0.validFrom < $1.validFrom })
        } catch { throw BackendError.invalidResponse }
        let task = Task {
            guard epoch == self.generation else { return }
            try await self.store.save(merged)
        }
        saving = task
        try await task.value
    }
}
