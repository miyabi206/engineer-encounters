import Foundation

/// Identifies this phone's role in the Bluetooth exchange.
public enum ExchangeRole: String, Codable, Sendable, Hashable { case central, peripheral }

/// Candidate acceptance remains pending until a terminal server acknowledgement.
public enum ReceiptUploadStatus: String, Codable, Sendable {
    case notYetUploaded
    case acceptedAsCandidate
}

/// Tokens and wall time observed at one completed exchange or checkpoint.
public struct ReceiptTokenPair: Codable, Sendable, Equatable {
    public let ownToken: TemporaryToken
    public let peerToken: TemporaryToken
    public let observedAt: Date

    public init(ownToken: TemporaryToken, peerToken: TemporaryToken, observedAt: Date) {
        self.ownToken = ownToken
        self.peerToken = peerToken
        self.observedAt = observedAt
    }
}

/// Unresolved exchange evidence; retries and checkpoints reuse its immutable identity.
public struct EncounterReceipt: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let protocolVersion: UInt8
    public let role: ExchangeRole
    public let exchangeNonce: ExchangeNonce
    public let priorExchangeNonce: ExchangeNonce?
    public let start: ReceiptTokenPair
    public var checkpoint: ReceiptTokenPair?
    /// Elapsed seconds from a monotonic clock, never inferred from wall timestamps.
    public var observedDuration: TimeInterval
    public var sessionFlag: Bool
    public var isFinalEvidence: Bool
    public var uploadStatus: ReceiptUploadStatus

    public init(id: UUID = UUID(), protocolVersion: UInt8 = EncounterProtocol.version,
                role: ExchangeRole, exchangeNonce: ExchangeNonce, priorExchangeNonce: ExchangeNonce? = nil,
                start: ReceiptTokenPair, checkpoint: ReceiptTokenPair? = nil, observedDuration: TimeInterval = 0,
                sessionFlag: Bool = false, isFinalEvidence: Bool = false,
                uploadStatus: ReceiptUploadStatus = .notYetUploaded) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.role = role
        self.exchangeNonce = exchangeNonce
        self.priorExchangeNonce = priorExchangeNonce
        self.start = start
        self.checkpoint = checkpoint
        self.observedDuration = observedDuration
        self.sessionFlag = sessionFlag
        self.isFinalEvidence = isFinalEvidence
        self.uploadStatus = uploadStatus
    }

    /// A checkpoint or explicitly joined second exchange needs 120 monotonic seconds.
    public var hasQualifyingAmbientEvidence: Bool {
        (checkpoint != nil || priorExchangeNonce != nil) && observedDuration >= EncounterProtocol.ambientPresenceThreshold
    }

    /// Retries and checkpoint updates never move the 48-hour observation deadline.
    public var expiresAt: Date { start.observedAt.addingTimeInterval(EncounterProtocol.receiptLifetime) }
}

/// Failed updates cannot insert missing identities or rewrite the original evidence.
public enum ReceiptQueueError: Error, Equatable, Sendable {
    case missingIdentity(UUID)
    case changedInitialEvidence(UUID)
}

/// Replaceable single-writer receipt storage; candidate acceptance is nonterminal.
public protocol ReceiptQueue: Sendable {
    /// Returns only after storage succeeds; a duplicate identity is an idempotent no-op.
    func enqueue(_ receipt: EncounterReceipt) async throws
    /// Stores a checkpoint/status update of an existing identity, preserving initial evidence.
    func update(_ receipt: EncounterReceipt) async throws
    /// Returns unresolved receipts in stable enqueue order, including accepted candidates.
    func pending() async throws -> [EncounterReceipt]
    /// Terminally removes an identity; repeated acknowledgement is harmless.
    func acknowledge(_ identity: UUID) async throws
    /// Removes receipts at or beyond 48 hours after their first observation.
    func removeExpired(asOf time: Date) async throws
    /// Clears all evidence and local identities for sign-out and trial reset.
    func removeAll() async throws
}

/// Actor-isolated ephemeral queue implementing the same write contract as durable stores.
public actor InMemoryReceiptQueue: ReceiptQueue {
    private var receipts: [UUID: EncounterReceipt] = [:]
    private var order: [UUID] = []
    private var terminalIdentities: Set<UUID> = []

    public init() {}

    public func enqueue(_ receipt: EncounterReceipt) async throws {
        guard receipts[receipt.id] == nil, !terminalIdentities.contains(receipt.id) else { return }
        receipts[receipt.id] = receipt
        order.append(receipt.id)
    }

    public func update(_ receipt: EncounterReceipt) async throws {
        guard let original = receipts[receipt.id] else { throw ReceiptQueueError.missingIdentity(receipt.id) }
        guard original.start == receipt.start,
              original.protocolVersion == receipt.protocolVersion,
              original.role == receipt.role,
              original.exchangeNonce == receipt.exchangeNonce,
              original.priorExchangeNonce == receipt.priorExchangeNonce else {
            throw ReceiptQueueError.changedInitialEvidence(receipt.id)
        }
        receipts[receipt.id] = receipt
    }

    public func pending() async throws -> [EncounterReceipt] { order.compactMap { receipts[$0] } }

    public func acknowledge(_ identity: UUID) async throws { remove(identity) }

    public func removeExpired(asOf time: Date) async throws {
        for identity in order where receipts[identity]!.expiresAt <= time { remove(identity) }
    }

    public func removeAll() async throws {
        receipts.removeAll()
        order.removeAll()
        terminalIdentities.removeAll()
    }

    private func remove(_ identity: UUID) {
        receipts.removeValue(forKey: identity)
        order.removeAll { $0 == identity }
        terminalIdentities.insert(identity)
    }
}
