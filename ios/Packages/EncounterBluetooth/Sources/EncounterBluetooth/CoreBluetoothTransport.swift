import Foundation
import CoreBluetooth
import EncounterDomain

/// Confines both radios to one queue and leaves exchange policy to the engine.
public final class CoreBluetoothTransport: NSObject, BluetoothTransport, @unchecked Sendable {
    public let events: AsyncStream<BluetoothEvent>
    private let continuation: AsyncStream<BluetoothEvent>.Continuation
    private let queue = DispatchQueue(label: "EncounterBluetooth.radio")
    private let serviceUUID = CBUUID(string: EncounterProtocol.serviceUUID)
    private let peripheralTokenUUID = CBUUID(string: EncounterProtocol.peripheralTokenCharacteristicUUID)
    private let centralTokenUUID = CBUUID(string: EncounterProtocol.centralTokenCharacteristicUUID)

    // @unchecked Sendable is justified by confinement: every mutable field below
    // is touched only on queue, including initialization and delegate callbacks.
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var radio = CombinedRadio()
    // nil leaves system-restored discovery alone until an engine command arrives.
    private var discoveryRequested: Bool?
    private var service: CBMutableService?
    private var publicationPending = false
    private var servicePublished = false
    private var advertisingPending = false
    private var registry: [PeerHandle: CBPeripheral] = [:]
    private var observations = ObservationRegistry(capacity: 256)
    private var centralLinks = CentralLinks()
    private var peripheralLinks = PeripheralLinks()
    private var snapshots = ReadSnapshots()
    private var links: [PeerHandle: CentralLink] = [:]
    // Keep canceled objects until their terminal callback, so a late callback
    // cannot be mistaken for a subsequent attempt on the same peripheral.
    private var cancellations: [PeerHandle: CBPeripheral] = [:]
    private var pendingReads: [BluetoothRequestID: CBATTRequest] = [:]
    private var pendingWrites: [BluetoothRequestID: CBATTRequest] = [:]
    private var nextRequest: UInt64 = 0

    private struct CentralLink {
        let peripheral: CBPeripheral
        var ready = false
        var readToken: CBCharacteristic?
        var writeToken: CBCharacteristic?
        var readRequest: BluetoothRequestID?
        var writeRequest: BluetoothRequestID?
    }

    /// Uses distinct restoration identities and buffers delegate events for the engine.
    public init(centralRestorationIdentifier: String = "EncounterBluetooth.central.v1",
                peripheralRestorationIdentifier: String = "EncounterBluetooth.peripheral.v1") {
        precondition(centralRestorationIdentifier != peripheralRestorationIdentifier)
        let stream = AsyncStream<BluetoothEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        super.init()
        queue.async { [self] in
            var centralOptions: [String: Any] = [:]
            var peripheralOptions: [String: Any] = [:]
            #if os(iOS)
            centralOptions[CBCentralManagerOptionRestoreIdentifierKey] = centralRestorationIdentifier
            peripheralOptions[CBPeripheralManagerOptionRestoreIdentifierKey] = peripheralRestorationIdentifier
            #endif
            centralManager = CBCentralManager(delegate: self, queue: queue, options: centralOptions)
            peripheralManager = CBPeripheralManager(delegate: self, queue: queue, options: peripheralOptions)
        }
    }

    deinit { continuation.finish() }

    /// Applies commands in the same serial order as the managers' callbacks.
    public func execute(_ command: BluetoothCommand) async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                handle(command)
                done.resume()
            }
        }
    }

    private func checkQueue() { dispatchPrecondition(condition: .onQueue(queue)) }
    private func emit(_ event: BluetoothEvent) { continuation.yield(event) }
    private func peer(_ identifier: UUID) -> PeerHandle { PeerHandle(id: identifier) }
    private func requestID() -> BluetoothRequestID {
        nextRequest &+= 1
        return BluetoothRequestID(nextRequest)
    }

    private func handle(_ command: BluetoothCommand) {
        checkQueue()
        switch command {
        case .startDiscovery:
            discoveryRequested = true
            applyDiscovery()
        case .stopDiscovery:
            discoveryRequested = false
            applyDiscovery()
        case .connect(let peer):
            guard centralManager.state == .poweredOn, links[peer] == nil,
                  cancellations[peer] == nil, let peripheral = registry[peer] else {
                emit(.connectFailed(peer)); return
            }
            links[peer] = CentralLink(peripheral: peripheral)
            centralLinks.begin(peer)
            peripheral.delegate = self
            centralManager.connect(peripheral)
        case .read(let peer, let id):
            guard var link = links[peer], link.ready, link.readRequest == nil,
                  let characteristic = link.readToken, centralManager.state == .poweredOn else {
                emit(.readFailed(peer, id)); return
            }
            link.readRequest = id
            links[peer] = link
            link.peripheral.readValue(for: characteristic)
        case .write(let peer, let id, let frame):
            guard var link = links[peer], link.ready, link.writeRequest == nil,
                  let characteristic = link.writeToken, centralManager.state == .poweredOn,
                  frame.count <= EncounterProtocol.maximumFrameByteCount else {
                emit(.writeFailed(peer, id)); return
            }
            link.writeRequest = id
            links[peer] = link
            link.peripheral.writeValue(frame, for: characteristic, type: .withResponse)
        case .disconnect(let connection):
            if connection.role == .central {
                cancelLink(connection.peer)
                emit(centralLinks.disconnect(connection.peer))
                restartScan()
            } else if peripheralLinks.close(connection.peer) {
                dropPeripheralRequests(connection.peer)
                emit(.disconnected(connection))
            }
        case .answerRead(let peer, let id, let snapshot):
            guard let request = pendingReads[id], self.peer(request.central.identifier) == peer else { return }
            pendingReads.removeValue(forKey: id)
            let frame = snapshots.answer(peer, request: id, snapshot: snapshot, now: Date())
            guard peripheralLinks.acceptsRequests(peer), let frame else {
                peripheralManager.respond(to: request, withResult: .readNotPermitted); return
            }
            request.value = frame
            peripheralManager.respond(to: request, withResult: .success)
        case .answerWrite(let peer, let id, let success):
            guard let request = pendingWrites[id], self.peer(request.central.identifier) == peer else { return }
            pendingWrites.removeValue(forKey: id)
            peripheralManager.respond(to: request, withResult:
                success && peripheralLinks.acceptsRequests(peer) ? .success : .writeNotPermitted)
        }
    }

    private func applyDiscovery() {
        if discoveryRequested == false {
            if centralManager.state == .poweredOn { centralManager.stopScan() }
            if peripheralManager.state == .poweredOn {
                peripheralManager.stopAdvertising()
                advertisingPending = false
                // An in-flight add is removed in didAdd rather than added twice.
                if let service, servicePublished {
                    peripheralManager.remove(service)
                    self.service = nil
                    servicePublished = false
                }
            }
            return
        }
        guard discoveryRequested == true else { return }
        if centralManager.state == .poweredOn, !centralManager.isScanning { startScan() }
        guard peripheralManager.state == .poweredOn else { return }
        if service == nil {
            let service = CBMutableService(type: serviceUUID, primary: true)
            service.characteristics = [
                CBMutableCharacteristic(type: peripheralTokenUUID, properties: [.read, .notify],
                                        value: nil, permissions: [.readable]),
                CBMutableCharacteristic(type: centralTokenUUID, properties: [.write],
                                        value: nil, permissions: [.writeable])
            ]
            self.service = service
            publicationPending = true
            peripheralManager.add(service)
        }
        if servicePublished, !advertisingPending, !peripheralManager.isAdvertising {
            advertisingPending = true
            peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
        }
    }

    private func startScan() {
        centralManager.scanForPeripherals(withServices: [serviceUUID],
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func restartScan() {
        guard discoveryRequested == true, centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        startScan()
    }

    private func cancelLink(_ peer: PeerHandle) {
        guard let link = links.removeValue(forKey: peer) else { return }
        failOperations(peer, link)
        if centralManager.state == .poweredOn {
            cancellations[peer] = link.peripheral
            centralManager.cancelPeripheralConnection(link.peripheral)
        }
    }

    private func failOperations(_ peer: PeerHandle, _ link: CentralLink) {
        if let id = link.readRequest { emit(.readFailed(peer, id)) }
        if let id = link.writeRequest { emit(.writeFailed(peer, id)) }
    }

    private func failConnect(_ peer: PeerHandle) {
        guard links[peer] != nil else { return }
        cancelLink(peer)
        _ = centralLinks.end(peer)
        emit(.connectFailed(peer))
        restartScan()
    }

    private func dropPeripheralRequests(_ peer: PeerHandle, respond: Bool = true) {
        snapshots.drop(peer)
        for (id, request) in pendingReads where self.peer(request.central.identifier) == peer {
            if respond { peripheralManager.respond(to: request, withResult: .readNotPermitted) }
            pendingReads.removeValue(forKey: id)
        }
        for (id, request) in pendingWrites where self.peer(request.central.identifier) == peer {
            if respond { peripheralManager.respond(to: request, withResult: .writeNotPermitted) }
            pendingWrites.removeValue(forKey: id)
        }
    }

    private func updateAvailability() {
        guard let availability = radio.update() else { return }
        emit(.availabilityChanged(availability))
        if availability != .available {
            // Managers may drop connections without issuing terminal callbacks.
            for (peer, link) in links {
                failOperations(peer, link)
                if centralLinks.end(peer) { emit(.disconnected(.init(peer: peer, role: .central))) }
            }
            links.removeAll()
            centralLinks = CentralLinks()
            cancellations.removeAll()
            registry.removeAll()
            for peer in peripheralLinks.openPeers {
                dropPeripheralRequests(peer, respond: peripheralManager.state == .poweredOn)
                emit(.disconnected(.init(peer: peer, role: .peripheral)))
            }
            peripheralLinks = PeripheralLinks()
            snapshots = ReadSnapshots()
            pendingReads.removeAll()
            pendingWrites.removeAll()
        }
    }

    private func managerState(_ state: CBManagerState) -> ManagerRadioState {
        switch state {
        case .poweredOn: .poweredOn
        case .unauthorized: .unauthorized
        case .unknown: .unknown
        case .poweredOff, .unsupported, .resetting: .unavailable
        @unknown default: .unavailable
        }
    }
}

extension CoreBluetoothTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        checkQueue()
        radio.central = managerState(central.state)
        updateAvailability()
        applyDiscovery()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        checkQueue()
        guard discoveryRequested == true, central.state == .poweredOn else { return }
        let peer = peer(peripheral.identifier)
        guard let observation = observations.observe(peer, now: ProcessInfo.processInfo.systemUptime) else { return }
        if let evicted = observation.evicted { registry.removeValue(forKey: evicted) }
        registry[peer] = peripheral
        if observation.shouldEmit { emit(.peerObserved(peer)) }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        guard let link = links[peer], link.peripheral === peripheral, !link.ready else { return }
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        if cancellations[peer] === peripheral {
            cancellations.removeValue(forKey: peer)
            return
        }
        guard let link = links[peer], link.peripheral === peripheral else { return }
        links.removeValue(forKey: peer)
        failOperations(peer, link)
        _ = centralLinks.end(peer)
        emit(.connectFailed(peer))
        restartScan()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        if cancellations[peer] === peripheral {
            cancellations.removeValue(forKey: peer)
            restartScan()
            return
        }
        guard let link = links[peer], link.peripheral === peripheral else { return }
        links.removeValue(forKey: peer)
        failOperations(peer, link)
        if !link.ready { emit(.connectFailed(peer)) }
        if centralLinks.end(peer) { emit(.disconnected(.init(peer: peer, role: .central))) }
        restartScan()
    }

    #if os(iOS)
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        checkQueue()
        central.delegate = self
        var restored: [BluetoothConnection] = []
        for peripheral in dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] {
            peripheral.delegate = self
            let peer = peer(peripheral.identifier)
            if let observation = observations.observe(peer, now: ProcessInfo.processInfo.systemUptime) {
                if let evicted = observation.evicted { registry.removeValue(forKey: evicted) }
                registry[peer] = peripheral
            }
            guard peripheral.state == .connected, links[peer] == nil else { continue }
            var link = CentralLink(peripheral: peripheral, ready: true)
            let characteristics = peripheral.services?.first { $0.uuid == serviceUUID }?.characteristics ?? []
            link.readToken = characteristics.first { $0.uuid == peripheralTokenUUID }
            link.writeToken = characteristics.first { $0.uuid == centralTokenUUID }
            links[peer] = link
            centralLinks.begin(peer)
            restored.append(.init(peer: peer, role: .central))
        }
        emit(.restored(restored))
    }
    #endif
}

extension CoreBluetoothTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        guard let link = links[peer], link.peripheral === peripheral, !link.ready else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            failConnect(peer); return
        }
        peripheral.discoverCharacteristics([peripheralTokenUUID, centralTokenUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        guard var link = links[peer], link.peripheral === peripheral, !link.ready else { return }
        guard error == nil, service.uuid == serviceUUID,
              let read = service.characteristics?.first(where: { $0.uuid == peripheralTokenUUID }),
              let write = service.characteristics?.first(where: { $0.uuid == centralTokenUUID }),
              read.properties.contains([.read, .notify]), write.properties.contains(.write) else {
            failConnect(peer); return
        }
        link.readToken = read
        link.writeToken = write
        links[peer] = link
        peripheral.setNotifyValue(true, for: read)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        guard var link = links[peer], link.peripheral === peripheral, link.readToken === characteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            if link.ready {
                cancelLink(peer)
                if centralLinks.end(peer) { emit(.disconnected(.init(peer: peer, role: .central))) }
                restartScan()
            } else { failConnect(peer) }
            return
        }
        guard !link.ready else { return }
        link.ready = true
        links[peer] = link
        emit(.connected(.init(peer: peer, role: .central)))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        guard var link = links[peer], link.peripheral === peripheral,
              link.readToken === characteristic, let id = link.readRequest else { return }
        link.readRequest = nil
        links[peer] = link
        if error == nil, let value = characteristic.value, value.count <= EncounterProtocol.maximumFrameByteCount {
            emit(.frameRead(peer, id, value))
        } else { emit(.readFailed(peer, id)) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        guard var link = links[peer], link.peripheral === peripheral,
              link.writeToken === characteristic, let id = link.writeRequest else { return }
        link.writeRequest = nil
        links[peer] = link
        emit(error == nil ? .writeAcknowledged(peer, id) : .writeFailed(peer, id))
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        checkQueue()
        guard invalidatedServices.contains(where: { $0.uuid == serviceUUID }) else { return }
        let peer = peer(peripheral.identifier)
        guard let link = links[peer], link.peripheral === peripheral else { return }
        if link.ready {
            cancelLink(peer)
            if centralLinks.end(peer) { emit(.disconnected(.init(peer: peer, role: .central))) }
            restartScan()
        } else { failConnect(peer) }
    }
}

extension CoreBluetoothTransport: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        checkQueue()
        radio.peripheral = managerState(peripheral.state)
        if peripheral.state != .poweredOn {
            service = nil
            publicationPending = false
            servicePublished = false
            advertisingPending = false
        }
        updateAvailability()
        applyDiscovery()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService,
                                  error: (any Error)?) {
        checkQueue()
        guard self.service === service, publicationPending else { return }
        publicationPending = false
        guard error == nil else { self.service = nil; servicePublished = false; return }
        servicePublished = true
        if discoveryRequested == true { applyDiscovery() }
        else {
            if let mutable = service as? CBMutableService { peripheral.remove(mutable) }
            self.service = nil
            servicePublished = false
        }
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        checkQueue()
        advertisingPending = false
        if discoveryRequested == false { peripheral.stopAdvertising() }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        checkQueue()
        guard characteristic.uuid == peripheralTokenUUID else { return }
        let peer = peer(central.identifier)
        if peripheralLinks.subscribe(peer) { emit(.connected(.init(peer: peer, role: .peripheral))) }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        checkQueue()
        guard characteristic.uuid == peripheralTokenUUID else { return }
        let peer = peer(central.identifier)
        dropPeripheralRequests(peer)
        if peripheralLinks.unsubscribe(peer) { emit(.disconnected(.init(peer: peer, role: .peripheral))) }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        checkQueue()
        let peer = peer(request.central.identifier)
        guard request.characteristic.uuid == peripheralTokenUUID, peripheralLinks.acceptsRequests(peer) else {
            peripheral.respond(to: request, withResult: .readNotPermitted); return
        }
        if request.offset == 0 {
            // Superseding a read also refuses its pending offset-zero request.
            for (id, old) in pendingReads where self.peer(old.central.identifier) == peer {
                peripheral.respond(to: old, withResult: .unlikelyError)
                pendingReads.removeValue(forKey: id)
            }
            let id = requestID()
            snapshots.begin(peer, request: id)
            pendingReads[id] = request
            emit(.incomingRead(peer, id))
        } else if let frame = snapshots.continuation(peer, offset: request.offset, now: Date()) {
            request.value = frame
            peripheral.respond(to: request, withResult: .success)
        } else { peripheral.respond(to: request, withResult: .invalidOffset) }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        checkQueue()
        guard let first = requests.first else { return }
        let peer = peer(first.central.identifier)
        guard peripheralLinks.acceptsRequests(peer), requests.allSatisfy({ $0.central.identifier == first.central.identifier }) else {
            peripheral.respond(to: first, withResult: .writeNotPermitted); return
        }
        let fragments = requests.map {
            WriteFragment(characteristic: $0.characteristic.uuid.uuidString, offset: $0.offset, value: $0.value)
        }
        do {
            let frame = try WriteAssembler.assemble(fragments)
            let id = requestID()
            pendingWrites[id] = first
            emit(.incomingWrite(peer, id, frame))
        } catch {
            let result: CBATTError.Code
            switch error as? WriteAssemblyError {
            case .gap, .overlap: result = .invalidOffset
            case .overflow: result = .invalidAttributeValueLength
            case .wrongCharacteristic: result = .writeNotPermitted
            default: result = .unlikelyError
            }
            peripheral.respond(to: first, withResult: result)
        }
    }

    #if os(iOS)
    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        checkQueue()
        peripheral.delegate = self
        var restored: [BluetoothConnection] = []
        for service in dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? [] {
            guard service.uuid == serviceUUID else { continue }
            self.service = service
            publicationPending = false
            servicePublished = true
            for characteristic in service.characteristics ?? [] where characteristic.uuid == peripheralTokenUUID {
                for central in (characteristic as? CBMutableCharacteristic)?.subscribedCentrals ?? [] {
                    let peer = peer(central.identifier)
                    if peripheralLinks.subscribe(peer) { restored.append(.init(peer: peer, role: .peripheral)) }
                }
            }
        }
        emit(.restored(restored))
    }
    #endif
}
