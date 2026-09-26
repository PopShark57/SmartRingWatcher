import CoreBluetooth
import Foundation
import Observation

/// GATT identifiers. The YC service is what Smarthealth-compatible rings expose; the
/// Nordic UART service carries the same frames on some models; the standard Heart Rate,
/// Battery and Device Information services are used when present (any "generic" ring).
@MainActor
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
    /// Smoothed signal strength in dBm.
    var rssi: Int
    var looksLikeRing: Bool

    /// 0…1 for `Image(systemName: "cellularbars", variableValue:)`: −90 dBm is empty, −50 full.
    var signalLevel: Double {
        min(1, max(0, Double(rssi + 90) / 40))
    }
}

/// CoreBluetooth central: scanning, connecting, auto-reconnect, service discovery,
/// subscriptions and a serialized write queue. All callbacks arrive on the main queue.
@MainActor
@Observable
final class RingBluetoothManager: NSObject, RingTransport {
    private(set) var state: RingConnectionState = .idle {
        didSet { if state != oldValue { stateChanged(from: oldValue) } }
    }
    /// Scan results, republished at most once a second and ordered by likely ring, then by
    /// signal strength in coarse steps, so rows don't jump around as RSSI fluctuates.
    private(set) var discovered: [DiscoveredRing] = []
    private(set) var connectedName: String?
    /// "YC (Smarthealth)" when the ring speaks the protocol, "Standard GATT" otherwise.
    private(set) var protocolName: String?
    private(set) var gattInfo: [String: String] = [:]
    private(set) var savedRingID: UUID?
    /// The user pressed Disconnect. Persisted, so the ring stays free for the phone app until
    /// the user presses Reconnect, even across launches and wrist raises.
    private(set) var isPaused: Bool
    private(set) var lastConnectedAt: Date?
    /// A connection attempt from the pairing screen has taken more than 15 s.
    private(set) var isSlowToConnect = false
    /// Reconnecting for more than 30 s: the ring is probably out of range or busy.
    private(set) var isWaitingForRing = false
    private(set) var maximumWriteLength: Int?
    private(set) var connectedRingID: UUID?

    /// Demo mode: no scanning or connecting, without touching the pause or the saved ring.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { suspendedChanged() } }
    }

    @ObservationIgnored weak var delegate: (any RingTransportDelegate)?

    private enum Keys {
        static let savedRing = "SavedRingIdentifier"
        static let savedRingName = "SavedRingName"
        static let paused = "SavedRingPaused"
        static let lastConnected = "SavedRingLastConnected"
    }

    private struct ScanResult {
        var peripheral: CBPeripheral
        var name: String
        var smoothedRSSI: Double
        var looksLikeRing: Bool
    }

    @ObservationIgnored private let log: DiagnosticsLog
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var peripheralsByID: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var scanResults: [UUID: ScanResult] = [:]
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    @ObservationIgnored private var batteryCharacteristic: CBCharacteristic?
    @ObservationIgnored private var notifyCharacteristics: Set<CBUUID> = []
    @ObservationIgnored private var pendingServiceDiscoveries = 0
    @ObservationIgnored private var writeQueue: [Data] = []
    @ObservationIgnored private var awaitingWriteResponse = false
    @ObservationIgnored private var scanStopTimer: (any Cancellable)?
    @ObservationIgnored private var scanPublishTimer: (any Cancellable)?
    @ObservationIgnored private var readyFallbackTimer: (any Cancellable)?
    @ObservationIgnored private var slowConnectTimer: (any Cancellable)?

    var hasProtocolChannel: Bool { writeCharacteristic != nil }
    var savedRingName: String? { defaults.string(forKey: Keys.savedRingName) }

    init(log: DiagnosticsLog, scheduler: any Scheduling = SystemScheduler.shared, defaults: UserDefaults = .standard) {
        self.log = log
        self.scheduler = scheduler
        self.defaults = defaults
        isPaused = defaults.bool(forKey: Keys.paused)
        lastConnectedAt = defaults.object(forKey: Keys.lastConnected) as? Date
        super.init()
        if let stored = defaults.string(forKey: Keys.savedRing) {
            savedRingID = UUID(uuidString: stored)
        }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    func startScan(duration: TimeInterval = 20) {
        guard central.state == .poweredOn, !isSuspended else { return }
        // Forget peripherals from earlier scans, except the ones in use.
        peripheralsByID = peripheralsByID.filter { $0.key == peripheral?.identifier || $0.key == savedRingID }
        scanResults.removeAll()
        discovered.removeAll()
        if !state.isConnected && !state.isConnecting { state = .scanning }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanStopTimer?.cancel()
        scanStopTimer = scheduler.after(duration) { [weak self] in self?.stopScan() }
        scanPublishTimer?.cancel()
        scanPublishTimer = scheduler.every(1) { [weak self] in self?.publishScanResults() }
    }

    func stopScan() {
        scanStopTimer?.cancel()
        scanStopTimer = nil
        scanPublishTimer?.cancel()
        scanPublishTimer = nil
        if central.isScanning { central.stopScan() }
        publishScanResults()
        if state == .scanning { state = restingState }
    }

    private func publishScanResults() {
        let rings = scanResults.map { id, result in
            DiscoveredRing(id: id, name: result.name, rssi: Int(result.smoothedRSSI.rounded()),
                           looksLikeRing: result.looksLikeRing)
        }
        let sorted = rings.sorted { lhs, rhs in
            if lhs.looksLikeRing != rhs.looksLikeRing { return lhs.looksLikeRing }
            // 6 dB steps, so small fluctuations don't reorder the list.
            let lhsBucket = lhs.rssi / 6, rhsBucket = rhs.rssi / 6
            if lhsBucket != rhsBucket { return lhsBucket > rhsBucket }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if sorted != discovered { discovered = sorted }
    }

    // MARK: - Connecting

    func connect(to ring: DiscoveredRing) {
        guard let target = peripheralsByID[ring.id] else { return }
        stopScan()
        if let current = peripheral, current.identifier != target.identifier {
            central.cancelPeripheralConnection(current)
        }
        defaults.set(target.identifier.uuidString, forKey: Keys.savedRing)
        defaults.set(ring.name, forKey: Keys.savedRingName)
        savedRingID = target.identifier
        setPaused(false)
        connect(target, name: ring.name)
    }

    /// Reconnects to the remembered ring. A pending `connect` never times out in
    /// CoreBluetooth, so the ring is picked up as soon as it is in range again.
    /// Does nothing while the user has paused the connection or demo mode is on.
    func connectSavedRing() {
        guard central.state == .poweredOn, let id = savedRingID, !isPaused, !isSuspended,
              !state.isConnected else { return }
        if peripheral?.identifier == id, state.isConnecting { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known, name: known.name ?? savedRingName ?? String(localized: "ring"))
        } else if state != .scanning {
            // Not known to the system yet: find it by scanning (see didDiscover).
            startScan()
        }
    }

    /// Clears the pause set by Disconnect and connects again.
    func reconnect() {
        setPaused(false)
        connectSavedRing()
    }

    /// Disconnects. Without `forget`, the connection stays paused (see `isPaused`) until
    /// `reconnect()`, so Smarthealth on the phone can connect meanwhile. `forget` also clears
    /// the remembered ring.
    func disconnect(forget: Bool) {
        if forget {
            defaults.removeObject(forKey: Keys.savedRing)
            defaults.removeObject(forKey: Keys.savedRingName)
            defaults.removeObject(forKey: Keys.lastConnected)
            savedRingID = nil
            lastConnectedAt = nil
            setPaused(false)
        } else {
            setPaused(true)
        }
        dropConnection()
        log.add(forget ? "Forgot the ring" : "Paused by the user", category: .ble)
    }

    /// Gives up a connection attempt that isn't getting anywhere (pairing screen's Cancel).
    func cancelConnectionAttempt() {
        disconnect(forget: false)
    }

    func readBattery() {
        guard let peripheral, let batteryCharacteristic else { return }
        peripheral.readValue(for: batteryCharacteristic)
    }

    private func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        defaults.set(paused, forKey: Keys.paused)
    }

    private func suspendedChanged() {
        if isSuspended {
            if central.isScanning { stopScan() }
            dropConnection()
        } else {
            connectSavedRing()
        }
    }

    /// Cancels the current or pending connection and settles in the resting state.
    private func dropConnection() {
        let wasReady = state == .ready
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        // The disconnect callback is ignored once `peripheral` is nil, so notify now.
        peripheral = nil
        resetConnectionState()
        if wasReady { delegate?.transportDidDisconnect(self) }
        if case .bluetoothUnavailable = state { return }
        state = restingState
    }

    private var restingState: RingConnectionState {
        if case .bluetoothUnavailable(let reason) = state { return .bluetoothUnavailable(reason) }
        if peripheral != nil, !isPaused, !isSuspended { return .reconnecting }
        return isPaused && savedRingID != nil ? .paused : .idle
    }

    private func connect(_ target: CBPeripheral, name: String) {
        peripheral = target
        peripheralsByID[target.identifier] = target
        target.delegate = self
        state = .connecting(name)
        central.connect(target, options: nil)
    }

    private func stateChanged(from old: RingConnectionState) {
        slowConnectTimer?.cancel()
        slowConnectTimer = nil
        isSlowToConnect = false
        isWaitingForRing = false
        switch state {
        case .connecting:
            slowConnectTimer = scheduler.after(15) { [weak self] in self?.isSlowToConnect = true }
        case .reconnecting:
            slowConnectTimer = scheduler.after(30) { [weak self] in self?.isWaitingForRing = true }
        case .ready:
            lastConnectedAt = scheduler.now
            defaults.set(lastConnectedAt, forKey: Keys.lastConnected)
        default:
            break
        }
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
        readyFallbackTimer?.cancel()
        readyFallbackTimer = nil
        writeCharacteristic = nil
        batteryCharacteristic = nil
        notifyCharacteristics.removeAll()
        pendingServiceDiscoveries = 0
        writeQueue.removeAll()
        awaitingWriteResponse = false
        connectedName = nil
        protocolName = nil
        connectedRingID = nil
        maximumWriteLength = nil
    }

    private func markReadyIfPossible(force: Bool = false) {
        guard state == .discovering, let peripheral else { return }
        if !force {
            guard pendingServiceDiscoveries == 0 else { return }
            // With a protocol channel, wait until its indications are switched on.
            let protocolNotify: Set<CBUUID> = [RingUUID.ycWrite, RingUUID.ycNotify, RingUUID.uartNotify]
            if writeCharacteristic != nil && notifyCharacteristics.isDisjoint(with: protocolNotify) { return }
        }
        readyFallbackTimer?.cancel()
        readyFallbackTimer = nil
        protocolName = writeCharacteristic == nil ? String(localized: "Standard GATT") : "YC (Smarthealth)"
        connectedRingID = peripheral.identifier
        if let characteristic = writeCharacteristic {
            maximumWriteLength = peripheral.maximumWriteValueLength(for: writeType(for: characteristic))
        }
        state = .ready
        delegate?.transportDidBecomeReady(self)
    }

    private func logError(_ context: String, _ error: Error?) {
        guard let error else { return }
        log.add("\(context): \(error.localizedDescription)", category: .ble, isError: true)
    }

    private static func looksLikeRing(name: String, advertised: [CBUUID]) -> Bool {
        if advertised.contains(where: { RingUUID.ringHints.contains($0) }) { return true }
        let lower = name.lowercased()
        return lower.contains("ring") || lower.hasPrefix("r0") || lower.hasPrefix("r1")
            || lower.hasPrefix("r2") || lower.hasPrefix("r9") || lower.contains("smart")
    }
}

// MARK: - CBCentralManagerDelegate

extension RingBluetoothManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Connections are dropped when Bluetooth goes away, without a disconnect callback.
        if central.state != .poweredOn, state == .ready {
            resetConnectionState()
            delegate?.transportDidDisconnect(self)
        }
        switch central.state {
        case .poweredOn:
            if state != .ready {
                peripheral = nil
                state = isPaused && savedRingID != nil ? .paused : .idle
            }
            connectSavedRing()
        case .poweredOff:
            state = .bluetoothUnavailable(String(localized: "Bluetooth is off"))
        case .unauthorized:
            state = .bluetoothUnavailable(String(localized: "Bluetooth permission denied"))
        case .unsupported:
            state = .bluetoothUnavailable(String(localized: "Bluetooth LE unavailable"))
        case .resetting, .unknown:
            state = .bluetoothUnavailable(String(localized: "Bluetooth starting…"))
        @unknown default:
            state = .bluetoothUnavailable(String(localized: "Bluetooth unavailable"))
        }
        log.add("Bluetooth state \(central.state.rawValue)", category: .ble)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = peripheral.name ?? advertisedName, !name.isEmpty else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        peripheralsByID[peripheral.identifier] = peripheral

        let rssi = RSSI.intValue == 127 ? -100.0 : RSSI.doubleValue
        if var result = scanResults[peripheral.identifier] {
            // Moving average: advertisement RSSI is noisy.
            result.smoothedRSSI = result.smoothedRSSI * 0.7 + rssi * 0.3
            result.name = name
            result.looksLikeRing = result.looksLikeRing || Self.looksLikeRing(name: name, advertised: services)
            scanResults[peripheral.identifier] = result
        } else {
            scanResults[peripheral.identifier] = ScanResult(
                peripheral: peripheral, name: name, smoothedRSSI: rssi,
                looksLikeRing: Self.looksLikeRing(name: name, advertised: services))
            // Show the first results right away; later updates wait for the 1 s tick.
            if discovered.count < 3 { publishScanResults() }
        }

        // The remembered ring was not known to the system yet; connect when it shows up.
        if !isPaused, !isSuspended, peripheral.identifier == savedRingID, !state.isConnected, self.peripheral == nil {
            stopScan()
            connect(peripheral, name: name)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        resetConnectionState()
        connectedName = peripheral.name ?? savedRingName
        state = .discovering
        peripheral.discoverServices(RingUUID.servicesOfInterest)
        // Some firmware never confirms the indication subscription; carry on regardless.
        readyFallbackTimer = scheduler.after(6) { [weak self] in
            self?.markReadyIfPossible(force: true)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logError("Connection failed", error)
        handleLostConnection(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logError("Disconnected", error)
        handleLostConnection(peripheral)
    }

    private func handleLostConnection(_ lost: CBPeripheral) {
        guard lost.identifier == peripheral?.identifier else { return }
        let wasReady = state == .ready
        resetConnectionState()
        if wasReady { delegate?.transportDidDisconnect(self) }
        if !isPaused, !isSuspended, lost.identifier == savedRingID, central.state == .poweredOn {
            state = .reconnecting
            central.connect(lost, options: nil)
        } else {
            peripheral = nil
            if case .bluetoothUnavailable = state { return }
            state = restingState
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RingBluetoothManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        logError("Service discovery failed", error)
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
        logError("Characteristic discovery failed for \(service.uuid)", error)
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
                batteryCharacteristic = characteristic
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
        logError("Subscribing to \(characteristic.uuid) failed", error)
        if error == nil, characteristic.isNotifying {
            notifyCharacteristics.insert(characteristic.uuid)
        }
        markReadyIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        logError("Reading \(characteristic.uuid) failed", error)
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
        logError("Write failed", error)
        awaitingWriteResponse = false
        pumpWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWrites()
    }
}
