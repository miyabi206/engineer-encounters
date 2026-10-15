import EncounterBackend
import Foundation

/// The packages preserve cancellation. Map it only when the captured account/backend context is obsolete.
@MainActor
struct BackendCallFence {
    let isCurrent: @MainActor () -> Bool

    func call<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        guard isCurrent() else { throw BackendError.notAuthenticated }
        do {
            let result = try await operation()
            guard isCurrent() else { throw BackendError.notAuthenticated }
            return result
        } catch is CancellationError {
            guard isCurrent() else { throw BackendError.notAuthenticated }
            throw CancellationError()
        }
    }
}
