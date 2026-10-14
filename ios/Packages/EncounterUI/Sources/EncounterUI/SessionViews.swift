import SwiftUI

// Spell the property wrapper through an alias to avoid the SDK's State macro.
typealias SessionViewState<Value> = State<Value>

@MainActor
struct SessionCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        EncounterSurfaceCard { content }
    }
}

/// Inject only currently authorized, confirmed/revealed cards. The host clears them on access loss.
@MainActor
public struct SessionView<RevealedEncounters: View>: View {
    @ObservedObject private var model: SessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize = 44.0
    private let navigation: SessionNavigationActions
    private let hasRevealedEncounters: Bool
    private let revealedEncounters: RevealedEncounters

    public init(model: SessionModel, navigation: SessionNavigationActions, hasRevealedEncounters: Bool,
                @ViewBuilder revealedEncounters: () -> RevealedEncounters) {
        self.model = model; self.navigation = navigation
        self.hasRevealedEncounters = hasRevealedEncounters; self.revealedEncounters = revealedEncounters()
    }

    public var body: some View {
        EncounterScreen {
            SessionCard {
                VStack(spacing: 16) {
                    EncounterMark(width: 140, signals: true, pulseRings: model.isActive)
                    status
                    Text(SessionStrings.text(.twoHours)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                    Divider().overlay(EncounterPalette.border)
                    Text(SessionStrings.text(.bothInSession)).font(.callout).foregroundStyle(EncounterPalette.inkSecondary)
                    Text(SessionStrings.text(.oneInSession)).font(.callout).foregroundStyle(EncounterPalette.inkSecondary)
                }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            let actions = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            actions {
                Button(action: navigation.openQR) {
                    Label { Text(SessionStrings.text(.qrExchange)) } icon: {
                        Image(systemName: "qrcode").accessibilityHidden(true)
                    }
                }.buttonStyle(EncounterButtonStyle(.secondary))
                if model.isActive {
                    Button(SessionStrings.text(.stop), role: .destructive) {
                        if model.stopLocally() {
                            Task { await model.synchronizeStop() }
                            navigation.close()
                        }
                    }.buttonStyle(SessionStopButtonStyle())
                } else if model.lifecycle.hasEnded {
                    Button(SessionStrings.text(.done), action: navigation.close)
                        .buttonStyle(EncounterButtonStyle(.primary))
                } else if model.state == .none {
                    Button(SessionStrings.text(.start)) { Task { await model.start() } }
                        .buttonStyle(EncounterButtonStyle(.primary))
                }
            }
            if model.isActive || model.lifecycle.hasEnded {
                EncounterSectionHeader(SessionStrings.text(.revealedEncounters))
                SessionCard {
                    if hasRevealedEncounters { revealedEncounters }
                    else {
                        VStack(spacing: 16) {
                            EncounterMark(width: 100, signals: true).opacity(0.4)
                            Text(SessionStrings.text(.noEncounters)).foregroundStyle(EncounterPalette.inkSecondary)
                        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
            }
        }
        .navigationTitle(SessionStrings.text(.session))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EncounterBackButton(label: SessionStrings.text(.back), action: navigation.close)
            }
        }
        .background {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Color.clear.onChange(of: context.date, initial: true) { model.tick() }
            }
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }

    @ViewBuilder private var status: some View {
        if model.lifecycle.hasEnded {
            EncounterNotice(SessionStrings.text(.ended))
                .multilineTextAlignment(.leading)
            if model.lifecycle.stopPending {
                EncounterNotice(SessionStrings.text(.stopPending))
                    .multilineTextAlignment(.leading)
                if model.lifecycle.stopFailed { retry }
            }
        } else {
            switch model.state {
            case .active:
                Text(SessionStrings.text(.active)).font(.title2.bold())
                Text(SessionStrings.text(.timeRemaining)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                    .accessibilityHidden(true)
                Text(SessionCountdown.text(seconds: model.remainingSeconds))
                    .font(.system(size: countdownSize, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(EncounterPalette.accent)
                    .accessibilityLabel(SessionStrings.remaining(model.remainingSeconds))
            case .starting:
                EncounterProgress(SessionStrings.text(.loading))
            case .startRefusedOffline:
                sessionError(.startOffline)
            case .failed:
                sessionError(.startFailed)
            case .none, .stopping:
                EmptyView()
            }
        }
        if model.refreshFailed {
            sessionError(.refreshFailed)
        }
    }

    private var retry: some View {
        Button(SessionStrings.text(.retry)) { Task { await model.retry() } }
            .buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false))
    }

    private func sessionError(_ key: SessionString) -> some View {
        EncounterInlineError(message: SessionStrings.text(key), retryLabel: SessionStrings.text(.retry)) {
            Task { await model.retry() }
        }.multilineTextAlignment(.leading)
    }
}

/// Stop retains its existing role and action, with the filled session action appearance.
@MainActor
private struct SessionStopButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) { configuration.label }
            .buttonStyle(EncounterButtonStyle(.primary))
    }
}

extension SessionView where RevealedEncounters == EmptyView {
    public init(model: SessionModel, navigation: SessionNavigationActions) {
        self.init(model: model, navigation: navigation, hasRevealedEncounters: false) { EmptyView() }
    }
}
