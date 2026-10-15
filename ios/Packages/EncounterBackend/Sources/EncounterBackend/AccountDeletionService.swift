/// Acknowledges hard server deletion. Local quarantine and purging belong to the app.
public struct AccountDeletionService: Sendable {
    private let client: RemoteProcedureClient
    public init(client: RemoteProcedureClient) { self.client = client }
    public func deleteOwnAccount() async throws -> DeletedTransfer {
        try await client.call("delete_own_account", parameters: EmptyLinkParameters())
    }
}
