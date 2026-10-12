import Foundation

/// Replenishes token coverage using the caller's wall time.
public protocol TokenIssuer: Sendable {
    func replenish(at now: Date) async throws
}
