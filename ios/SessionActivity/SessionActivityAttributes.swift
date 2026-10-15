import ActivityKit
import Foundation

/// The only data handed to the extension. No account, backend, peer or credential data.
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        let displayName: String
        let endsAt: Date
        let isActive: Bool

        func presentsActive(isStale: Bool) -> Bool { isActive && !isStale }
    }
    // Fences a delayed Stop button against a different, newer session.
    let sessionID: String
}
