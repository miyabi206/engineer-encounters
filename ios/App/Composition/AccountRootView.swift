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
                    EncounterSurfaceCard {
                        EncounterNotice(AccountStrings.text("cleanupError"), kind: .warning)
                        Button(AccountStrings.text("retry")) { Task { await flow.refresh() } }
                            .buttonStyle(EncounterButtonStyle(.secondary))
                    }.padding(.horizontal, 20)
                }
                if flow.savedWithStaleProfile {
                    EncounterSurfaceCard {
                        EncounterNotice(AccountStrings.text("savedStale"), kind: .warning)
                        Button(AccountStrings.text("retry")) { Task { await flow.refresh() } }
                            .buttonStyle(EncounterButtonStyle(.secondary))
                    }.padding(.horizontal, 20)
                }
                switch flow.root {
                case .restoring:
                    loadingState("restoring")
                case .welcome:
                    NavigationStack { welcome }
                case .loadingProfile:
                    NavigationStack {
                        VStack(spacing: 16) {
                            EncounterMark()
                            EncounterProgress(AccountStrings.text("loadingProfile"))
                            diagnosticsLink
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(EncounterPalette.background.ignoresSafeArea())
                    }
                case .profileUnavailable:
                    NavigationStack {
                        VStack(spacing: 16) {
                            EncounterSurfaceCard {
                                EncounterNotice(AccountStrings.text("profileError"), kind: .warning)
                                Button(AccountStrings.text("retry")) { Task { await flow.refresh() } }
                                    .buttonStyle(EncounterButtonStyle(.secondary))
                            }
                            diagnosticsLink
                        }
                        .padding(.horizontal, 20).padding(.vertical, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(EncounterPalette.background.ignoresSafeArea())
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
        .tint(EncounterPalette.accent)
        .background(EncounterPalette.background.ignoresSafeArea())
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

    private func loadingState(_ key: String) -> some View {
        VStack(spacing: 16) {
            EncounterMark()
            EncounterProgress(AccountStrings.text(key))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EncounterPalette.background.ignoresSafeArea())
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
                .buttonStyle(EncounterButtonStyle(.secondary))
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
            if adapter.needsGitHubSync || (model.route == .list &&
                (adapter.connection.isConnected || adapter.connectionError != nil || adapter.disconnectError != nil)) {
                ScrollView {
                    EncounterSurfaceCard {
                        if adapter.needsGitHubSync { EncounterNotice(AccountStrings.text("githubSyncPending")) }
                        if model.route == .list {
                            if adapter.connection.isConnected {
                                Button(AccountStrings.text("disconnectGitHub"), role: .destructive) { confirmDisconnect = true }
                                    .buttonStyle(EncounterButtonStyle(.destructive))
                                    .disabled(model.isBusy || disconnecting)
                            }
                            if adapter.needsGitHubSync {
                                Button(AccountStrings.text("retry")) { Task { await model.connectGitHub() } }
                                    .buttonStyle(EncounterButtonStyle(.secondary))
                                    .disabled(model.isBusy || disconnecting)
                            }
                            if adapter.connectionError != nil {
                                EncounterNotice(AccountStrings.text("connectError"), kind: .warning)
                            }
                            if let error = adapter.disconnectError {
                                EncounterNotice(AccountStrings.text(error.isLastLink ? "disconnectLastLink" : "disconnectError"), kind: .warning)
                                if error.isLastLink {
                                    Button(AccountStrings.text("discoverySettings"), action: discovery)
                                        .buttonStyle(EncounterButtonStyle(.secondary))
                                }
                            }
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 16)
                }
            }
        }
        .background(EncounterPalette.background.ignoresSafeArea())
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
