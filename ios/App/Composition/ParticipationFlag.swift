import Foundation

@MainActor
struct ParticipationFlag {
    private let defaults: UserDefaults
    private let key = "encounter.localParticipation"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: key) }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }
}
