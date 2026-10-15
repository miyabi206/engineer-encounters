import Foundation

/// The scanner accepts only the contract's exact ASCII payload, never a URL or identifier.
public enum QRCodePayload {
    public static func code(from payload: String) throws -> String {
        guard payload.hasPrefix("EEQR1:") else { throw BackendError.invalidInput(fields: ["code"]) }
        let code = String(payload.dropFirst(6))
        guard isValidCode(code) else { throw BackendError.invalidInput(fields: ["code"]) }
        return code
    }
    static func isValidCode(_ code: String) -> Bool {
        code.utf8.count == 32 && code.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct QRCodeTransfer: Decodable, Sendable, Equatable {
    public let code: String
    public let expiresAt: WireSeconds
    public var payload: String { "EEQR1:" + code }
    private enum CodingKeys: String, CodingKey { case code, expiresAt = "expires_at" }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        code = try fields.decode(String.self, forKey: .code)
        expiresAt = try fields.decode(WireSeconds.self, forKey: .expiresAt)
        guard QRCodePayload.isValidCode(code) else { throw WireValueError.invalidResponse }
    }
}

public struct CancelledQRTransfer: Decodable, Sendable, Equatable {
    public let cancelled: Bool
    private enum CodingKeys: String, CodingKey { case cancelled }
    public init(from decoder: any Decoder) throws {
        cancelled = try decoder.container(keyedBy: CodingKeys.self).trueFlag(forKey: .cancelled)
    }
}

public struct RedeemedQRTransfer: Decodable, Sendable, Equatable {
    public let encounterID: UUID
    private enum CodingKeys: String, CodingKey { case encounterID = "encounter_id" }
    public init(from decoder: any Decoder) throws {
        encounterID = try decoder.container(keyedBy: CodingKeys.self).lowercaseUUID(forKey: .encounterID)
    }
}

public struct QRService: Sendable {
    private let client: RemoteProcedureClient
    public init(client: RemoteProcedureClient) { self.client = client }
    public func issueQRCode() async throws -> QRCodeTransfer {
        try await client.call("issue_qr_code", parameters: EmptyLinkParameters())
    }
    public func cancelQRCode() async throws -> CancelledQRTransfer {
        try await client.call("cancel_qr_code", parameters: EmptyLinkParameters())
    }
    public func redeemQRCode(code: String) async throws -> RedeemedQRTransfer {
        struct Parameters: Encodable, Sendable { let code: String }
        return try await client.call("redeem_qr_code", parameters: Parameters(code: code))
    }
    public func redeemQRCode(payload: String) async throws -> RedeemedQRTransfer {
        try await redeemQRCode(code: QRCodePayload.code(from: payload))
    }
}
