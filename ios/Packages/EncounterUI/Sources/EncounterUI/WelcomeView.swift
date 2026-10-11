import SwiftUI

@MainActor
public struct WelcomeView<Trailing: View>: View {
    private let trailing: Trailing
    private let signIn: AnyView?
    private let suppliedDeclarations: Binding<SignInDeclarations>?
    private let isSigningIn: Bool
    private let signInError: ProfileActionError?
    private let onTerms: (@MainActor () -> Void)?
    private let onPrivacy: (@MainActor () -> Void)?
    private let onRetry: (@MainActor () -> Void)?
    @OnboardingViewState private var localDeclarations = SignInDeclarations()

    /// Existing trailing content (including Development diagnostics) remains independently available.
    public init(@ViewBuilder trailing: () -> Trailing) {
        self.trailing = trailing()
        signIn = nil
        suppliedDeclarations = nil
        isSigningIn = false
        signInError = nil
        onTerms = nil
        onPrivacy = nil
        onRetry = nil
    }

    /// The caller supplies the sign-in control and owns its asynchronous operation and error state.
    public init<SignIn: View>(declarations: Binding<SignInDeclarations>, isSigningIn: Bool = false,
                             error: ProfileActionError? = nil,
                             onTerms: @escaping @MainActor () -> Void,
                             onPrivacy: @escaping @MainActor () -> Void,
                             onRetry: @escaping @MainActor () -> Void,
                             @ViewBuilder signIn: () -> SignIn,
                             @ViewBuilder trailing: () -> Trailing) {
        self.trailing = trailing()
        self.signIn = AnyView(signIn())
        suppliedDeclarations = declarations
        self.isSigningIn = isSigningIn
        signInError = error
        self.onTerms = onTerms
        self.onPrivacy = onPrivacy
        self.onRetry = onRetry
    }

    private var declarations: Binding<SignInDeclarations> {
        suppliedDeclarations ?? $localDeclarations
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("welcome.title", bundle: .module)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("welcome.introduction", bundle: .module)
                    .font(.body)
                OnboardingCard {
                    SelectionControl(label: OnboardingStrings.text(.age),
                                     selected: declarations.wrappedValue.isAdult) {
                        declarations.wrappedValue.isAdult.toggle()
                    }
                    SelectionControl(label: OnboardingStrings.text(.agreement),
                                     selected: declarations.wrappedValue.acceptsTermsAndPrivacy) {
                        declarations.wrappedValue.acceptsTermsAndPrivacy.toggle()
                    }
                }.disabled(isSigningIn)
                VStack(alignment: .leading, spacing: 12) {
                    Button(OnboardingStrings.text(.terms)) { onTerms?() }.disabled(onTerms == nil)
                    Button(OnboardingStrings.text(.privacy)) { onPrivacy?() }.disabled(onPrivacy == nil)
                }
                if let signIn {
                    signIn.disabled(!declarations.wrappedValue.canSignIn || isSigningIn)
                }
                if isSigningIn { OnboardingProgress() }
                if let signInError {
                    OnboardingActionError(error: signInError,
                        disabled: isSigningIn || !declarations.wrappedValue.canSignIn,
                        fallback: .signInError) { onRetry?() }
                }
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(.teal)
    }
}

extension WelcomeView where Trailing == EmptyView {
    public init() { self.init { EmptyView() } }

    public init<SignIn: View>(declarations: Binding<SignInDeclarations>, isSigningIn: Bool = false,
                             error: ProfileActionError? = nil,
                             onTerms: @escaping @MainActor () -> Void,
                             onPrivacy: @escaping @MainActor () -> Void,
                             onRetry: @escaping @MainActor () -> Void,
                             @ViewBuilder signIn: () -> SignIn) {
        self.init(declarations: declarations, isSigningIn: isSigningIn, error: error,
                  onTerms: onTerms, onPrivacy: onPrivacy, onRetry: onRetry,
                  signIn: signIn, trailing: { EmptyView() })
    }
}

enum WelcomeStrings {
    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
