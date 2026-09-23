import Foundation

/// Drives the ring: a serialized command queue, auto-refresh timers, history sync,
/// on-demand measurements and background refresh. Owns the `YCProtocolSession`.
///
/// Auto-refresh while the app is on screen:
/// - every `liveRefreshSeconds`: poll the live snapshot (HR, BP, SpO2, temperature,
///   respiration, today's steps), plus battery once a minute;
/// - every `historyRefreshMinutes`: pull stored history (HR, steps, sleep, BP, SpO2, HRV,
///   stress, temperature, blood chemistry);
/// - anything the ring pushes on its own (real-time uploads, measurement results) is
///   shown immediately.
final class RingSyncEngine: ObservableObject {
    @Published private(set) var isSyncingHistory = false
    @Published private(set) var lastHistorySync: Date?
    @Published private(set) var lastLivePoll: Date?
    @Published private(set) var activeMeasurement: MeasurementKind?
    @Published private(set) var lastMeasurementOutcome: (kind: MeasurementKind, outcome: MeasurementOutcome)?
    @Published private(set) var log: [String] = []

    let transport: RingBluetoothManager
    let store: HealthDataStore
    let settings: AppSettings

    private struct QueuedCommand {
        let frame: YCFrame
        let timeout: TimeInterval
    }

    private let session = YCProtocolSession()
    private var queue: [QueuedCommand] = []
    private var inFlight: QueuedCommand?
    private var inFlightTimer: Timer?
    private var spacingTimer: Timer?
    private var liveTimer: Timer?
    private var historyTimer: Timer?
    private var measurementTimer: Timer?
    private var demoTimer: Timer?
    private var failureCounts: [YCDataType: Int] = [:]
    private var liveTick = 0
    private var isForeground = true
    private var backgroundCompletion: (() -> Void)?
    private var backgroundDeadline: Timer?
    private var lastStreamedSample: [String: Date] = [:]

    /// Minimum gap between writes; the vendor's reference client uses ~80–100 ms.
    private let commandSpacing: TimeInterval = 0.1

    init(transport: RingBluetoothManager, store: HealthDataStore, settings: AppSettings) {
        self.transport = transport
        self.store = store
        self.settings = settings
        transport.delegate = self
        if settings.demoMode { startDemo() }
    }

    // MARK: - Public controls

    /// Called when the app becomes active / inactive.
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground {
            if settings.demoMode {
                startDemo()
            } else if transport.state.isConnected {
                startTimers()
                refreshNow(includeHistory: (lastHistorySync ?? .distantPast) < Date().addingTimeInterval(-60))
                if settings.liveStreaming { enqueueLiveStream(enabled: true) }
            } else {
                transport.connectSavedRing()
            }
        } else {
            stopTimers()
            demoTimer?.invalidate()
            demoTimer = nil
            if settings.liveStreaming, transport.state.isConnected {
                enqueueLiveStream(enabled: false)
            }
        }
    }

    /// Pull-to-refresh / "Sync now".
    func refreshNow(includeHistory: Bool = true) {
        if settings.demoMode {
            store.applyLive(DemoDataGenerator.live(previous: store.live))
            lastLivePoll = Date()
            return
        }
        guard transport.state.isConnected else {
            transport.connectSavedRing()
            return
        }
        pollLive(includeBattery: true)
        if includeHistory { syncHistory() }
    }

    func settingsChanged() {
        if settings.demoMode {
            stopTimers()
            startDemo()
            return
        }
        stopDemo()
        if transport.state.isConnected {
            if isForeground { startTimers() }
            enqueueLiveStream(enabled: settings.liveStreaming)
        } else {
            transport.connectSavedRing()
        }
    }

    func startMeasurement(_ kind: MeasurementKind) {
        guard transport.hasProtocolChannel || settings.demoMode else { return }
        if let current = activeMeasurement { stopMeasurement(current) }
        activeMeasurement = kind
        lastMeasurementOutcome = nil
        measurementTimer?.invalidate()
        // Rings finish within ~30–60 s; give up after 90 s.
        measurementTimer = Timer.scheduledTimer(withTimeInterval: settings.demoMode ? 8 : 90, repeats: false) { [weak self] _ in
            guard let self, let kind = self.activeMeasurement else { return }
            if self.settings.demoMode {
                self.finishDemoMeasurement(kind)
            } else {
                self.stopMeasurement(kind)
                self.lastMeasurementOutcome = (kind: kind, outcome: .failed)
            }
        }
        if !settings.demoMode {
            enqueue(YCCommand.startMeasurement(kind))
        }
        addLog("Measuring \(kind.displayName)")
    }

    func stopMeasurement(_ kind: MeasurementKind) {
        measurementTimer?.invalidate()
        measurementTimer = nil
        activeMeasurement = nil
        if !settings.demoMode {
            enqueue(YCCommand.stopMeasurement(kind))
        }
    }

    /// Background App Refresh: watchOS allows ~15 s, so do the essentials and report back.
    func performBackgroundSync(completion: @escaping () -> Void) {
        guard !settings.demoMode else { completion(); return }
        // Only one refresh task is honoured at a time; finish any earlier one first.
        if let pending = backgroundCompletion {
            backgroundCompletion = nil
            pending()
        }
        backgroundCompletion = completion
        backgroundDeadline?.invalidate()
        backgroundDeadline = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.finishBackgroundSync()
        }
        if transport.state.isConnected {
            enqueue(YCCommand.allRealData)
            enqueue(YCCommand.deviceInfo)
            enqueue(YCCommand.history(.historyHeart), timeout: 8)
            enqueue(YCCommand.history(.historySport), timeout: 8)
        } else {
            transport.connectSavedRing()
        }
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        let liveInterval = TimeInterval(max(5, settings.liveRefreshSeconds))
        liveTimer = Timer.scheduledTimer(withTimeInterval: liveInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.liveTick += 1
            // Battery roughly once a minute.
            let batteryEvery = max(1, Int(60 / liveInterval))
            self.pollLive(includeBattery: self.liveTick % batteryEvery == 0)
        }
        let historyInterval = TimeInterval(max(1, settings.historyRefreshMinutes) * 60)
        historyTimer = Timer.scheduledTimer(withTimeInterval: historyInterval, repeats: true) { [weak self] _ in
            self?.syncHistory()
        }
    }

    private func stopTimers() {
        liveTimer?.invalidate()
        historyTimer?.invalidate()
        liveTimer = nil
        historyTimer = nil
    }

    private func pollLive(includeBattery: Bool) {
        guard transport.hasProtocolChannel else { return }
        if failureCounts[.getAllRealData, default: 0] < 3 {
            enqueue(YCCommand.allRealData)
        } else {
            // Older firmware: fall back to the individual queries.
            enqueue(YCCommand.nowStep)
            enqueue(YCCommand.realTemperature)
            enqueue(YCCommand.realBloodOxygen)
        }
        if includeBattery { enqueue(YCCommand.deviceInfo) }
        lastLivePoll = Date()
    }

    private func syncHistory() {
        guard transport.hasProtocolChannel else { return }
        var queuedAny = false
        for type in YCCommand.historyTypes where failureCounts[type, default: 0] < 3 {
            // A long history can take a while over BLE; the timeout is extended while data flows.
            queuedAny = enqueue(YCCommand.history(type), timeout: 20) || queuedAny
        }
        if queuedAny { isSyncingHistory = true }
    }

    private func enqueueLiveStream(enabled: Bool) {
        guard transport.hasProtocolChannel else { return }
        enqueue(YCCommand.liveStream(enabled: enabled, kind: 0))
        enqueue(YCCommand.liveStream(enabled: enabled, kind: 1))
    }

    // MARK: - Command queue

    /// Returns false when an identical request is already waiting (avoids pile-ups
    /// when the ring is slower than the refresh interval).
    @discardableResult
    private func enqueue(_ frame: YCFrame, timeout: TimeInterval = 4) -> Bool {
        guard transport.hasProtocolChannel else { return false }
        if queue.contains(where: { $0.frame == frame }) || inFlight?.frame == frame { return false }
        queue.append(QueuedCommand(frame: frame, timeout: timeout))
        pump()
        return true
    }

    private func pump() {
        guard inFlight == nil, spacingTimer == nil, !queue.isEmpty, transport.state.isConnected else { return }
        let command = queue.removeFirst()
        inFlight = command
        transport.write(command.frame.data)
        armInFlightTimer(command.timeout)
    }

    private func armInFlightTimer(_ seconds: TimeInterval) {
        inFlightTimer?.invalidate()
        inFlightTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, let command = self.inFlight else { return }
            self.addLog("Timeout \(command.frame.dataType)")
            self.failureCounts[command.frame.dataType, default: 0] += 1
            self.completeInFlight()
        }
    }

    private func completeInFlight() {
        inFlightTimer?.invalidate()
        inFlightTimer = nil
        inFlight = nil
        spacingTimer?.invalidate()
        spacingTimer = Timer.scheduledTimer(withTimeInterval: commandSpacing, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.spacingTimer = nil
            self.pump()
            self.queueDidDrainIfIdle()
        }
    }

    private func queueDidDrainIfIdle() {
        guard inFlight == nil, queue.isEmpty else { return }
        if isSyncingHistory {
            isSyncingHistory = false
            lastHistorySync = Date()
            store.save()
        }
        if backgroundCompletion != nil { finishBackgroundSync() }
    }

    private func resetQueue() {
        queue.removeAll()
        inFlight = nil
        inFlightTimer?.invalidate()
        inFlightTimer = nil
        spacingTimer?.invalidate()
        spacingTimer = nil
        isSyncingHistory = false
    }

    private func finishBackgroundSync() {
        backgroundDeadline?.invalidate()
        backgroundDeadline = nil
        store.save()
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
    }

    // MARK: - Protocol events

    private func handle(_ output: YCProtocolSession.Output) {
        for reply in output.replies {
            transport.write(reply.data)
        }
        for event in output.events {
            switch event {
            case .live(let patch, let pushed):
                store.applyLive(patch)
                if pushed { recordStreamedSamples(patch) }
            case .samples(let batch):
                store.apply(batch)
            case .deviceInfo(let info):
                store.setDeviceInfo(info)
            case .completed(let type, let success):
                if success {
                    failureCounts[type] = 0
                } else {
                    failureCounts[type, default: 0] += 1
                    addLog("Not supported / failed: \(type)")
                }
                if inFlight?.frame.dataType == type { completeInFlight() }
            case .measurementFinished(let kind, let outcome):
                measurementFinished(kind, outcome)
            }
        }
        // History arrives as many frames; keep the request alive while data flows.
        if session.isReceivingHistory, let command = inFlight, command.frame.dataType.group == YCGroup.health {
            armInFlightTimer(8)
        }
    }

    private func measurementFinished(_ kind: MeasurementKind?, _ outcome: MeasurementOutcome) {
        let finished = kind ?? activeMeasurement ?? .heartRate
        addLog("\(finished.displayName): \(outcome.rawValue)")
        measurementTimer?.invalidate()
        measurementTimer = nil
        if activeMeasurement == finished { activeMeasurement = nil }
        lastMeasurementOutcome = (kind: finished, outcome: outcome)
        guard outcome == .success else { return }
        // Results are stored on the ring; fetch them.
        switch finished {
        case .heartRate: enqueue(YCCommand.history(.historyHeart), timeout: 20)
        case .bloodPressure: enqueue(YCCommand.history(.historyBlood), timeout: 20)
        case .bloodOxygen: enqueue(YCCommand.history(.historyBloodOxygen), timeout: 20)
        case .temperature: enqueue(YCCommand.history(.historyTemperature), timeout: 20)
        case .respiratoryRate: enqueue(YCCommand.history(.historyAll), timeout: 20)
        case .bloodGlucose, .uricAcid, .bloodKetone: enqueue(YCCommand.history(.historyComprehensive), timeout: 20)
        }
        enqueue(YCCommand.allRealData)
    }

    /// Values the ring streams during a measurement or live streaming are real readings; keep
    /// one per 30 s so charts show them without flooding the store. Polled snapshots never get
    /// here (they may repeat an old measurement).
    private func recordStreamedSamples(_ patch: LiveSnapshot) {
        guard activeMeasurement != nil || settings.liveStreaming, let at = patch.updatedAt else { return }
        var batch = HealthBatch()
        if let bpm = patch.heartRate, shouldRecord("hr", at) {
            batch.heartRate.append(HeartRateSample(date: at, bpm: bpm))
        }
        if let spo2 = patch.bloodOxygen, shouldRecord("spo2", at) {
            batch.bloodOxygen.append(BloodOxygenSample(date: at, percent: spo2))
        }
        store.apply(batch)
    }

    private func shouldRecord(_ key: String, _ date: Date) -> Bool {
        if let last = lastStreamedSample[key], date.timeIntervalSince(last) < 30 { return false }
        lastStreamedSample[key] = date
        return true
    }

    private func addLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.append("\(formatter.string(from: Date())) \(message)")
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    // MARK: - Demo mode

    private func startDemo() {
        if store.heartRate.isEmpty || store.deviceInfo?.deviceID != DemoDataGenerator.deviceInfo.deviceID {
            store.replaceAll(with: DemoDataGenerator.history(),
                             live: DemoDataGenerator.live(previous: LiveSnapshot()),
                             device: DemoDataGenerator.deviceInfo)
            lastHistorySync = Date()
        }
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(5, settings.liveRefreshSeconds)), repeats: true) { [weak self] _ in
            guard let self else { return }
            self.store.applyLive(DemoDataGenerator.live(previous: self.store.live))
            self.lastLivePoll = Date()
        }
    }

    private func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        if store.deviceInfo?.deviceID == DemoDataGenerator.deviceInfo.deviceID {
            store.eraseAll()
        }
    }

    private func finishDemoMeasurement(_ kind: MeasurementKind) {
        let now = Date()
        var batch = HealthBatch()
        switch kind {
        case .heartRate: batch.heartRate = [HeartRateSample(date: now, bpm: Int.random(in: 62...74))]
        case .bloodPressure: batch.bloodPressure = [BloodPressureSample(date: now, systolic: Int.random(in: 112...124), diastolic: Int.random(in: 72...80), heartRate: nil)]
        case .bloodOxygen: batch.bloodOxygen = [BloodOxygenSample(date: now, percent: Int.random(in: 96...99))]
        case .temperature: batch.temperature = [TemperatureSample(date: now, celsius: 36.6)]
        case .respiratoryRate: batch.respiration = [RespirationSample(date: now, breathsPerMinute: Int.random(in: 13...17))]
        case .bloodGlucose: batch.metabolic = [MetabolicSample(date: now, glucose: 5.3)]
        case .uricAcid: batch.metabolic = [MetabolicSample(date: now, uricAcid: 305)]
        case .bloodKetone: batch.metabolic = [MetabolicSample(date: now, ketone: 0.2)]
        }
        store.apply(batch)
        measurementFinished(kind, .success)
    }
}

// MARK: - RingTransportDelegate

extension RingSyncEngine: RingTransportDelegate {
    func transportDidBecomeReady(_ transport: RingBluetoothManager) {
        session.reset()
        resetQueue()
        failureCounts.removeAll()
        addLog("Connected (\(transport.protocolName ?? "?"))")
        guard !settings.demoMode else { return }
        if transport.hasProtocolChannel {
            enqueue(YCCommand.syncClock())
            enqueue(YCCommand.deviceInfo)
            pollLive(includeBattery: false)
            syncHistory()
            if settings.liveStreaming { enqueueLiveStream(enabled: true) }
        }
        if isForeground { startTimers() }
        if backgroundCompletion != nil {
            // Woken for background refresh: fetch only the essentials.
            queue = queue.filter { command in
                [YCDataType.getAllRealData, .getDeviceInfo, .historyHeart, .historySport, .settingTime]
                    .contains(command.frame.dataType)
            }
        }
    }

    func transportDidDisconnect(_ transport: RingBluetoothManager) {
        addLog("Disconnected")
        stopTimers()
        resetQueue()
        session.reset()
        if activeMeasurement != nil {
            measurementTimer?.invalidate()
            activeMeasurement = nil
        }
    }

    func transport(_ transport: RingBluetoothManager, didReceive data: Data) {
        guard !settings.demoMode else { return }
        handle(session.receive(data))
    }

    func transport(_ transport: RingBluetoothManager, didReceiveHeartRate bpm: Int, rrIntervals: [Double]) {
        guard !settings.demoMode, let bpm = Plausible.heartRate(bpm) else { return }
        let now = Date()
        var patch = LiveSnapshot(updatedAt: now)
        patch.heartRate = bpm
        var batch = HealthBatch()
        if shouldRecord("gatt-hr", now) {
            batch.heartRate.append(HeartRateSample(date: now, bpm: bpm))
        }
        if let rmssd = YCParsers.rmssd(rrIntervals), let hrv = Plausible.hrv(rmssd) {
            patch.hrv = hrv.rounded()
            if shouldRecord("gatt-hrv", now) {
                batch.hrv.append(HRVSample(date: now, milliseconds: hrv.rounded()))
            }
        }
        store.applyLive(patch)
        store.apply(batch)
    }

    func transport(_ transport: RingBluetoothManager, didReadBattery percent: Int) {
        guard !settings.demoMode else { return }
        var patch = LiveSnapshot()
        patch.batteryPercent = min(100, percent)
        store.applyLive(patch)
    }
}
