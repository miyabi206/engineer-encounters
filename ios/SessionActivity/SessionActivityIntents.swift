import AppIntents
import Foundation

// LiveActivityIntent executes in the containing app process. Both targets contain
// the intent metadata, but only the app links session/account/backend composition.
struct StartSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { LocalizedStringResource("start", table: "SessionActivity") }
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor func perform() async throws -> some IntentResult {
        #if SESSION_ACTIVITY_EXTENSION
        try requireContainingApp()
        #else
        await AppComposition.shared.startSessionFromControl()
        #endif
        return .result()
    }
}

struct StopSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { LocalizedStringResource("stop", table: "SessionActivity") }
    static var supportedModes: IntentModes { .background }
    static var isDiscoverable: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: LocalizedStringResource("session", table: "SessionActivity")) var sessionID: String
    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    @MainActor func perform() async throws -> some IntentResult {
        #if SESSION_ACTIVITY_EXTENSION
        try requireContainingApp()
        #else
        await AppComposition.shared.stopSessionFromActivity(sessionID: sessionID)
        #endif
        return .result()
    }
}

private enum SessionIntentExecutionError: Error { case appRequired }
private func requireContainingApp() throws { throw SessionIntentExecutionError.appRequired }
