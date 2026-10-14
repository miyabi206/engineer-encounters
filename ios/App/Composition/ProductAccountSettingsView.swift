import EncounterUI
import SwiftUI

private typealias ProductAccountViewState<Value> = State<Value>

/// S20 owns only ordinary screen actions. Deletion and recovery survive this view.
@MainActor
struct ProductAccountSettingsView: View {
    @StateObject private var model: AccountSettingsModel
    @ObservedObject var composition: AppComposition
    @ProductAccountViewState private var confirmation: AccountSettingsOperation?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(composition: AppComposition, navigation: AccountSettingsNavigationActions) {
        self.composition = composition
        _model = StateObject(wrappedValue: AccountSettingsModel(
            actions: composition.settingsSafetyAdapter.accountActions(), navigation: navigation))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let data = model.data {
                    EncounterSurfaceCard {
                        let layout = dynamicTypeSize.isAccessibilitySize ?
                            AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) :
                            AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                        layout {
                            EncounterSymbolTile(symbol: "person.fill")
                            VStack(alignment: .leading, spacing: 8) {
                                Text(AccountStrings.text("accountSettingsSignIn")).font(.headline)
                                Text(data.signIn == .apple ? "Apple" : AccountStrings.text("accountSettingsTemporary"))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if data.signIn == .temporary {
                            Text(AccountStrings.text("accountSettingsTemporaryWarning"))
                                .foregroundStyle(EncounterPalette.inkSecondary)
                        }
                        layout {
                            EncounterSymbolTile(symbol: "chevron.left.forwardslash.chevron.right")
                            VStack(alignment: .leading, spacing: 8) {
                                Text(AccountStrings.text("accountSettingsGithub")).font(.headline)
                                EncounterBadge(AccountStrings.text(data.githubConnected ? "accountSettingsConnected" : "accountSettingsNotConnected"),
                                               style: data.githubConnected ? .verified : .unverified)
                                if let handle = data.githubHandle, data.githubConnected { Text(handle) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if data.githubConnected {
                            Button(AccountStrings.text("accountSettingsDisconnect"), role: .destructive) { confirmation = .disconnect }
                                .buttonStyle(EncounterButtonStyle(.destructive))
                        }
                    }
                    Button(AccountStrings.text("accountSettingsSignOut")) { confirmation = .signOut }
                        .buttonStyle(EncounterButtonStyle(.secondary))
                    Button(AccountStrings.text("accountSettingsDelete"), role: .destructive) { confirmation = .delete }
                        .buttonStyle(EncounterButtonStyle(.destructive))
                    Text(AccountStrings.text("accountSettingsPermanent")).font(.caption)
                        .foregroundStyle(EncounterPalette.inkSecondary)
                }
                if model.isBusy { ProgressView().tint(EncounterPalette.accent) }
                if model.lastLinkRefused {
                    EncounterNotice(AccountStrings.text("accountSettingsLastLink"), kind: .warning)
                    Button(AccountStrings.text("discoverySettings"), action: model.navigation.discovery)
                        .buttonStyle(EncounterButtonStyle(.secondary))
                } else if model.error != nil {
                    EncounterInlineError(message: AccountStrings.text("profileError"), retryLabel: AccountStrings.text("retry")) {
                        Task { await model.retry() }
                    }
                }
                if composition.deletionError != nil, !composition.deletionSuspended {
                    EncounterInlineError(message: AccountStrings.text("profileError"), retryLabel: AccountStrings.text("deletionRetry")) {
                        Task { await composition.retryAccountDeletion() }
                    }
                }
                if let support = model.navigation.support {
                    Button(AccountStrings.text("support"), action: support)
                        .buttonStyle(EncounterButtonStyle(.tertiary))
                }
            }.padding(.horizontal, 20).padding(.vertical, 16).disabled(model.isBusy)
        }
        .foregroundStyle(EncounterPalette.ink)
        .background(EncounterPalette.background.ignoresSafeArea())
        .navigationTitle(AccountStrings.text("accountSettingsTitle"))
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EncounterBackButton(label: AccountStrings.text("back"), action: model.navigation.back).disabled(model.isBusy)
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
                                    await composition.retryAccountDeletion()
                                case .disconnect: await model.disconnect()
                                case .signOut: await model.signOut()
                                default: break
                                }
                            }
                        }.buttonStyle(EncounterButtonStyle(.destructive))
                    }.padding(.horizontal, 20).padding(.vertical, 16)
                }
                .foregroundStyle(EncounterPalette.ink)
                .background(EncounterPalette.background.ignoresSafeArea())
                .navigationTitle(AccountStrings.text(confirmationTitle))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(AccountStrings.text("cancel")) { confirmation = nil }
                            .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false))
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
                EncounterSurfaceCard {
                    Text(AccountStrings.text("accountSettingsPending"))
                    if composition.deletionState == .pending || composition.checkingDeletionAccount {
                        ProgressView().tint(EncounterPalette.accent)
                    }
                    if composition.deletionError != nil {
                        Text(AccountStrings.text(composition.deletionState == .configurationRequired
                            ? "accountSettingsConfigurationRequired" : composition.deletionAccountCheckFailed
                                ? "accountSettingsFailedAccountCheck" : "accountSettingsFailedDeletion"))
                            .foregroundStyle(EncounterPalette.destructive)
                    }
                    if composition.deletionState.canRetry {
                        Button(AccountStrings.text("deletionRetry"), role: .destructive) {
                            Task { await composition.retryAccountDeletion() }
                        }.buttonStyle(EncounterButtonStyle(.destructive))
                        Button(AccountStrings.text("deletionResume")) {
                            Task { await composition.checkAccountAndResume() }
                        }.buttonStyle(EncounterButtonStyle(.secondary))
                    }
                    if SettingsSafetyAdapter.hasSupport() {
                        Button(AccountStrings.text("support")) { showsSupport = true }
                            .buttonStyle(EncounterButtonStyle(.tertiary))
                    }
                }.padding(.horizontal, 20).padding(.vertical, 16).disabled(composition.checkingDeletionAccount)
            }
            .navigationTitle(AccountStrings.text("accountSettingsTitle"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(EncounterPalette.background.ignoresSafeArea())
            .sheet(isPresented: $showsSupport) {
                NavigationStack {
                    LegalView(model: LegalModel(data: SettingsSafetyAdapter.legalData(),
                        actions: SettingsSafetyAdapter.legalActions(), navigation: .init(back: { showsSupport = false })))
                }
            }
        }
    }
}
