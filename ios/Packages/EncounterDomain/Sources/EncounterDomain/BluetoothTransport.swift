import Foundation

/// A provisional local handle, never a name or permanent device identifier.
public struct PeerHandle: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Correlates a single radio operation or incoming request with its response.
public struct BluetoothRequestID: Hashable, Sendable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
}

/// Portable availability states, independent of framework manager objects.
public enum RadioAvailability: Sendable, Equatable { case unknown, available, unavailable, unauthorized }

/// Distinguishes the two independent reciprocal connections to a provisional peer.
public struct BluetoothConnection: Hashable, Sendable {
    public let peer: PeerHandle
    public let role: ExchangeRole
    public init(peer: PeerHandle, role: ExchangeRole) { self.peer = peer; self.role = role }
}

/// A fragmented read must serve this immutable snapshot only before validUntil.
public struct BluetoothReadSnapshot: Sendable, Equatable {
    public let frame: Data
    public let validUntil: Date
    public init(frame: Data, validUntil: Date) { self.frame = frame; self.validUntil = validUntil }
}

/// Radio primitives only; exchange and presence policy belong to the engine.
public enum BluetoothCommand: Sendable, Equatable {
    case startDiscovery
    case stopDiscovery
    case connect(PeerHandle)
    case read(PeerHandle, BluetoothRequestID)
    case write(PeerHandle, BluetoothRequestID, Data)
    case disconnect(BluetoothConnection)
    case answerRead(PeerHandle, BluetoothRequestID, BluetoothReadSnapshot?)
    case answerWrite(PeerHandle, BluetoothRequestID, success: Bool)
}

/// One ordered delegate stream; complete Data frames are assembled by the adapter.
public enum BluetoothEvent: Sendable, Equatable {
    case availabilityChanged(RadioAvailability)
    case peerObserved(PeerHandle)
    case connected(BluetoothConnection)
    case connectFailed(PeerHandle)
    case frameRead(PeerHandle, BluetoothRequestID, Data)
    case readFailed(PeerHandle, BluetoothRequestID)
    case writeAcknowledged(PeerHandle, BluetoothRequestID)
    case writeFailed(PeerHandle, BluetoothRequestID)
    case disconnected(BluetoothConnection)
    case incomingRead(PeerHandle, BluetoothRequestID)
    case incomingWrite(PeerHandle, BluetoothRequestID, Data)
    case restored([BluetoothConnection])
}

/// Hides every Core Bluetooth call behind commands and one ordered event stream.
public protocol BluetoothTransport: Sendable {
    /// A single engine consumes this ordered stream for the transport's lifetime.
    var events: AsyncStream<BluetoothEvent> { get }
    /// Dispatches a primitive; outcomes arrive through events, never through return values.
    func execute(_ command: BluetoothCommand) async
}
