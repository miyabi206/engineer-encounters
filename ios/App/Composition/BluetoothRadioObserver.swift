import CoreBluetooth
import EncounterDomain
import Foundation

/// A status side channel does not consume or buffer the adapter's delegate stream.
@MainActor
protocol RuntimeBluetoothStateReporting {
    func observeRadioState(_ receive: @escaping @MainActor (RadioAvailability, Bool) -> Void)
}

@MainActor
final class BluetoothRadioObserver: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private let receive: @MainActor (RadioAvailability, Bool) -> Void

    init(receive: @escaping @MainActor (RadioAvailability, Bool) -> Void) {
        self.receive = receive
        super.init()
        // Only after an explicit request or persisted participation consent.
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let rawState = central.state.rawValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = CBManagerState(rawValue: rawState) ?? .unknown
            self.receive(Self.availability(state), state == .poweredOff)
        }
    }

    static func availability(_ state: CBManagerState) -> RadioAvailability {
        switch state {
        case .poweredOn: .available
        case .unauthorized: .unauthorized
        case .unknown, .resetting: .unknown
        default: .unavailable
        }
    }
}
