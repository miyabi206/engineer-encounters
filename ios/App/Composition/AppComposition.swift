import Combine
import EncounterDomain

/// One composition root survives scene creation and keeps one runtime per process.
@MainActor
final class AppComposition: ObservableObject {
    static let shared = AppComposition()
    private let participation = ParticipationFlag()
    @Published private(set) var runtime: EncounterRuntime?
    @Published private(set) var isParticipating = false
    private var runtimeStatusSubscription: AnyCancellable?
    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    let trialLog: TrialLog
    let trialRecorder: TrialRecorder
    let demoSwitch = DemoSwitchSetting()
    private let approachSetting = PresenceApproachSetting()
    @Published private(set) var presenceApproach: PresenceApproach
    #endif

    private init() {
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        trialLog = TrialLog()
        trialRecorder = TrialRecorder(log: trialLog)
        presenceApproach = approachSetting.value
        #endif
        isParticipating = participation.isEnabled
        if participation.isEnabled {
            let runtime = makeRuntime()
            #if DEVELOPMENT_BUILD || INTERNAL_BUILD
            trialRecorder.beginIfNeeded(metadata: trialMetadata, reason: .launch)
            #endif
            Task {
                guard participation.isEnabled else { return }
                await runtime.start()
            }
        }
    }

    var status: EncounterRuntimeStatus { runtime?.status ?? EncounterRuntimeStatus() }

    func setParticipation(_ enabled: Bool) async {
        participation.isEnabled = enabled
        isParticipating = enabled
        if enabled {
            let runtime = makeRuntime()
            #if DEVELOPMENT_BUILD || INTERNAL_BUILD
            trialRecorder.beginIfNeeded(metadata: trialMetadata)
            #endif
            await runtime.start()
        } else {
            await runtime?.stop()
            #if DEVELOPMENT_BUILD || INTERNAL_BUILD
            trialRecorder.close()
            #endif
        }
    }

    func refresh() async {
        await runtime?.refresh()
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        trialLog.prune()
        #endif
    }
    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    func resetTrial() async -> Bool {
        var recorded = false
        let reset = await makeRuntime().resetTrial {
            recorded = self.trialRecorder.resetCompleted(success: true, metadata: self.trialMetadata)
        }
        return reset && recorded
    }
    func selectPresenceApproach(_ approach: PresenceApproach) async {
        trialRecorder.selectPresenceApproach(approach)
        approachSetting.value = approach
        presenceApproach = approach
        await runtime?.selectPresenceApproach(approach)
    }

    func retryDiagnostics() async {
        if trialLog.state == .failed { trialLog.retry() }
        if isParticipating {
            trialRecorder.beginIfNeeded(metadata: trialMetadata, reason: .launch)
            await makeRuntime().start()
        } else { await makeRuntime().refreshLocalSummary() }
    }
    #endif

    func refreshLocalSummary() async { await makeRuntime().refreshLocalSummary() }

    private func makeRuntime() -> EncounterRuntime {
        if let runtime { return runtime }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        let runtime = EncounterRuntime(approach: presenceApproach)
        let recorder = trialRecorder
        runtime.observeEvents { event in recorder.record(event) }
        #else
        let runtime = EncounterRuntime()
        #endif
        self.runtime = runtime
        runtimeStatusSubscription = runtime.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return runtime
    }

    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    var trialMetadata: TrialMetadata {
        TrialMetadata.capture(approach: presenceApproach, participation: isParticipating,
                              availability: status.radioAvailability)
    }
    #endif
}
