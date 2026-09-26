import Foundation

enum RingConnectionState: Equatable, Sendable {
    case bluetoothUnavailable(String)
    case idle
    /// The user pressed Disconnect; nothing reconnects until they press Reconnect.
    case paused
    case scanning
    case connecting(String)
    case discovering
    case ready
    case reconnecting

    var label: String {
        switch self {
        case .bluetoothUnavailable(let reason): return reason
        case .idle: return String(localized: "Not connected")
        case .paused: return String(localized: "Paused")
        case .scanning: return String(localized: "Scanning…")
        case .connecting(let name): return String(localized: "Connecting to \(name)…")
        case .discovering: return String(localized: "Setting up…")
        case .ready: return String(localized: "Connected")
        case .reconnecting: return String(localized: "Reconnecting…")
        }
    }

    var isConnected: Bool { self == .ready }

    var isConnecting: Bool {
        switch self {
        case .connecting, .discovering, .reconnecting: return true
        default: return false
        }
    }
}

/// What the sync engine needs from a Bluetooth link. `RingBluetoothManager` is the real one;
/// tests use a fake, which is what makes the queue, timeout and scheduling logic testable.
@MainActor
protocol RingTransport: AnyObject {
    var delegate: (any RingTransportDelegate)? { get set }
    var state: RingConnectionState { get }
    /// True when the ring speaks the YC protocol (commands can be written).
    var hasProtocolChannel: Bool { get }
    var protocolName: String? { get }
    /// Identifies the connected ring, to notice when a different ring is paired.
    var connectedRingID: UUID? { get }
    /// Largest single write, in bytes, once connected.
    var maximumWriteLength: Int? { get }
    /// Demo mode: stop connecting without touching the user's pause or the remembered ring.
    var isSuspended: Bool { get set }

    func write(_ data: Data)
    /// Reconnects to the remembered ring, unless the user paused or demo mode suspended it.
    func connectSavedRing()
    /// Re-reads the standard Battery Level characteristic (rings without the YC protocol).
    func readBattery()
}

@MainActor
protocol RingTransportDelegate: AnyObject {
    func transportDidBecomeReady(_ transport: any RingTransport)
    func transportDidDisconnect(_ transport: any RingTransport)
    /// Raw YC notification bytes (from BE940001/BE940003 or the UART TX characteristic).
    func transport(_ transport: any RingTransport, didReceive data: Data)
    func transport(_ transport: any RingTransport, didReceiveHeartRate bpm: Int, rrIntervals: [Double])
    func transport(_ transport: any RingTransport, didReadBattery percent: Int)
}
