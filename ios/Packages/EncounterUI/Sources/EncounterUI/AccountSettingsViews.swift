import SwiftUI

enum AccountSettingsConfirmation: String, Identifiable {
    case disconnect, signOut, delete
    var id: String { rawValue }
    var title: AccountSettingsString {
        switch self { case .disconnect: .disconnect; case .signOut: .confirmSignOut; case .delete: .delete }
    }
    var message: AccountSettingsString {
        switch self {
        case .disconnect: .disconnectExplanation
        case .signOut: .signOutExplanation
        case .delete: .deletionConfirmation
        }
    }
    var action: AccountSettingsString {
        switch self { case .disconnect: .disconnect; case .signOut: .signOut; case .delete: .delete }
    }
}

@MainActor
public struct AccountSettingsView: View {
    @ObservedObject private var model: AccountSettingsModel
    @SafetyViewState private var confirmation: AccountSettingsConfirmation?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(model: AccountSettingsModel) { self.model = model }
    public var body: some View {
        SafetyPage(title: AccountSettingsStrings.text(.title)) {
            if let data = model.data {
                OnboardingCard {
                    let layout = dynamicTypeSize.isAccessibilitySize ?
                        AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) :
                        AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                    layout {
                        EncounterSymbolTile(symbol: "person.fill")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(AccountSettingsStrings.text(.signIn)).font(.headline)
                            Text(data.signIn == .apple ? "Apple" : AccountSettingsStrings.text(.temporary))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if data.signIn == .temporary {
                        Text(AccountSettingsStrings.text(.temporaryWarning)).foregroundStyle(EncounterPalette.inkSecondary)
                    }
                    layout {
                        EncounterSymbolTile(symbol: "chevron.left.forwardslash.chevron.right")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(AccountSettingsStrings.text(.github)).font(.headline)
                            EncounterBadge(AccountSettingsStrings.text(data.githubConnected ? .connected : .notConnected),
                                           style: data.githubConnected ? .verified : .unverified,
                                           symbol: data.githubConnected ? "link" : "minus.circle")
                            if data.githubConnected, let handle = data.githubHandle { Text(handle) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if data.githubConnected {
                        Button(AccountSettingsStrings.text(.disconnect), role: .destructive) { confirmation = .disconnect }
                            .buttonStyle(EncounterButtonStyle(.destructiveText, fullWidth: false)).disabled(!model.canDismiss)
                    }
                }
                if model.allowsSignOut {
                    Button(AccountSettingsStrings.text(.signOut)) { confirmation = .signOut }
                        .buttonStyle(EncounterButtonStyle(.secondary)).disabled(!model.canDismiss)
                }
                Button(AccountSettingsStrings.text(.delete), role: .destructive) { confirmation = .delete }
                    .buttonStyle(EncounterButtonStyle(.destructive)).disabled(!model.canDismiss)
                Text(AccountSettingsStrings.text(.permanent)).font(.footnote).foregroundStyle(EncounterPalette.inkSecondary)
            }
            if model.isBusy {
                EncounterProgress(model.failedOperation == .checkAccount ?
                    AccountSettingsStrings.text(.checkingAccount) : SettingsStrings.text(.loading))
            }
            if model.deletion == .pending { Text(AccountSettingsStrings.text(.pending)).foregroundStyle(EncounterPalette.inkSecondary) }
            if model.failedOperation == .checkAccount, model.error != nil {
                Text(AccountSettingsStrings.text(.failedAccountCheck)).foregroundStyle(EncounterPalette.destructive)
            } else if model.deletion == .configurationRequired {
                Text(AccountSettingsStrings.text(.configurationRequired)).foregroundStyle(EncounterPalette.destructive)
            } else if model.deletion == .failed {
                Text(AccountSettingsStrings.text(.failedDeletion)).foregroundStyle(EncounterPalette.destructive)
            }
            if model.lastLinkRefused {
                Text(AccountSettingsStrings.text(.lastLink)).foregroundStyle(EncounterPalette.destructive)
                Button(SettingsStrings.text(.discoveryMatching), action: model.navigation.discovery)
                    .buttonStyle(EncounterButtonStyle(.secondary)).disabled(model.isBusy)
            }
            if model.deletion.canRetry {
                Button(SettingsStrings.text(.retry)) { Task { await model.retry() } }
                    .buttonStyle(EncounterButtonStyle(.secondary)).disabled(model.isBusy)
                Button(SettingsStrings.text(.cancel)) { Task { await model.cancelDeletion() } }
                    .buttonStyle(EncounterButtonStyle(.tertiary)).disabled(model.isBusy)
            } else if let error = model.error {
                SafetyFailure(error: error, fallback: model.failedOperation == .load ? .listError : .saveError,
                              disabled: !model.canDismiss) { await model.retry() }
            }
            if model.showsSupport, let support = model.navigation.support {
                Button(LegalStrings.text(.contact), action: support)
                    .buttonStyle(EncounterButtonStyle(.secondary)).disabled(!model.canDismiss)
            }
        }
        .navigationBarBackButtonHidden(true)
        .environment(\.safetyPageIsPushed, true)
        .interactiveDismissDisabled(!model.canDismiss)
        .toolbar {
            if model.canDismiss {
                ToolbarItem(placement: .topBarLeading) {
                    EncounterBackButton(label: SettingsStrings.text(.back)) { Task { await model.back() } }
                }
            }
        }
        .sheet(item: $confirmation) { choice in
            NavigationStack {
                SafetyPage(title: AccountSettingsStrings.text(choice.title)) {
                    // A scrolling confirmation keeps the complete safety exception readable at large text sizes.
                    Text(AccountSettingsStrings.text(choice.message))
                    Button(AccountSettingsStrings.text(choice.action), role: .destructive) {
                        confirmation = nil
                        Task {
                            switch choice {
                            case .disconnect: await model.disconnect()
                            case .signOut: await model.signOut()
                            case .delete: await model.deleteAccount()
                            }
                        }
                    }.buttonStyle(EncounterButtonStyle(.destructive))
                }
                .environment(\.safetyPageIsPushed, false)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(SettingsStrings.text(.cancel)) { confirmation = nil }
                            .buttonStyle(EncounterPlainButtonStyle()).foregroundStyle(EncounterPalette.accent)
                    }
                }
            }.presentationDetents([.large])
        }
        .task { await model.load() }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }
}
