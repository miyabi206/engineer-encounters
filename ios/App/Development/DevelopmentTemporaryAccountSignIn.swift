#if DEVELOPMENT_BUILD
import EncounterBackend
import Foundation

enum DevelopmentTemporaryAccountSignIn {
    static func request() throws -> AuthRequest {
        try AuthRequest(path: "signup", method: "POST", body: Data(#"{"data":{}}"#.utf8))
    }
}

enum DevelopmentTemporaryAccountText {
    static var title: String {
        Bundle.main.localizedString(forKey: "temporarySignIn", value: nil, table: "DevelopmentAccount")
    }
}

@MainActor
extension AccountModel {
    var temporarySignInTitle: String { DevelopmentTemporaryAccountText.title }

    func signInTemporaryAccount() async throws {
        try await signIn(using: DevelopmentTemporaryAccountSignIn.request(),
                         termsVersion: "development-draft", privacyVersion: "development-draft")
    }
}
#endif
