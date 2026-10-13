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
    @ObservedObject private var account: AccountModel
    @ObservedObject private var sessionAdapter: SessionAdapter
    @ObservedObject private var flow: AccountFlowModel

    init(composition: AppComposition) {
        self.composition = composition
        account = composition.account
        sessionAdapter = composition.sessionAdapter
        flow = composition.accountFlow
    }

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                if account.sessionCleanupFailed {
                    Text(AccountStrings.text("cleanupError"))
                    Button(AccountStrings.text("retry")) { Task { await flow.refresh() } }
                }
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
                            if sessionAdapter.controlStartFailure != nil {
                                Text(SessionSurfaceStrings.text("startFailed"))
                                Button(AccountStrings.text("retry")) { Task { await composition.startSessionFromControl() } }
                            } else {
                                Text(AccountStrings.text("profileError"))
                                Button(AccountStrings.text("retry")) { Task { await flow.refresh() } }
                            }
                            diagnosticsLink
                        }.padding()
                        .navigationTitle(sessionAdapter.controlStartFailure == nil ? "" : SessionSurfaceStrings.text("session"))
                    }
                case .onboarding:
                    if let model = flow.onboarding { OnboardingView(model: model) }
                case .settings:
                    if let model = flow.settings { ProductRootView(settings: model, links: flow.links, composition: composition) }
                }
            }
            .disabled(composition.deletionSuspended)
            .accessibilityHidden(composition.deletionSuspended)
            if composition.deletionSuspended { AccountDeletionRecoveryView(composition: composition) }
        }
        .background(ScenePrivacyAttachment(cover: composition.productLifecycle.privacyCover))
        .task { await flow.start() }
        .onOpenURL { url in
            guard url.scheme == "engineer-encounters", url.host == "session" else { return }
            Task { await composition.openSessionFromActivity() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
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
struct AccountLinksView: View {
    @ObservedObject var model: LinksModel
    @ObservedObject var adapter: LinkAdapter
    let back: @MainActor () -> Void
    let discovery: @MainActor () -> Void
    @AccountViewState private var confirmDisconnect = false
    @AccountViewState private var disconnecting = false

    var body: some View {
        VStack {
            LinkListView(model: model, back: back, discoverySettings: discovery)
            if adapter.needsGitHubSync { Text(AccountStrings.text("githubSyncPending")) }
            if model.route == .list {
                if adapter.connection.isConnected {
                    Button(AccountStrings.text("disconnectGitHub"), role: .destructive) { confirmDisconnect = true }
                        .disabled(model.isBusy || disconnecting)
                }
                if adapter.needsGitHubSync {
                    Button(AccountStrings.text("retry")) { Task { await model.connectGitHub() } }
                        .disabled(model.isBusy || disconnecting)
                }
                if adapter.connectionError != nil {
                    Text(AccountStrings.text("connectError"))
                }
                if let error = adapter.disconnectError {
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
                    } catch { /* The adapter exposes a sanitized presentation failure. */ }
                    await model.loadLinks()
                }
            }
        } message: { Text(AccountStrings.text("disconnectConfirmation")) }
    }
}
