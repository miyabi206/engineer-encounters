import EncounterUI
import SwiftUI

@main
@MainActor
struct EngineerEncountersApp: App {
    private let composition: AppComposition

    init() {
        // This also runs on Bluetooth background relaunches without a visible scene.
        composition = AppComposition.shared
    }

    var body: some Scene {
        WindowGroup {
            AccountRootView(composition: composition)
        }
    }
}
