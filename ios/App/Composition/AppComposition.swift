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
            trialRecorder.beginIfNeeded(metadata: trialMetadata)
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
    func resetTrial() async -> Bool {
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        var recorded = false
        let reset = await makeRuntime().resetTrial {
            recorded = self.trialRecorder.resetCompleted(success: true, metadata: self.trialMetadata)
        }
        return reset && recorded
        #else
        return await makeRuntime().resetTrial()
        #endif
    }
    func selectPresenceApproach(_ approach: PresenceApproach) async {
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        approachSetting.value = approach
        presenceApproach = approach
        #endif
        await runtime?.selectPresenceApproach(approach)
    }

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
