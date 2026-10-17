#if DEVELOPMENT_BUILD
import EncounterUI
import SwiftUI

private typealias DevelopmentWelcomeState<Value> = State<Value>

@MainActor
struct DevelopmentWelcomeView<Trailing: View>: View {
    @ObservedObject var account: AccountModel
    let trailing: Trailing
    @DevelopmentWelcomeState private var declarations = SignInDeclarations()
    @DevelopmentWelcomeState private var isSigningIn = false
    @DevelopmentWelcomeState private var error: ProfileActionError?

    init(account: AccountModel, @ViewBuilder trailing: () -> Trailing) {
        self.account = account
        self.trailing = trailing()
    }

    var body: some View {
        WelcomeView(declarations: $declarations, isSigningIn: isSigningIn, error: error,
            onRetry: signIn, signIn: {
                Button(account.temporarySignInTitle, action: signIn).buttonStyle(EncounterButtonStyle(.primary))
            }, trailing: { trailing })
    }

    private func signIn() {
        guard declarations.canSignIn, !isSigningIn else { return }
        let submitted = declarations
        isSigningIn = true
        error = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await account.signInTemporaryAccount(isAdult: submitted.isAdult,
                    acceptsTermsAndPrivacy: submitted.acceptsTermsAndPrivacy)
            } catch is CancellationError {
            } catch { self.error = AccountModel.presentationError(error) }
        }
    }
}
#endif
