import Combine
import EncounterBackend
import EncounterDomain
import EncounterUI
import Foundation

@MainActor
private final class QRDiscardCompletion {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func finish() { continuation?.resume(); continuation = nil }
}

/// Serializes account-wide issue/cancel calls. A late screen cleanup cannot cancel a newer code.
@MainActor
final class QRAdapter: ObservableObject {
    @Published private(set) var failure: ProfileActionError?
    private let account: AccountModel
    private let clock: any EncounterClock
    private var backend: SessionBackendServices?
    private var outstanding: QRCode?
    private weak var presentation: QRModel?
    private var operation: Task<Void, Never>?
    var didRedeem: @MainActor () async -> Void = {}

    init(account: AccountModel, clock: any EncounterClock) { self.account = account; self.clock = clock }

    func configure(_ backend: SessionBackendServices?) {
        if self.backend?.epoch != backend?.epoch || self.backend?.owner != backend?.owner {
            invalidate()
        }
        self.backend = backend
    }

    func invalidate() {
        presentation?.disappear(); presentation = nil
        backend = nil; outstanding = nil; operation = nil; failure = nil
    }

    func makeModel(navigation: QRNavigationActions) -> QRModel {
        let model = QRModel(actions: actions(), navigation: navigation)
        presentation = model
        return model
    }

    func actions() -> QRActions {
        let epoch = account.sessionGeneration
        let fence = account.backendCallFence()
        return QRActions(issueCode: {
            try await self.serialized {
                let result = try await self.call(epoch: epoch, fence: fence) { try await $0.qr.issueQRCode() }
                guard let code = QRCode(payloadText: result.payload, expiresAt: result.expiresAt.date) else {
                    throw QRActionError.unknownCode
                }
                self.outstanding = code
                return code
            }
        }, cancelCode: { code in
            try await self.cancel(code, epoch: epoch, fence: fence)
        }, redeemCode: { payload in
            let result = try await self.call(epoch: epoch, fence: fence) { try await $0.qr.redeemQRCode(code: payload.token) }
            await self.didRedeem()
            guard fence.isCurrent(), epoch == self.account.sessionGeneration, self.backend?.isCurrent == true else { throw CancellationError() }
            return result.encounterID.uuidString.lowercased()
        })
    }

    private func cancel(_ code: QRCode, epoch: UUID, fence: BackendCallFence, outgoing: Bool = false) async throws {
        try await serialized {
            guard epoch == self.account.sessionGeneration, self.outstanding == code else { return }
            _ = try await self.call(epoch: epoch, fence: fence, outgoing: outgoing) { try await $0.qr.cancelQRCode() }
            if self.outstanding == code { self.outstanding = nil }
        }
    }

    func hidePresentation() { presentation?.disappear() }

    /// Called before the credential tombstone, with a bounded, injected-clock best effort.
    func prepareToDiscardSession() async {
        presentation?.disappear()
        guard let code = outstanding else { invalidate(); return }
        let epoch = account.sessionGeneration
        let deadline = await clock.now().monotonic + 2
        var cancellation: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        await withCheckedContinuation { continuation in
            let completion = QRDiscardCompletion(continuation)
            cancellation = Task {
                try? await self.cancel(code, epoch: epoch, fence: self.account.backendCallFence(), outgoing: true)
                completion.finish()
            }
            timeout = Task {
                try? await self.clock.wait(until: deadline)
                completion.finish()
            }
        }
        cancellation?.cancel(); timeout?.cancel()
        invalidate()
    }

    private func serialized<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = self.operation
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        self.operation = Task { _ = await task.result }
        return try await task.value
    }

    private func call<Value>(epoch: UUID, fence: BackendCallFence, outgoing: Bool = false,
                             _ operation: @MainActor (SessionBackendServices.Services) async throws -> Value) async throws -> Value {
        guard fence.isCurrent(), epoch == account.sessionGeneration, outgoing || !account.sessionChangeInProgress,
              let backend, backend.isCurrent else { throw CancellationError() }
        do {
            let result = try await backend.call(outgoing: outgoing, operation)
            failure = nil
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard self.backend === backend, epoch == account.sessionGeneration, backend.isCurrent else { throw CancellationError() }
            failure = AccountModel.presentationError(error)
            if error as? BackendError == .notAuthenticated, !outgoing {
                await account.rejectDeadSession(generation: epoch)
            }
            throw Self.presentationError(error)
        }
    }

    static func presentationError(_ error: any Error) -> QRActionError {
        if let error = error as? QRActionError { return error }
        switch error as? BackendError {
        case .prerequisiteMissing(let fields): return .prerequisiteMissing(details: fields)
        case .accountNotReady: return .prerequisiteMissing(details: ["account"])
        case .declarationRequired: return .prerequisiteMissing(details: ["age_18", "terms_version", "privacy_version"])
        case .notFound: return .notFound
        case .rateLimited: return .rateLimited
        case .invalidInput: return .unknownCode
        default: return .network
        }
    }
}
