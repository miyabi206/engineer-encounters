import Foundation

/// An opaque 128-bit token, with an exact ASCII wire representation and no identity fields.
public struct QRPayload: Equatable, Hashable, Sendable {
    public static let prefix = "EEQR1:"
    public let token: String
    public var text: String { Self.prefix + token }

    public init?(token: String) {
        let bytes = Array(token.utf8)
        guard bytes.count == 32, bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.token = token
    }

    public init?(text: String) {
        guard text.utf8.count == 38, text.hasPrefix(Self.prefix) else { return nil }
        self.init(token: String(text.dropFirst(Self.prefix.count)))
    }
}

public struct QRCode: Equatable, Sendable {
    public let payload: QRPayload
    public let expiresAt: Date
    public var payloadText: String { payload.text }

    public init(payload: QRPayload, expiresAt: Date) { self.payload = payload; self.expiresAt = expiresAt }
    public init?(payloadText: String, expiresAt: Date) {
        guard let payload = QRPayload(text: payloadText) else { return nil }
        self.init(payload: payload, expiresAt: expiresAt)
    }
}

public enum QRActionError: Error, Equatable, Sendable {
    case selfScan, notFound, unknownCode, network, cameraUnavailable, rateLimited
    case prerequisiteMissing(details: [String])
}

public enum QRSegment: Hashable, Sendable { case show, scan }
public enum QRCameraPermission: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
}

/// Decoupled from AVFoundation so permission mapping is testable without a device.
public enum QRPermissionMapping {
    public static func permission(authorizationRawValue: Int) -> QRCameraPermission {
        switch authorizationRawValue {
        case 0: .notDetermined
        case 1: .restricted
        case 2: .denied
        case 3: .authorized
        default: .restricted
        }
    }
}

public enum QRCodeRules {
    public static func isExpired(_ code: QRCode, now: Date) -> Bool { code.expiresAt <= now }
    public static func shouldReplace(_ code: QRCode?, now: Date) -> Bool {
        code.map { isExpired($0, now: now) } ?? true
    }
    public static func validate(_ text: String, ownPayloads: Set<QRPayload>) -> Result<QRPayload, QRActionError> {
        guard let payload = QRPayload(text: text) else { return .failure(.unknownCode) }
        guard !ownPayloads.contains(payload) else { return .failure(.selfScan) }
        return .success(payload)
    }
}

@MainActor
public struct QRActions {
    /// Issuance must atomically replace the account's previous outstanding code.
    public var issueCode: @MainActor () async throws -> QRCode
    /// Cancel this particular code, so late cleanup cannot cancel a newer code.
    public var cancelCode: @MainActor (QRCode) async throws -> Void
    public var redeemCode: @MainActor (QRPayload) async throws -> String

    public init(issueCode: @escaping @MainActor () async throws -> QRCode,
                cancelCode: @escaping @MainActor (QRCode) async throws -> Void,
                redeemCode: @escaping @MainActor (QRPayload) async throws -> String) {
        self.issueCode = issueCode; self.cancelCode = cancelCode; self.redeemCode = redeemCode
    }
}

@MainActor
public struct QRNavigationActions {
    public var openEncounter: @MainActor (String) -> Void
    public var openIOSSettings: @MainActor () -> Void
    public var openDiscoveryOff: @MainActor () -> Void
    public var close: @MainActor () -> Void

    public init(openEncounter: @escaping @MainActor (String) -> Void,
                openIOSSettings: @escaping @MainActor () -> Void,
                close: @escaping @MainActor () -> Void,
                openDiscoveryOff: @escaping @MainActor () -> Void) {
        self.openDiscoveryOff = openDiscoveryOff
        self.openEncounter = openEncounter; self.openIOSSettings = openIOSSettings; self.close = close
    }
}
