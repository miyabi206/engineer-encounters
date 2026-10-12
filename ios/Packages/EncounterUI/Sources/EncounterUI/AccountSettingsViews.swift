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
    public init(model: AccountSettingsModel) { self.model = model }
    public var body: some View {
        SafetyPage(title: AccountSettingsStrings.text(.title)) {
            if let data = model.data {
                OnboardingCard {
                    Text(AccountSettingsStrings.text(.signIn)).font(.headline)
                    Text(data.signIn == .apple ? "Apple" : AccountSettingsStrings.text(.temporary))
                    if data.signIn == .temporary {
                        Text(AccountSettingsStrings.text(.temporaryWarning)).foregroundStyle(.secondary)
                    }
                    Text(AccountSettingsStrings.text(.github)).font(.headline)
                    Text(AccountSettingsStrings.text(data.githubConnected ? .connected : .notConnected))
                    if data.githubConnected, let handle = data.githubHandle { Text(handle) }
                    if data.githubConnected {
                        Button(AccountSettingsStrings.text(.disconnect), role: .destructive) { confirmation = .disconnect }
                            .disabled(!model.canDismiss)
                    }
                }
                if model.allowsSignOut {
                    Button(AccountSettingsStrings.text(.signOut)) { confirmation = .signOut }.disabled(!model.canDismiss)
                }
                Button(AccountSettingsStrings.text(.delete), role: .destructive) { confirmation = .delete }
                    .disabled(!model.canDismiss)
                Text(AccountSettingsStrings.text(.permanent)).foregroundStyle(.secondary)
            }
            if model.isBusy { ProgressView(SettingsStrings.text(.loading)) }
            if model.deletion == .pending { Text(AccountSettingsStrings.text(.pending)).foregroundStyle(.secondary) }
            if model.deletion == .configurationRequired {
                Text(AccountSettingsStrings.text(.configurationRequired)).foregroundStyle(.red)
            } else if model.deletion == .failed {
                Text(AccountSettingsStrings.text(.failedDeletion)).foregroundStyle(.red)
            }
            if model.lastLinkRefused {
                Text(AccountSettingsStrings.text(.lastLink)).foregroundStyle(.red)
                Button(SettingsStrings.text(.discoveryMatching), action: model.navigation.discovery).disabled(model.isBusy)
            }
            if model.deletion.canRetry {
                Button(SettingsStrings.text(.retry)) { Task { await model.retry() } }.disabled(model.isBusy)
                if let support = model.navigation.support {
                    Button(LegalStrings.text(.contact), action: support).disabled(model.isBusy)
                }
            } else if let error = model.error {
                SafetyFailure(error: error, fallback: model.failedOperation == .load ? .listError : .saveError,
                              disabled: model.isBusy) { await model.retry() }
            }
        }
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(!model.canDismiss)
        .toolbar {
            if !model.deletion.preventsSignedInDismissal {
                ToolbarItem(placement: .topBarLeading) {
                    Button(SettingsStrings.text(.back)) { model.back() }.disabled(!model.canDismiss)
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
                    }.buttonStyle(.borderedProminent)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(SettingsStrings.text(.cancel)) { confirmation = nil }
                    }
                }
            }.presentationDetents([.large])
        }
        .task { await model.load() }
    }
}
