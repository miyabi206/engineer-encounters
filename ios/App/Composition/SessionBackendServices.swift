import EncounterBackend
import Foundation

/// Adapters get the service bundle only inside an account/backend-fenced operation.
@MainActor
final class SessionBackendServices {
    struct Services: Sendable {
        let session: EncounterSessionService
        let qr: QRService
        let encounter: EncounterService
        let report: ReportService
        let safety: SafetyService
        let deletion: AccountDeletionService
        let ownAccount: OwnAccountService

        init(client: RemoteProcedureClient) {
            session = EncounterSessionService(client: client)
            qr = QRService(client: client)
            encounter = EncounterService(client: client)
            report = ReportService(client: client)
            safety = SafetyService(client: client)
            deletion = AccountDeletionService(client: client)
            ownAccount = OwnAccountService(client: client)
        }
    }
    let owner: BackendStorageOwner
    let epoch: UUID
    private let account: AccountModel
    private let fence: BackendCallFence
    private let services: Services

    init(client: RemoteProcedureClient, account: AccountModel, owner: BackendStorageOwner) {
        self.account = account; self.owner = owner
        epoch = account.sessionGeneration
        fence = account.backendCallFence()
        services = Services(client: client)
    }

    var isCurrent: Bool { fence.isCurrent() && account.sessionGeneration == epoch }

    func call<Value>(outgoing: Bool = false,
                     _ operation: @MainActor (Services) async throws -> Value) async throws -> Value {
        try requireSession(outgoing: outgoing)
        let value = try await fence.call { try await operation(services) }
        try requireSession(outgoing: outgoing)
        return value
    }

    private func requireSession(outgoing: Bool) throws {
        guard isCurrent, account.state.isSignedIn, !account.sessionCleanupPending,
              outgoing || !account.sessionChangeInProgress else { throw BackendError.notAuthenticated }
        guard account.canRefreshSession() else { throw BackendError.storageFailure }
    }
}
