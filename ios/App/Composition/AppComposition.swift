import Combine
import EncounterDomain

/// One composition root survives scene creation and keeps one runtime per process.
@MainActor
final class AppComposition: ObservableObject {
    static let shared = AppComposition()
    private let participation = ParticipationFlag()
    @Published private(set) var runtime: EncounterRuntime?

    private init() {
        if participation.isEnabled {
            let runtime = EncounterRuntime()
            self.runtime = runtime
            Task {
                guard participation.isEnabled else { return }
                await runtime.start()
            }
        }
    }

    var isParticipating: Bool { participation.isEnabled }
    var status: EncounterRuntimeStatus { runtime?.status ?? EncounterRuntimeStatus() }

    // The later diagnostics UI calls this; S01 exposes no participation control.
    func setParticipation(_ enabled: Bool) async {
        participation.isEnabled = enabled
        if enabled {
            if runtime == nil { runtime = EncounterRuntime() }
            await runtime?.start()
        } else {
            await runtime?.stop()
        }
    }

    func refresh() async { await runtime?.refresh() }
    func resetTrial() async -> Bool { await runtime?.resetTrial() ?? false }
    func selectPresenceApproach(_ approach: PresenceApproach) async {
        await runtime?.selectPresenceApproach(approach)
    }
}
