import EncounterUI
import SwiftUI

@main
struct EngineerEncountersApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let composition: AppComposition

    init() {
        // This also runs on Bluetooth background relaunches without a visible scene.
        composition = AppComposition.shared
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                #if DEVELOPMENT_BUILD
                WelcomeView { DevelopmentDiagnosticsEntry(composition: composition) }
                #else
                WelcomeView()
                #endif
            }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await composition.refresh() }
                    }
                }
        }
    }
}
