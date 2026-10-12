import Foundation

/// Validated backend address and public client key.
public struct BackendConfiguration: Sendable, Equatable {
    public let address: URL
    public let publicClientKey: String

    /// Returns nil for an empty key or an invalid HTTP(S) base address.
    public init?(address: String, publicClientKey: String) {
        guard !address.isEmpty, !address.contains(where: { $0.isWhitespace }),
              let parts = URLComponents(string: address),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url,
              Self.isHeaderValue(publicClientKey) else { return nil }
        self.address = url
        self.publicClientKey = publicClientKey
    }

    static func isHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }

    func endpoint(_ path: String) -> URL {
        address.appendingPathComponent(path)
    }
}
