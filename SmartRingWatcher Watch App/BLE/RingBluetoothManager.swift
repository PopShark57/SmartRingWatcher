import CoreBluetooth
import Foundation

/// GATT identifiers. The YC service is what Smarthealth-compatible rings expose; the
/// Nordic UART service carries the same frames on some models; the standard Heart Rate,
/// Battery and Device Information services are used when present (any "generic" ring).
enum RingUUID {
    static let ycService = CBUUID(string: "BE940000-7333-BE46-B7AE-689E71722BD5")
    static let ycWrite = CBUUID(string: "BE940001-7333-BE46-B7AE-689E71722BD5")
    static let ycNotify = CBUUID(string: "BE940003-7333-BE46-B7AE-689E71722BD5")

    static let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let uartWrite = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let uartNotify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    static let heartRateService = CBUUID(string: "180D")
    static let heartRateMeasurement = CBUUID(string: "2A37")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    static let deviceInfoService = CBUUID(string: "180A")
    static let manufacturerName = CBUUID(string: "2A29")
    static let modelNumber = CBUUID(string: "2A24")
    static let firmwareRevision = CBUUID(string: "2A26")

    static let servicesOfInterest = [ycService, uartService, heartRateService, batteryService, deviceInfoService]
    /// Services commonly advertised by smart rings; used only to rank scan results.
    static let ringHints: Set<CBUUID> = [ycService, uartService, heartRateService, CBUUID(string: "FEE7")]
}

struct DiscoveredRing: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var looksLikeRing: Bool
}

enum RingConnectionState: Equatable {
    case bluetoothUnavailable(String)
    case idle
    case scanning
    case connecting(String)
    case discovering
    case ready
    case reconnecting

    var label: String {
        switch self {
        case .bluetoothUnavailable(let reason): return reason
        case .idle: return "Not connected"
        case .scanning: return "Scanning…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .discovering: return "Setting up…"
        case .ready: return "Connected"
        case .reconnecting: return "Reconnecting…"
        }
    }

    var isConnected: Bool { self == .ready }
}

protocol RingTransportDelegate: AnyObject {
    func transportDidBecomeReady(_ transport: RingBluetoothManager)
    func transportDidDisconnect(_ transport: RingBluetoothManager)
    /// Raw YC notification bytes (from BE940001/BE940003 or the UART TX characteristic).
    func transport(_ transport: RingBluetoothManager, didReceive data: Data)
    func transport(_ transport: RingBluetoothManager, didReceiveHeartRate bpm: Int, rrIntervals: [Double])
    func transport(_ transport: RingBluetoothManager, didReadBattery percent: Int)
}

/// CoreBluetooth central: scanning, connecting, auto-reconnect, service discovery,
/// subscriptions and a serialized write queue. All callbacks arrive on the main queue.
final class RingBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var state: RingConnectionState = .idle
    @Published private(set) var discovered: [DiscoveredRing] = []
    @Published private(set) var connectedName: String?
    /// "YC" when the Smarthealth protocol is available, "Standard GATT" otherwise.
    @Published private(set) var protocolName: String?
    @Published private(set) var gattInfo: [String: String] = [:]
    @Published private(set) var savedRingID: UUID?

    weak var delegate: RingTransportDelegate?

    private static let savedRingKey = "SavedRingIdentifier"
    private static let savedRingNameKey = "SavedRingName"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristics: Set<CBUUID> = []
    private var pendingServiceDiscoveries = 0
    private var writeQueue: [Data] = []
    private var awaitingWriteResponse = false
    private var scanStopTimer: Timer?
    private var readyFallbackTimer: Timer?
    private var autoConnect = true

    var hasProtocolChannel: Bool { writeCharacteristic != nil }
    var savedRingName: String? { UserDefaults.standard.string(forKey: Self.savedRingNameKey) }

    override init() {
        super.init()
        if let stored = UserDefaults.standard.string(forKey: Self.savedRingKey) {
            savedRingID = UUID(uuidString: stored)
        }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    func startScan(duration: TimeInterval = 20) {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        if !state.isConnected { state = .scanning }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanStopTimer?.invalidate()
        scanStopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    func stopScan() {
        scanStopTimer?.invalidate()
        scanStopTimer = nil
        if central.isScanning { central.stopScan() }
        if state == .scanning { state = .idle }
    }

    // MARK: - Connecting

    func connect(to ring: DiscoveredRing) {
        guard let target = peripheralsByID[ring.id] else { return }
        stopScan()
        if let current = peripheral, current.identifier != target.identifier {
            central.cancelPeripheralConnection(current)
        }
        UserDefaults.standard.set(target.identifier.uuidString, forKey: Self.savedRingKey)
        UserDefaults.standard.set(ring.name, forKey: Self.savedRingNameKey)
        savedRingID = target.identifier
        autoConnect = true
        connect(target, name: ring.name)
    }

    /// Reconnects to the remembered ring. A pending `connect` never times out in
    /// CoreBluetooth, so the ring is picked up as soon as it is in range again.
    func connectSavedRing() {
        guard central.state == .poweredOn, let id = savedRingID, !state.isConnected else { return }
        autoConnect = true
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known, name: known.name ?? savedRingName ?? "ring")
        } else {
            // Not known to the system yet: find it by scanning (see didDiscover).
            startScan()
        }
    }

    /// Disconnects and stops auto-reconnecting until `connectSavedRing()` is called again.
    /// `forget` also clears the remembered ring.
    func disconnect(forget: Bool) {
        autoConnect = false
        if forget {
            UserDefaults.standard.removeObject(forKey: Self.savedRingKey)
            UserDefaults.standard.removeObject(forKey: Self.savedRingNameKey)
            savedRingID = nil
        }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        if forget {
            // The disconnect callback will no longer see a ready connection, so notify now.
            if state == .ready { delegate?.transportDidDisconnect(self) }
            state = .idle
        }
    }

    private func connect(_ target: CBPeripheral, name: String) {
        peripheral = target
        peripheralsByID[target.identifier] = target
        target.delegate = self
        state = .connecting(name)
        central.connect(target, options: nil)
    }

    // MARK: - Writing

    func write(_ data: Data) {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        // Split anything longer than the negotiated ATT payload (the SDK does the same).
        let type = writeType(for: characteristic)
        let maxLength = max(20, peripheral.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < data.count {
            let end = min(offset + maxLength, data.count)
            writeQueue.append(data.subdata(in: offset..<end))
            offset = end
        }
        pumpWrites()
    }

    private func writeType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType {
        characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
    }

    private func pumpWrites() {
        guard let peripheral, let characteristic = writeCharacteristic, !awaitingWriteResponse,
              !writeQueue.isEmpty else { return }
        let type = writeType(for: characteristic)
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
        let chunk = writeQueue.removeFirst()
        peripheral.writeValue(chunk, for: characteristic, type: type)
        if type == .withResponse {
            awaitingWriteResponse = true
        } else {
            pumpWrites()
        }
    }

    // MARK: - Helpers

    private func resetConnectionState() {
        readyFallbackTimer?.invalidate()
        readyFallbackTimer = nil
        writeCharacteristic = nil
        notifyCharacteristics.removeAll()
        pendingServiceDiscoveries = 0
        writeQueue.removeAll()
        awaitingWriteResponse = false
        connectedName = nil
        protocolName = nil
    }

    private func markReadyIfPossible(force: Bool = false) {
        guard state == .discovering else { return }
        if !force {
            guard pendingServiceDiscoveries == 0 else { return }
            // With a protocol channel, wait until its indications are switched on.
            let protocolNotify: Set<CBUUID> = [RingUUID.ycWrite, RingUUID.ycNotify, RingUUID.uartNotify]
            if writeCharacteristic != nil && notifyCharacteristics.isDisjoint(with: protocolNotify) { return }
        }
        readyFallbackTimer?.invalidate()
        readyFallbackTimer = nil
        protocolName = writeCharacteristic == nil ? "Standard GATT" : "YC (Smarthealth)"
        state = .ready
        delegate?.transportDidBecomeReady(self)
    }

    private static func looksLikeRing(name: String, advertised: [CBUUID]) -> Bool {
        if advertised.contains(where: { RingUUID.ringHints.contains($0) }) { return true }
        let lower = name.lowercased()
        return lower.contains("ring") || lower.hasPrefix("r0") || lower.hasPrefix("r1")
            || lower.hasPrefix("r2") || lower.hasPrefix("r9") || lower.contains("smart")
    }
}

// MARK: - CBCentralManagerDelegate

extension RingBluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Connections are dropped when Bluetooth goes away, without a disconnect callback.
        if central.state != .poweredOn, state == .ready {
            resetConnectionState()
            delegate?.transportDidDisconnect(self)
        }
        switch central.state {
        case .poweredOn:
            if state != .ready { state = .idle }
            if autoConnect { connectSavedRing() }
        case .poweredOff:
            state = .bluetoothUnavailable("Bluetooth is off")
        case .unauthorized:
            state = .bluetoothUnavailable("Bluetooth permission denied")
        case .unsupported:
            state = .bluetoothUnavailable("Bluetooth LE unavailable")
        case .resetting, .unknown:
            state = .bluetoothUnavailable("Bluetooth starting…")
        @unknown default:
            state = .bluetoothUnavailable("Bluetooth unavailable")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = peripheral.name ?? advertisedName, !name.isEmpty else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        peripheralsByID[peripheral.identifier] = peripheral

        let rssi = RSSI.intValue == 127 ? -100 : RSSI.intValue
        let ring = DiscoveredRing(id: peripheral.identifier, name: name, rssi: rssi,
                                  looksLikeRing: Self.looksLikeRing(name: name, advertised: services))
        if let index = discovered.firstIndex(where: { $0.id == ring.id }) {
            discovered[index] = ring
        } else {
            discovered.append(ring)
        }
        discovered.sort { lhs, rhs in
            if lhs.looksLikeRing != rhs.looksLikeRing { return lhs.looksLikeRing }
            return lhs.rssi > rhs.rssi
        }

        // The remembered ring was not known to the system yet; connect when it shows up.
        if autoConnect, peripheral.identifier == savedRingID, !state.isConnected, self.peripheral == nil {
            stopScan()
            connect(peripheral, name: name)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetConnectionState()
        connectedName = peripheral.name ?? savedRingName
        state = .discovering
        peripheral.discoverServices(RingUUID.servicesOfInterest)
        // Some firmware never confirms the indication subscription; carry on regardless.
        readyFallbackTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.markReadyIfPossible(force: true)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handleLostConnection(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleLostConnection(peripheral)
    }

    private func handleLostConnection(_ lost: CBPeripheral) {
        guard lost.identifier == peripheral?.identifier else { return }
        let wasReady = state == .ready
        resetConnectionState()
        if wasReady { delegate?.transportDidDisconnect(self) }
        if autoConnect, lost.identifier == savedRingID, central.state == .poweredOn {
            state = .reconnecting
            central.connect(lost, options: nil)
        } else {
            peripheral = nil
            if case .bluetoothUnavailable = state { return }
            state = .idle
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RingBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        let hasYC = services.contains { $0.uuid == RingUUID.ycService }
        for service in services {
            // Prefer the YC service; use Nordic UART only when YC is absent.
            if service.uuid == RingUUID.uartService && hasYC { continue }
            pendingServiceDiscoveries += 1
            peripheral.discoverCharacteristics(nil, for: service)
        }
        markReadyIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServiceDiscoveries = max(0, pendingServiceDiscoveries - 1)
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case RingUUID.ycWrite:
                writeCharacteristic = characteristic
                // BE940001 is write + indicate: replies can arrive here too.
                if characteristic.properties.contains(.indicate) || characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            case RingUUID.uartWrite:
                if writeCharacteristic == nil { writeCharacteristic = characteristic }
            case RingUUID.ycNotify, RingUUID.uartNotify, RingUUID.heartRateMeasurement:
                peripheral.setNotifyValue(true, for: characteristic)
            case RingUUID.batteryLevel:
                peripheral.readValue(for: characteristic)
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            case RingUUID.manufacturerName, RingUUID.modelNumber, RingUUID.firmwareRevision:
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }
        markReadyIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil, characteristic.isNotifying {
            notifyCharacteristics.insert(characteristic.uuid)
        }
        markReadyIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        switch characteristic.uuid {
        case RingUUID.ycWrite, RingUUID.ycNotify, RingUUID.uartNotify:
            delegate?.transport(self, didReceive: value)
        case RingUUID.heartRateMeasurement:
            if let hr = YCParsers.gattHeartRate([UInt8](value)) {
                delegate?.transport(self, didReceiveHeartRate: hr.bpm, rrIntervals: hr.rrIntervals)
            }
        case RingUUID.batteryLevel:
            if let percent = value.first {
                delegate?.transport(self, didReadBattery: Int(percent))
            }
        case RingUUID.manufacturerName:
            gattInfo["Manufacturer"] = String(decoding: value, as: UTF8.self)
        case RingUUID.modelNumber:
            gattInfo["Model"] = String(decoding: value, as: UTF8.self)
        case RingUUID.firmwareRevision:
            gattInfo["Firmware"] = String(decoding: value, as: UTF8.self)
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        awaitingWriteResponse = false
        pumpWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWrites()
    }
}
