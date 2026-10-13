import EncounterUI
import SwiftUI

private typealias ProductAccountViewState<Value> = State<Value>

/// S20 owns only ordinary screen actions. Deletion and recovery survive this view.
@MainActor
struct ProductAccountSettingsView: View {
    @StateObject private var model: AccountSettingsModel
    @ObservedObject var composition: AppComposition
    @ProductAccountViewState private var confirmation: AccountSettingsOperation?

    init(composition: AppComposition, navigation: AccountSettingsNavigationActions) {
        self.composition = composition
        _model = StateObject(wrappedValue: AccountSettingsModel(
            actions: composition.settingsSafetyAdapter.accountActions(), navigation: navigation))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let data = model.data {
                    Text(AccountStrings.text("accountSettingsSignIn")).font(.headline)
                    Text(data.signIn == .apple ? "Apple" : AccountStrings.text("accountSettingsTemporary"))
                    if data.signIn == .temporary { Text(AccountStrings.text("accountSettingsTemporaryWarning")) }
                    Text(AccountStrings.text("accountSettingsGithub")).font(.headline)
                    Text(AccountStrings.text(data.githubConnected ? "accountSettingsConnected" : "accountSettingsNotConnected"))
                    if let handle = data.githubHandle, data.githubConnected { Text(handle) }
                    if data.githubConnected {
                        Button(AccountStrings.text("accountSettingsDisconnect"), role: .destructive) { confirmation = .disconnect }
                    }
                    Button(AccountStrings.text("accountSettingsSignOut")) { confirmation = .signOut }
                    Button(AccountStrings.text("accountSettingsDelete"), role: .destructive) { confirmation = .delete }
                    Text(AccountStrings.text("accountSettingsPermanent")).foregroundStyle(.secondary)
                }
                if model.isBusy { ProgressView() }
                if model.lastLinkRefused {
                    Text(AccountStrings.text("accountSettingsLastLink"))
                    Button(AccountStrings.text("discoverySettings"), action: model.navigation.discovery)
                } else if model.error != nil {
                    Text(AccountStrings.text("profileError"))
                    Button(AccountStrings.text("retry")) { Task { await model.retry() } }
                }
                if let support = model.navigation.support { Button(AccountStrings.text("support"), action: support) }
            }.padding().disabled(model.isBusy)
        }
        .navigationTitle(AccountStrings.text("accountSettingsTitle"))
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(AccountStrings.text("back"), action: model.navigation.back).disabled(model.isBusy)
            }
        }
        .sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(AccountStrings.text(confirmationMessage))
                        Button(AccountStrings.text(confirmationTitle), role: .destructive) {
                            let operation = confirmation
                            confirmation = nil
                            Task {
                                switch operation {
                                case .delete:
                                    _ = try? await composition.settingsSafetyAdapter.accountActions().deleteAccount()
                                case .disconnect: await model.disconnect()
                                case .signOut: await model.signOut()
                                default: break
                                }
                            }
                        }.buttonStyle(.borderedProminent)
                    }.padding()
                }
                .navigationTitle(AccountStrings.text(confirmationTitle))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(AccountStrings.text("cancel")) { confirmation = nil }
                    }
                }
            }.presentationDetents([.large])
        }
        .task { await model.load() }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .delete: "accountSettingsDelete"
        case .disconnect: "accountSettingsDisconnect"
        default: "accountSettingsSignOut"
        }
    }
    private var confirmationMessage: String {
        switch confirmation {
        case .delete: "accountSettingsDeletionConfirmation"
        case .disconnect: "accountSettingsDisconnectExplanation"
        default: "accountSettingsSignOutExplanation"
        }
    }
}

@MainActor
struct AccountDeletionRecoveryView: View {
    @ObservedObject var composition: AppComposition
    @ProductAccountViewState private var showsSupport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(AccountStrings.text("accountSettingsPending"))
                    if composition.deletionState == .pending || composition.checkingDeletionAccount { ProgressView() }
                    if composition.deletionError != nil {
                        Text(AccountStrings.text(composition.deletionState == .configurationRequired
                            ? "accountSettingsConfigurationRequired" : composition.deletionAccountCheckFailed
                                ? "accountSettingsFailedAccountCheck" : "accountSettingsFailedDeletion"))
                            .foregroundStyle(.red)
                    }
                    if composition.deletionState.canRetry {
                        Button(AccountStrings.text("deletionRetry"), role: .destructive) {
                            Task { await composition.retryAccountDeletion() }
                        }
                        Button(AccountStrings.text("deletionResume")) {
                            Task { await composition.checkAccountAndResume() }
                        }
                    }
                    if SettingsSafetyAdapter.hasSupport() {
                        Button(AccountStrings.text("support")) { showsSupport = true }
                    }
                }.padding().disabled(composition.checkingDeletionAccount)
            }
            .navigationTitle(AccountStrings.text("accountSettingsTitle"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .sheet(isPresented: $showsSupport) {
                NavigationStack {
                    LegalView(model: LegalModel(data: SettingsSafetyAdapter.legalData(),
                        actions: SettingsSafetyAdapter.legalActions(), navigation: .init(back: { showsSupport = false })))
                }
            }
        }
    }
}
