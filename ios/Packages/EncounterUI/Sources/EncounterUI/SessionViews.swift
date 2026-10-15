import SwiftUI

// Spell the property wrapper through an alias to avoid the SDK's State macro.
typealias SessionViewState<Value> = State<Value>

@MainActor
struct SessionCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.secondary.opacity(0.2)))
    }
}

/// Inject only currently authorized, confirmed/revealed cards. The host clears them on access loss.
@MainActor
public struct SessionView<RevealedEncounters: View>: View {
    @ObservedObject private var model: SessionModel
    @Environment(\.scenePhase) private var scenePhase
    private let navigation: SessionNavigationActions
    private let hasRevealedEncounters: Bool
    private let revealedEncounters: RevealedEncounters

    public init(model: SessionModel, navigation: SessionNavigationActions, hasRevealedEncounters: Bool,
                @ViewBuilder revealedEncounters: () -> RevealedEncounters) {
        self.model = model; self.navigation = navigation
        self.hasRevealedEncounters = hasRevealedEncounters; self.revealedEncounters = revealedEncounters()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SessionCard {
                    status
                    Text(SessionStrings.text(.twoHours)).foregroundStyle(.secondary)
                    Text(SessionStrings.text(.bothInSession))
                    Text(SessionStrings.text(.oneInSession))
                }
                SessionCard {
                    Button(SessionStrings.text(.qrExchange), action: navigation.openQR)
                    if model.isActive {
                        Button(SessionStrings.text(.stop), role: .destructive) {
                            if model.stopLocally() {
                                Task { await model.synchronizeStop() }
                                navigation.close()
                            }
                        }
                    } else if model.lifecycle.hasEnded {
                        Button(SessionStrings.text(.done), action: navigation.close)
                    } else if model.state == .none {
                        Button(SessionStrings.text(.start)) { Task { await model.start() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if model.isActive || model.lifecycle.hasEnded {
                    SessionCard {
                        Text(SessionStrings.text(.revealedEncounters)).font(.headline).accessibilityAddTraits(.isHeader)
                        if hasRevealedEncounters { revealedEncounters }
                        else { Text(SessionStrings.text(.noEncounters)).foregroundStyle(.secondary) }
                    }
                }
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(SessionStrings.text(.session))
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(SessionStrings.text(.back), action: navigation.close) }
        }
        .tint(.teal)
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
            Text(SessionStrings.text(.ended)).font(.headline)
            if model.lifecycle.stopPending {
                Text(SessionStrings.text(.stopPending))
                if model.lifecycle.stopFailed { retry }
            }
        } else {
            switch model.state {
            case .active:
                Text(SessionStrings.text(.active)).font(.headline)
                Text(SessionStrings.remaining(model.remainingSeconds)).monospacedDigit()
                    .accessibilityLabel(SessionStrings.remaining(model.remainingSeconds))
            case .starting:
                ProgressView(SessionStrings.text(.loading))
            case .startRefusedOffline:
                Text(SessionStrings.text(.startOffline)); retry
            case .failed:
                Text(SessionStrings.text(.startFailed)); retry
            case .none, .stopping:
                EmptyView()
            }
        }
        if model.refreshFailed {
            Text(SessionStrings.text(.refreshFailed)); retry
        }
    }

    private var retry: some View {
        Button(SessionStrings.text(.retry)) { Task { await model.retry() } }
    }
}

extension SessionView where RevealedEncounters == EmptyView {
    public init(model: SessionModel, navigation: SessionNavigationActions) {
        self.init(model: model, navigation: navigation, hasRevealedEncounters: false) { EmptyView() }
    }
}
