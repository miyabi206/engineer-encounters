import EncounterUI
import SwiftUI

private typealias AccountViewState<Value> = State<Value>

enum AccountStrings {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: "Account")
    }
}

@MainActor
struct AccountRootView: View {
    @ObservedObject private var composition: AppComposition
    @StateObject private var flow: AccountFlowModel

    init(composition: AppComposition) {
        self.composition = composition
        _flow = StateObject(wrappedValue: AccountFlowModel(composition: composition))
    }

    var body: some View {
        VStack(spacing: 16) {
            if flow.savedWithStaleProfile {
                Text(AccountStrings.text("savedStale"))
                Button(AccountStrings.text("retry")) { Task { await flow.refresh() } }
            }
            switch flow.root {
            case .restoring:
                ProgressView(AccountStrings.text("restoring"))
            case .welcome:
                NavigationStack { welcome }
            case .loadingProfile:
                NavigationStack {
                    VStack(spacing: 16) {
                        ProgressView(AccountStrings.text("loadingProfile"))
                        diagnosticsLink
                    }
                }
            case .profileUnavailable:
                NavigationStack {
                    VStack(spacing: 16) {
                        Text(AccountStrings.text("profileError"))
                        Button(AccountStrings.text("retry")) { Task { await flow.refresh() } }
                        diagnosticsLink
                    }.padding()
                }
            case .onboarding:
                if let model = flow.onboarding { OnboardingView(model: model) }
            case .settings:
                if let model = flow.settings { AccountSettingsView(model: model, composition: composition) }
            }
        }
        .task { await flow.start() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
                await composition.refresh()
                await flow.refresh()
            }
        }
    }

    @ViewBuilder
    private var welcome: some View {
        #if DEVELOPMENT_BUILD
        if flow.usesSignInWelcome {
            DevelopmentWelcomeView(account: composition.account) { welcomeTrailing }
        } else { WelcomeView { welcomeTrailing } }
        #else
        WelcomeView { welcomeTrailing }
        #endif
    }

    @ViewBuilder
    private var welcomeTrailing: some View {
        if flow.canResumeOnboarding {
            Button(AccountStrings.text("continueSetup")) { flow.resumeOnboarding() }
        }
        #if DEVELOPMENT_BUILD
        DevelopmentDiagnosticsEntry(composition: composition)
        #elseif INTERNAL_BUILD
        diagnosticsLink
        #endif
    }

    @ViewBuilder
    private var diagnosticsLink: some View {
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        if flow.offersDiagnostics {
            NavigationLink(DiagnosticsStrings.text("title")) { DiagnosticsView(composition: composition) }
        }
        #endif
    }
}

@MainActor
private struct AccountSettingsView: View {
    @ObservedObject var model: SettingsModel
    let composition: AppComposition
    @AccountViewState private var path: [SettingsScreen] = []

    private var navigation: SettingsNavigationActions {
        SettingsNavigationActions(back: { if !path.isEmpty { path.removeLast() } },
            editProfile: { path.append(.profile) }, discovery: { path.append(.discovery) },
            visibility: { path.append(.visibility) }, bluetoothRecovery: AccountFlowModel.openBluetoothSettings)
    }

    var body: some View {
        // The signed-in root is the Settings list until the later product roots exist.
        NavigationStack(path: $path) {
            SettingsListView(navigation: navigation) {
                #if DEVELOPMENT_BUILD || INTERNAL_BUILD
                NavigationLink(DiagnosticsStrings.text("title")) { DiagnosticsView(composition: composition) }
                #endif
            }
            .navigationDestination(for: SettingsScreen.self) { screen in
                switch screen {
                case .profile: EditProfileView(model: model, navigation: navigation)
                case .discovery: DiscoveryAndMatchingView(model: model, navigation: navigation)
                case .visibility: VisibilitySettingsView(model: model, navigation: navigation)
                }
            }
        }
    }
}
