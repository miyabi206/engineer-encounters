#if DEVELOPMENT_BUILD || INTERNAL_BUILD
import EncounterDomain
import SwiftUI

// Use the property wrapper explicitly; the SDK's same-named macro requires
// a plugin subprocess that the standalone sandboxed type-check cannot launch.
private typealias DiagnosticsViewState<Value> = State<Value>

enum DiagnosticsStrings {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: "Diagnostics")
    }
}

@MainActor
struct DiagnosticsView: View {
    @ObservedObject private var composition: AppComposition
    @ObservedObject private var account: AccountModel
    @ObservedObject private var log: TrialLog
    @ObservedObject private var demo: DemoSwitchSetting
    @DiagnosticsViewState private var isLoading = false
    @DiagnosticsViewState private var resetResult: Bool?

    init(composition: AppComposition) {
        self.composition = composition
        account = composition.account
        log = composition.trialLog
        demo = composition.demoSwitch
    }

    var body: some View {
        List {
            Section {
                Text(text(BuildKind.isDevelopment ? "development" : "internal"))
                let metadata = composition.trialMetadata
                row("app", "\(metadata.appVersion) (\(metadata.appBuild))")
                row("ios", metadata.iOSVersion)
                row("device", metadata.deviceModel)
                row("bluetooth", composition.status.bluetoothPoweredOff ? text("off") : availability(composition.status.radioAvailability))
                row("discovery", text(composition.status.discoveryOn ? "on" : "off"))
                row("ownSession", text("unavailable"))
                if composition.status.pausedForLackOfToken { Text(text("noTokenPause")) }
                if composition.status.storageUnavailable { Text(text("storageUnavailable")) }
                DiagnosticsParticipationControl(composition: composition, isLoading: isLoading, perform: perform)
                if account.state.isSignedIn {
                    Button(text("signOut")) {
                        perform {
                            try? await account.signOut()
                        }
                    }.disabled(isLoading)
                }
                if account.sessionCleanupFailed { Text(text("signOutFailed")) }
            }
            Section {
                Picker(text("approach"), selection: Binding(
                    get: { composition.presenceApproach == .secondExchange },
                    set: { second in
                        perform { await composition.selectPresenceApproach(second ? .secondExchange : .heldConnection) }
                    })) {
                        Text(text("held")).tag(false)
                        Text(text("second")).tag(true)
                    }
                    .pickerStyle(.inline)
                    .accessibilityLabel(text("approach"))
                    .disabled(isLoading)
                Button(text("reset")) {
                    perform { resetResult = await composition.resetTrial() }
                }
                .accessibilityLabel(text("reset"))
                .disabled(isLoading)
                if let resetResult {
                    Text(text(resetResult ? "resetConfirmed" : "resetFailed"))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            if isLoading || log.state == .loading {
                ProgressView(text("loading"))
            }
            if log.state == .failed || composition.status.storageUnavailable {
                Section {
                    Text(text("localError"))
                    Button(text("retry")) {
                        perform {
                            await composition.retryDiagnostics()
                        }
                    }
                    .accessibilityLabel(text("retry"))
                    .disabled(isLoading)
                }
            }
            Section(text("elapsed")) {
                if let trial = log.records.last(where: { $0.isOpen }) {
                    measurements(trial)
                } else { Text(text("empty")) }
            }
            Section(text("trials")) {
                if log.records.isEmpty { Text(text("empty")) }
                ForEach(Array(log.records.reversed())) { trial in
                    DisclosureGroup("\(trial.creationDate) · \(text("ordinal")) \(trial.ordinal) · \(startReason(trial.startReason))") {
                        row("build", text(trial.metadata.buildKind == "Development" ? "development" : "internal"))
                        row("app", "\(trial.metadata.appVersion) (\(trial.metadata.appBuild))")
                        row("ios", trial.metadata.iOSVersion)
                        row("device", trial.metadata.deviceModel)
                        row("approach", text(trial.metadata.presenceApproach == "secondExchange" ? "second" : "held"))
                        row("participation", text(trial.metadata.participationEnabled ? "on" : "off"))
                        row("bluetooth", text(trial.metadata.bluetoothAvailability))
                        row("battery", trial.metadata.batteryLevel.map { "\(Int($0 * 100))%" } ?? text("unavailable"))
                        measurements(trial)
                    }
                }
            }
            Section(text("summary")) {
                row("pendingReceipts", composition.status.pendingReceiptCount.map(String.init) ?? text("unavailable"))
                row("validToken", text(composition.status.validTokenAvailable ? "available" : "unavailable"))
                row("trials", String(log.records.count))
                Button(text("refresh")) {
                    perform {
                        log.prune()
                        await composition.refresh()
                        await composition.refreshLocalSummary()
                    }
                }
                .accessibilityLabel(text("refresh"))
                .disabled(isLoading)
                ShareLink(item: log.fileURL) { Text(text("share")) }
                    .accessibilityLabel(text("share"))
                    .simultaneousGesture(TapGesture().onEnded { resetResult = nil })
                    .disabled(log.state != .ready || isLoading)
            }
            Section {
                Toggle(text("demo"), isOn: Binding(
                    get: { demo.isEnabled },
                    set: { resetResult = nil; demo.isEnabled = $0 }))
                    .accessibilityLabel(text("demo"))
                    .disabled(isLoading)
                if demo.isEnabled { Text(text("demoWarning")) }
            }
        }
        .navigationTitle(text("title"))
        .task {
            isLoading = true
            await composition.refreshLocalSummary()
            isLoading = false
        }
    }

    @ViewBuilder
    private func measurements(_ trial: TrialRecord) -> some View {
        row("ordinal", String(trial.ordinal))
        row("startReason", startReason(trial.startReason))
        if trial.presenceApproachChanged { Text(text("approachChanged")) }
        row("discoveryElapsed", trial.discoveryElapsedSeconds.map(seconds) ?? state(trial.discoveryState))
        row("peers", String(trial.distinctPeerCount))
        row("droppedExchangeCount", String(trial.droppedExchangeCount))
        row("droppedEvidenceCount", String(trial.droppedEvidenceCount))
        if trial.exchanges.isEmpty { row("exchangeElapsed", state(trial.exchangeState)) }
        ForEach(Array(trial.exchanges.enumerated()), id: \.offset) { _, exchange in
            VStack(alignment: .leading) {
                row("exchangeElapsed", seconds(exchange.elapsedSeconds))
                row("role", text(exchange.role.rawValue))
                row("digest", exchange.exchangeDigest)
                if trial.evidenceState(for: exchange) != .recorded {
                    row("evidenceElapsed", state(trial.evidenceState(for: exchange)))
                }
            }
        }
        if trial.evidence.isEmpty { row("evidenceElapsed", state(trial.evidenceState)) }
        ForEach(Array(trial.evidence.enumerated()), id: \.offset) { _, evidence in
            VStack(alignment: .leading) {
                row("evidenceElapsed", seconds(evidence.elapsedSeconds))
                row("role", text(evidence.role.rawValue))
                row("digest", evidence.exchangeDigest)
                row("observedDuration", seconds(evidence.observedDurationSeconds))
                Text(text("localEvidenceOnly"))
                    .font(.footnote)
            }
        }
        row("serverElapsed", state(trial.serverConfirmation))
        ForEach(Array(trial.attemptEnds.enumerated()), id: \.offset) { _, end in
            row("attemptEnd", "\(text(end.role.rawValue)) · \(text(end.reason == "reset" ? "attemptReset" : end.reason)) · \(seconds(end.elapsedSeconds))")
        }
    }

    private func startReason(_ reason: TrialStartReason) -> String {
        switch reason {
        case .reset: text("startReset")
        case .participationSwitch: text("startParticipationSwitch")
        case .launch: text("startLaunch")
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text(key)).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
        }
        .accessibilityElement(children: .combine)
    }
    private func text(_ key: String) -> String { DiagnosticsStrings.text(key) }
    private func seconds(_ value: TimeInterval) -> String { String(format: "%.3f s", value) }
    private func state(_ value: TrialMeasurementState) -> String { text(value.rawValue) }
    private func availability(_ value: RadioAvailability) -> String { text(String(describing: value)) }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        resetResult = nil
        isLoading = true
        Task {
            await action()
            isLoading = false
        }
    }
}

@MainActor
struct DiagnosticsParticipationControl: View {
    @ObservedObject var composition: AppComposition
    let isLoading: Bool
    let perform: @MainActor (@escaping @MainActor () async -> Void) -> Void

    var participation: Binding<Bool> {
        Binding(get: { composition.isParticipating }, set: { enabled in
            perform { await composition.setParticipation(enabled) }
        })
    }

    var body: some View {
        Toggle(DiagnosticsStrings.text("discovery"), isOn: participation)
            .accessibilityLabel(DiagnosticsStrings.text("discovery"))
            .disabled(isLoading)
    }
}
#endif
