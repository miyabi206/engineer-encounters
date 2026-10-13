import EncounterBackend
import Foundation

/// Clear local session intent only after a current account's deletion succeeds.
struct SessionAccountDeletionService: Sendable {
    let service: AccountDeletionService
    let didDelete: @MainActor @Sendable () async -> Void

    func deleteOwnAccount() async throws -> DeletedTransfer {
        let result = try await service.deleteOwnAccount()
        await didDelete()
        return result
    }
}

/// Adapters get the service bundle only inside an account/backend-fenced operation.
@MainActor
final class SessionBackendServices {
    struct Services: Sendable {
        let session: EncounterSessionService
        let qr: QRService
        let encounter: EncounterService
        let report: ReportService
        let safety: SafetyService
        let deletion: SessionAccountDeletionService
        let ownAccount: OwnAccountService

        init(client: RemoteProcedureClient, didDelete: @escaping @MainActor @Sendable () async -> Void) {
            session = EncounterSessionService(client: client)
            qr = QRService(client: client)
            encounter = EncounterService(client: client)
            report = ReportService(client: client)
            safety = SafetyService(client: client)
            deletion = SessionAccountDeletionService(service: AccountDeletionService(client: client), didDelete: didDelete)
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
        let epoch = account.sessionGeneration
        let fence = account.backendCallFence()
        self.epoch = epoch; self.fence = fence
        services = Services(client: client) { [weak account] in
            guard fence.isCurrent(), let account, account.sessionGeneration == epoch else { return }
            await account.authorizationWillBeDiscarded()
        }
    }

    var isCurrent: Bool { fence.isCurrent() && account.sessionGeneration == epoch }

    func call<Value>(outgoing: Bool = false,
                     _ operation: @MainActor (Services) async throws -> Value) async throws -> Value {
        try requireSession(outgoing: outgoing)
        let value: Value
        if outgoing { value = try await fence.call { try await operation(services) } }
        else { value = try await account.protectedOperation { try await fence.call { try await operation(services) } } }
        try requireSession(outgoing: outgoing)
        return value
    }

    private func requireSession(outgoing: Bool) throws {
        if !outgoing, account.deletionSuspended { throw CancellationError() }
        guard isCurrent, account.state.isSignedIn, !account.sessionCleanupPending,
              outgoing || (!account.sessionChangeInProgress && !account.deletionSuspended) else { throw BackendError.notAuthenticated }
        guard account.canRefreshSession() else { throw BackendError.storageFailure }
    }
}
