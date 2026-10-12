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
                if let model = flow.settings { AccountSettingsView(model: model, links: flow.links, composition: composition) }
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

private enum AccountSettingsRoute: Hashable { case profile, discovery, visibility, links }

@MainActor
private struct AccountSettingsView: View {
    @ObservedObject var model: SettingsModel
    let links: LinksModel?
    let composition: AppComposition
    @AccountViewState private var path: [AccountSettingsRoute] = []

    private var navigation: SettingsNavigationActions {
        SettingsNavigationActions(back: { if !path.isEmpty { path.removeLast() } },
            editProfile: { path.append(.profile) }, discovery: { path.append(.discovery) },
            visibility: { path.append(.visibility) }, links: { path.append(.links) }, bluetoothRecovery: AccountFlowModel.openBluetoothSettings)
    }

    var body: some View {
        // The signed-in root is the Settings list until the later product roots exist.
        NavigationStack(path: $path) {
            SettingsListView(navigation: navigation) {
                Button(AccountStrings.text("links")) { path.append(.links) }
                #if DEVELOPMENT_BUILD || INTERNAL_BUILD
                NavigationLink(DiagnosticsStrings.text("title")) { DiagnosticsView(composition: composition) }
                #endif
            }
            .navigationDestination(for: AccountSettingsRoute.self) { screen in
                switch screen {
                case .profile: EditProfileView(model: model, navigation: navigation)
                case .discovery: DiscoveryAndMatchingView(model: model, navigation: navigation)
                case .visibility: VisibilitySettingsView(model: model, navigation: navigation)
                case .links:
                    if let links {
                        AccountLinksView(model: links, adapter: composition.linkAdapter,
                            back: navigation.back, discovery: navigation.discovery)
                    }
                }
            }
        }
    }
}

@MainActor
private struct AccountLinksView: View {
    @ObservedObject var model: LinksModel
    @ObservedObject var adapter: LinkAdapter
    let back: @MainActor () -> Void
    let discovery: @MainActor () -> Void
    @AccountViewState private var confirmDisconnect = false
    @AccountViewState private var disconnecting = false

    var body: some View {
        VStack {
            LinkListView(model: model, back: back, discoverySettings: discovery)
            if model.route == .list {
                if adapter.connection.isConnected {
                    Button(AccountStrings.text("disconnectGitHub"), role: .destructive) { confirmDisconnect = true }
                        .disabled(model.isBusy || disconnecting)
                }
                if let error = adapter.connectionError {
                    Text(AccountStrings.text(error.isLastLink ? "disconnectLastLink" : "disconnectError"))
                    if error.isLastLink { Button(AccountStrings.text("discoverySettings"), action: discovery) }
                }
            }
        }
        .task {
            // Read the identity without starting a repository-list request.
            _ = try? await adapter.actions().loadConnection()
        }
        .confirmationDialog(AccountStrings.text("disconnectGitHub"), isPresented: $confirmDisconnect) {
            Button(AccountStrings.text("disconnectGitHub"), role: .destructive) {
                Task {
                    disconnecting = true
                    defer { disconnecting = false }
                    do {
                        try await adapter.disconnectGitHub()
                        await model.loadLinks()
                    } catch { /* The adapter exposes a sanitized presentation failure. */ }
                }
            }
        } message: { Text(AccountStrings.text("disconnectConfirmation")) }
    }
}
