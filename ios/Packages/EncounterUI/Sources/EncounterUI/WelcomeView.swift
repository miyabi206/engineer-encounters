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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var topSpacing = 32.0
    @ScaledMetric(relativeTo: .body) private var linkTarget = 44.0
    @ScaledMetric(relativeTo: .body) private var dividerHeight = 20.0

    /// Existing trailing content remains independently available.
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
                             onTerms: (@MainActor () -> Void)? = nil,
                             onPrivacy: (@MainActor () -> Void)? = nil,
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

    var showsSignInControls: Bool { suppliedDeclarations != nil }
    var showsTerms: Bool { showsSignInControls && onTerms != nil }
    var showsPrivacy: Bool { showsSignInControls && onPrivacy != nil }

    public var body: some View {
        EncounterScreen {
            VStack(spacing: 24) {
                EncounterMark().padding(.top, topSpacing)
                Text("welcome.title", bundle: .module)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let otherName {
                    Text(otherName).font(.title3).foregroundStyle(EncounterPalette.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                Text("welcome.introduction", bundle: .module)
                    .font(.body)
                    .foregroundStyle(EncounterPalette.inkSecondary)
                    .multilineTextAlignment(.center)
                if let declarations = suppliedDeclarations, let signIn {
                    VStack(spacing: 12) {
                        SelectionControl(label: OnboardingStrings.text(.age),
                                         selected: declarations.wrappedValue.isAdult) {
                            declarations.wrappedValue.isAdult.toggle()
                        }
                        SelectionControl(label: OnboardingStrings.text(.agreement),
                                         selected: declarations.wrappedValue.acceptsTermsAndPrivacy) {
                            declarations.wrappedValue.acceptsTermsAndPrivacy.toggle()
                        }
                    }.disabled(isSigningIn)
                    let linksLayout = dynamicTypeSize.isAccessibilitySize ?
                        AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 16))
                    linksLayout {
                        if let onTerms {
                            Button(action: onTerms) {
                                Text(OnboardingStrings.text(.terms)).underline()
                                    .frame(minWidth: max(44, linkTarget), minHeight: max(44, linkTarget))
                                    .contentShape(Rectangle())
                            }
                        }
                        if onTerms != nil && onPrivacy != nil && !dynamicTypeSize.isAccessibilitySize {
                            Rectangle().fill(EncounterPalette.border).frame(width: 1, height: dividerHeight)
                                .accessibilityHidden(true)
                        }
                        if let onPrivacy {
                            Button(action: onPrivacy) {
                                Text(OnboardingStrings.text(.privacy)).underline()
                                    .frame(minWidth: max(44, linkTarget), minHeight: max(44, linkTarget))
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(EncounterPalette.accent)
                    .frame(maxWidth: .infinity)
                    signIn.frame(maxWidth: .infinity)
                        .disabled(!declarations.wrappedValue.canSignIn || isSigningIn)
                    if isSigningIn { OnboardingProgress() }
                    if let signInError {
                        OnboardingActionError(error: signInError,
                            disabled: isSigningIn || !declarations.wrappedValue.canSignIn,
                            fallback: .signInError) { onRetry?() }
                    }
                }
                trailing
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var otherName: AttributedString? {
        guard Bundle.module.preferredLocalizations.first == "ja",
              let name = WelcomeStrings.localized("welcome.title", language: "en"),
              name != WelcomeStrings.localized("welcome.title", language: "ja") else { return nil }
        var attributed = AttributedString(name)
        attributed.languageIdentifier = "en"
        return attributed
    }
}

extension WelcomeView where Trailing == EmptyView {
    public init() { self.init { EmptyView() } }

    public init<SignIn: View>(declarations: Binding<SignInDeclarations>, isSigningIn: Bool = false,
                             error: ProfileActionError? = nil,
                             onTerms: (@MainActor () -> Void)? = nil,
                             onPrivacy: (@MainActor () -> Void)? = nil,
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
