import Foundation
import CoreBluetooth
import EncounterDomain

/// Confines both radios to one queue and leaves exchange policy to the engine.
public final class CoreBluetoothTransport: NSObject, BluetoothTransport, @unchecked Sendable {
    public let events: AsyncStream<BluetoothEvent>
    private let eventDelivery: EventDelivery
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
    private var publication = Publication()
    private var publicationRearm: DispatchWorkItem?
    private var restoredCentral: [BluetoothConnection]?
    private var restoredPeripheral: [BluetoothConnection]?
    // Registry and observation/throttle tables each contain at most 256 peers.
    private var registry: [PeerHandle: CBPeripheral] = [:]
    private var observations = ObservationRegistry(capacity: RadioAdmission.centralLimit)
    private var centralLinks = CentralLinks()
    private var peripheralLinks = PeripheralLinks()
    private var snapshots = ReadSnapshots()
    // Central links (including reducer states) plus cancellations: at most 256.
    private var links: [PeerHandle: CentralLink] = [:]
    // Keep canceled objects until their terminal callback, so a late callback
    // cannot be mistaken for a subsequent attempt on the same peripheral.
    private var cancellations: [PeerHandle: CBPeripheral] = [:]
    // One pending read and write per admitted peripheral: at most 16 each.
    private var pendingReads: [BluetoothRequestID: CBATTRequest] = [:]
    private var pendingWrites: [BluetoothRequestID: CBATTRequest] = [:]
    private var writeRequests = PeripheralRequests()
    private var nextRequest: UInt64 = 0

    private struct CentralLink {
        let peripheral: CBPeripheral
        var readToken: CBCharacteristic?
        var writeToken: CBCharacteristic?
        var readRequest: BluetoothRequestID?
        var writeRequest: BluetoothRequestID?
    }

    /// Uses distinct restoration identities and buffers delegate events for the engine.
    public init(centralRestorationIdentifier: String = "EncounterBluetooth.central.v1",
                peripheralRestorationIdentifier: String = "EncounterBluetooth.peripheral.v1") {
        precondition(centralRestorationIdentifier != peripheralRestorationIdentifier)
        let delivery = EventDelivery(queue: queue)
        eventDelivery = delivery
        events = AsyncStream(unfolding: { await delivery.next() }, onCancel: { delivery.finish(cancelled: true) })
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

    deinit {
        publicationRearm?.cancel()
        eventDelivery.finish()
    }

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
    private func emit(_ event: BluetoothEvent) { eventDelivery.append(event) }
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
            applyPublication(publication.request(true))
            updateAvailability()
            applyDiscovery()
        case .stopDiscovery:
            discoveryRequested = false
            applyPublication(publication.request(false))
            applyDiscovery()
        case .connect(let peer):
            if cancellations[peer]?.state == .disconnected {
                cancellations.removeValue(forKey: peer)
                _ = centralLinks.end(peer)
            }
            guard centralManager.state == .poweredOn, links[peer] == nil,
                  cancellations[peer] == nil,
                  RadioAdmission.canTrackCentral(links: links.count, cancellations: cancellations.count),
                  let peripheral = registry[peer] else {
                emit(.connectFailed(peer)); return
            }
            links[peer] = CentralLink(peripheral: peripheral)
            centralLinks.begin(peer)
            peripheral.delegate = self
            centralManager.connect(peripheral)
        case .read(let peer, let id):
            guard var link = links[peer], centralLinks.state(peer) == .ready, link.readRequest == nil,
                  let characteristic = link.readToken, centralManager.state == .poweredOn else {
                emit(.readFailed(peer, id)); return
            }
            link.readRequest = id
            links[peer] = link
            link.peripheral.readValue(for: characteristic)
        case .write(let peer, let id, let frame):
            guard var link = links[peer], centralLinks.state(peer) == .ready, link.writeRequest == nil,
                  let characteristic = link.writeToken, centralManager.state == .poweredOn,
                  frame.count <= EncounterProtocol.maximumFrameByteCount else {
                emit(.writeFailed(peer, id)); return
            }
            link.writeRequest = id
            links[peer] = link
            link.peripheral.writeValue(frame, for: characteristic, type: .withResponse)
        case .disconnect(let connection):
            if connection.role == .central {
                emit(centralLinks.disconnect(connection.peer))
                cancelLink(connection.peer)
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
            _ = writeRequests.finish(peer, request: id)
            peripheralManager.respond(to: request, withResult:
                success && peripheralLinks.acceptsRequests(peer) ? .success : .writeNotPermitted)
        }
    }

    private func applyDiscovery() {
        if discoveryRequested == false {
            if centralManager.state == .poweredOn { centralManager.stopScan() }
        } else if discoveryRequested == true, centralManager.state == .poweredOn, !centralManager.isScanning {
            startScan()
        }
    }

    private func applyPublication(_ actions: [Publication.Action]) {
        for action in actions {
            switch action {
            case .remove:
                removePeripheralLinks()
                peripheralManager.removeAllServices()
                service = nil
            case .add:
                let service = CBMutableService(type: serviceUUID, primary: true)
                service.characteristics = [
                    CBMutableCharacteristic(type: peripheralTokenUUID, properties: [.read, .notify],
                                            value: nil, permissions: [.readable]),
                    CBMutableCharacteristic(type: centralTokenUUID, properties: [.write],
                                            value: nil, permissions: [.writeable])
                ]
                self.service = service
                peripheralManager.add(service)
            case .startAdvertising:
                peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
            case .stopAdvertising:
                peripheralManager.stopAdvertising()
            case .unavailable:
                updateAvailability()
            case .scheduleRearm(let delay):
                publicationRearm?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    checkQueue()
                    publicationRearm = nil
                    applyPublication(publication.rearm())
                    updateAvailability()
                }
                publicationRearm = work
                queue.asyncAfter(deadline: .now() + delay, execute: work)
            case .cancelRearm:
                publicationRearm?.cancel()
                publicationRearm = nil
            }
        }
    }

    private func removePeripheralLinks(respond: Bool = true) {
        for peer in peripheralLinks.removeService() {
            emit(.disconnected(.init(peer: peer, role: .peripheral)))
        }
        // Include requests from logically closed links as well.
        for request in pendingReads.values {
            if respond { peripheralManager.respond(to: request, withResult: .readNotPermitted) }
        }
        for request in pendingWrites.values {
            if respond { peripheralManager.respond(to: request, withResult: .writeNotPermitted) }
        }
        snapshots = ReadSnapshots()
        pendingReads.removeAll()
        pendingWrites.removeAll()
        writeRequests = PeripheralRequests()
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
        if let event = centralLinks.end(peer) { emit(event) }
        restartScan()
    }

    private func dropPeripheralRequests(_ peer: PeerHandle, respond: Bool = true) {
        snapshots.drop(peer)
        writeRequests.drop(peer)
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
        radio.peripheral = publication.unavailable ? .unavailable : managerState(peripheralManager.state)
        guard let availability = radio.update() else { return }
        emit(.availabilityChanged(availability))
        if availability != .available {
            // Preserve restoration until that manager can process the engine's close.
            if centralManager.state != .unknown || restoredCentral == nil { endCentralLinks() }
            if peripheralManager.state != .unknown || restoredPeripheral == nil {
                removePeripheralLinks(respond: peripheralManager.state == .poweredOn)
            }
        }
    }

    private func endCentralLinks() {
        for peer in Array(links.keys) {
            cancelLink(peer)
            if let event = centralLinks.end(peer) { emit(event) }
        }
        centralLinks = CentralLinks()
        if centralManager.state != .poweredOn { cancellations.removeAll() }
        registry.removeAll()
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
        if central.state == .poweredOn, let restored = restoredCentral {
            restoredCentral = nil
            emit(.restored(restored.filter { links[$0.peer] != nil }))
        }
        updateAvailability()
        if central.state != .poweredOn, !(central.state == .unknown && restoredCentral != nil) {
            endCentralLinks()
        }
        applyDiscovery()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        checkQueue()
        guard discoveryRequested == true, central.state == .poweredOn else { return }
        let peer = peer(peripheral.identifier)
        guard let observation = observations.observe(peer, now: ProcessInfo.processInfo.systemUptime,
                                                     backlogCount: eventDelivery.count) else { return }
        if let evicted = observation.evicted { registry.removeValue(forKey: evicted) }
        registry[peer] = peripheral
        if observation.shouldEmit { emit(.peerObserved(peer)) }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        guard let link = links[peer], link.peripheral === peripheral,
              centralLinks.state(peer) == .pending else {
            if links[peer] == nil,
               cancellations[peer] != nil || RadioAdmission.canTrackCentral(links: links.count, cancellations: cancellations.count) {
                cancellations[peer] = peripheral
            }
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        if cancellations[peer] === peripheral {
            cancellations.removeValue(forKey: peer)
            _ = centralLinks.end(peer)
            return
        }
        guard let link = links[peer], link.peripheral === peripheral else { return }
        links.removeValue(forKey: peer)
        failOperations(peer, link)
        if let event = centralLinks.end(peer) { emit(event) }
        restartScan()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        if cancellations[peer] === peripheral {
            cancellations.removeValue(forKey: peer)
            _ = centralLinks.end(peer)
            restartScan()
            return
        }
        guard let link = links[peer], link.peripheral === peripheral else { return }
        links.removeValue(forKey: peer)
        failOperations(peer, link)
        if let event = centralLinks.end(peer) { emit(event) }
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
            guard RadioAdmission.canTrackCentral(links: links.count, cancellations: cancellations.count) else {
                central.cancelPeripheralConnection(peripheral)
                continue
            }
            var link = CentralLink(peripheral: peripheral)
            let characteristics = peripheral.services?.first { $0.uuid == serviceUUID }?.characteristics ?? []
            link.readToken = characteristics.first { $0.uuid == peripheralTokenUUID }
            link.writeToken = characteristics.first { $0.uuid == centralTokenUUID }
            links[peer] = link
            centralLinks.begin(peer, ready: true)
            restored.append(.init(peer: peer, role: .central))
        }
        restoredCentral = restored
    }
    #endif
}

extension CoreBluetoothTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        guard let link = links[peer], link.peripheral === peripheral, centralLinks.state(peer) == .pending else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            failConnect(peer); return
        }
        peripheral.discoverCharacteristics([peripheralTokenUUID, centralTokenUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: (any Error)?) {
        checkQueue()
        let peer = peer(peripheral.identifier)
        guard var link = links[peer], link.peripheral === peripheral, centralLinks.state(peer) == .pending else { return }
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
        guard let link = links[peer], link.peripheral === peripheral, link.readToken === characteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            if centralLinks.state(peer) == .ready {
                cancelLink(peer)
                if let event = centralLinks.end(peer) { emit(event) }
                restartScan()
            } else { failConnect(peer) }
            return
        }
        if let event = centralLinks.ready(peer) { emit(event) }
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
        if centralLinks.state(peer) == .ready {
            cancelLink(peer)
            if let event = centralLinks.end(peer) { emit(event) }
            restartScan()
        } else { failConnect(peer) }
    }
}

extension CoreBluetoothTransport: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        checkQueue()
        let state: Publication.Radio
        switch peripheral.state {
        case .poweredOn: state = .poweredOn
        case .poweredOff: state = .poweredOff
        default: state = .databaseCleared
        }
        let awaitingRestoration = peripheral.state == .unknown && restoredPeripheral != nil
        let actions = awaitingRestoration ? [] : publication.update(state, isAdvertising: peripheral.isAdvertising)
        if peripheral.state == .poweredOn, let restored = restoredPeripheral {
            restoredPeripheral = nil
            emit(.restored(restored.filter { peripheralLinks.acceptsRequests($0.peer) }))
        }
        if state == .databaseCleared, !awaitingRestoration { service = nil }
        updateAvailability()
        if peripheral.state != .poweredOn, !awaitingRestoration {
            removePeripheralLinks(respond: false)
        }
        applyPublication(actions)
        applyDiscovery()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService,
                                  error: (any Error)?) {
        checkQueue()
        applyPublication(publication.didAdd(matchesUUID: service.uuid == serviceUUID, success: error == nil))
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        checkQueue()
        applyPublication(publication.didStartAdvertising(success: error == nil))
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        checkQueue()
        guard peripheral.state == .poweredOn, characteristic.uuid == peripheralTokenUUID,
              publication.published, discoveryRequested != false,
              service?.characteristics?.contains(where: { $0 === characteristic }) == true else { return }
        let peer = peer(central.identifier)
        if peripheralLinks.subscribe(peer, backlogCount: eventDelivery.count) {
            emit(.connected(.init(peer: peer, role: .peripheral)))
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        checkQueue()
        guard characteristic.uuid == peripheralTokenUUID,
              service?.characteristics?.contains(where: { $0 === characteristic }) == true else { return }
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
            let id = requestID()
            // Refuse another request until the engine answers the admitted one.
            guard snapshots.begin(peer, request: id) else {
                peripheral.respond(to: request, withResult: .unlikelyError); return
            }
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
        do {
            try WriteAssembler.validateBatch(requests, value: { $0.value })
        } catch {
            let result: CBATTError.Code = (error as? WriteAssemblyError) == .missingValue
                ? .unlikelyError : .invalidAttributeValueLength
            peripheral.respond(to: first, withResult: result); return
        }
        let peer = peer(first.central.identifier)
        guard peripheralLinks.acceptsRequests(peer), !writeRequests.contains(peer),
              requests.allSatisfy({ $0.central.identifier == first.central.identifier }) else {
            peripheral.respond(to: first, withResult: .writeNotPermitted); return
        }
        let fragments = requests.map {
            WriteFragment(characteristic: $0.characteristic.uuid.uuidString, offset: $0.offset, value: $0.value)
        }
        do {
            let frame = try WriteAssembler.assemble(fragments)
            let id = requestID()
            guard writeRequests.begin(peer, request: id) else {
                peripheral.respond(to: first, withResult: .writeNotPermitted); return
            }
            pendingWrites[id] = first
            emit(.incomingWrite(peer, id, frame))
        } catch {
            let result: CBATTError.Code
            switch error as? WriteAssemblyError {
            case .gap, .overlap: result = .invalidOffset
            case .overflow, .emptyValue, .tooManyFragments: result = .invalidAttributeValueLength
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
            publication.restorePublished()
            for characteristic in service.characteristics ?? [] where characteristic.uuid == peripheralTokenUUID {
                for central in (characteristic as? CBMutableCharacteristic)?.subscribedCentrals ?? [] {
                    let peer = peer(central.identifier)
                    if peripheralLinks.subscribe(peer, backlogCount: eventDelivery.count) {
                        restored.append(.init(peer: peer, role: .peripheral))
                    }
                }
            }
        }
        restoredPeripheral = restored
    }
    #endif
}
