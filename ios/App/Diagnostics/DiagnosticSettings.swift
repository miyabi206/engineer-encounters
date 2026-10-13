#if DEVELOPMENT_BUILD || INTERNAL_BUILD
import Combine
import Darwin
import EncounterDomain
import Foundation
import UIKit

@MainActor
final class DemoSwitchSetting: ObservableObject {
    private let defaults: UserDefaults
    private static let key = "diagnostics.immediateAmbientDemo"
    // Only the gated demo reveal consumer reads this; evidence rules never do.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.key) }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.key)
    }
}

@MainActor
struct PresenceApproachSetting {
    private let defaults: UserDefaults
    private let key = "diagnostics.presenceApproach"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var value: PresenceApproach {
        get { defaults.string(forKey: key) == "heldConnection" ? .heldConnection : .secondExchange }
        nonmutating set {
            defaults.set(newValue == .secondExchange ? "secondExchange" : "heldConnection", forKey: key)
        }
    }
}

extension TrialMetadata {
    @MainActor
    static func capture(approach: PresenceApproach, participation: Bool,
                        availability: RadioAvailability) -> TrialMetadata {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return TrialMetadata(buildKind: BuildKind.isDevelopment ? "Development" : "Internal",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
            iOSVersion: device.systemVersion, deviceModel: model,
            presenceApproach: approach == .secondExchange ? "secondExchange" : "heldConnection",
            participationEnabled: participation, bluetoothAvailability: String(describing: availability),
            batteryLevel: device.batteryLevel >= 0 ? device.batteryLevel : nil)
    }
}
#endif
