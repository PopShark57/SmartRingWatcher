import Foundation
import Observation

/// Health of one request type, shown under Settings → Diagnostics.
struct CommandStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ok
        /// Timed out or failed; retried after `retryAt` with exponential backoff.
        case failing
        /// The ring answered "unsupported"; not asked again until the next connection.
        case unsupported
    }

    var state: State = .ok
    var failures = 0
    var retryAt: Date?
    var lastSuccess: Date?
    /// Size of the last history transfer.
    var lastBytes: Int?
    var lastRecords: Int?
}

/// How a one-off measurement ended.
struct MeasurementResult: Equatable, Sendable {
    let kind: MeasurementKind
    let outcome: MeasurementOutcome
    let startedAt: Date
    let date: Date
}

/// Drives the ring: a serialized command queue, auto-refresh timers, history sync,
/// on-demand measurements and background refresh. Owns the `YCProtocolSession`.
///
/// Auto-refresh while the app is on screen:
/// - every `liveRefreshSeconds`: poll the live snapshot (HR, BP, SpO2, temperature,
///   respiration, today's steps), plus battery once a minute;
/// - once a minute: pull whichever history types are due (see `HistorySchedule`);
/// - anything the ring pushes on its own (real-time uploads, measurement results) is
///   shown immediately.
@MainActor
@Observable
final class RingSyncEngine {
    private(set) var isSyncingHistory = false
    private(set) var lastHistorySync: Date?
    private(set) var lastLivePoll: Date?
    private(set) var activeMeasurement: MeasurementKind?
    private(set) var measurementStartedAt: Date?
    private(set) var lastMeasurementOutcome: MeasurementResult?
    private(set) var commandStatus: [YCDataType: CommandStatus] = [:]
    private(set) var crcErrors = 0

    /// Rings take about 30–60 s; the measurement is abandoned after this.
    let measurementTimeout: TimeInterval
    /// How long the current kind of measurement may take (demo measurements are quick).
    var measurementDuration: TimeInterval { isDemo ? 8 : measurementTimeout }
    let transport: any RingTransport
    let realStore: HealthDataStore
    /// Demo data lives in its own in-memory store, so demo mode never touches the real cache.
    let demoStore: HealthDataStore
    let settings: AppSettings
    let log: DiagnosticsLog

    /// The store the UI shows: demo or real.
    var store: HealthDataStore { settings.demoMode ? demoStore : realStore }

    @ObservationIgnored var onMeasurementFinished: (@MainActor (MeasurementKind, MeasurementOutcome) -> Void)?
    /// The ring was reachable (connected or sent data); used for the "not seen" notification.
    @ObservationIgnored var onRingContact: (@MainActor () -> Void)?
    /// A burst of requests finished (a good moment to refresh the complication).
    @ObservationIgnored var onSyncFinished: (@MainActor () -> Void)?

    private struct QueuedCommand {
        let frame: YCFrame
        let timeout: TimeInterval
        var isHistory: Bool { frame.dataType.group == YCGroup.health }
    }

    @ObservationIgnored private let session = YCProtocolSession(timeZone: .autoupdatingCurrent)
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var queue: [QueuedCommand] = []
    @ObservationIgnored private var inFlight: QueuedCommand?
    @ObservationIgnored private var inFlightTimer: (any Cancellable)?
    @ObservationIgnored private var spacingTimer: (any Cancellable)?
    @ObservationIgnored private var liveTimer: (any Cancellable)?
    @ObservationIgnored private var historyTimer: (any Cancellable)?
    @ObservationIgnored private var measurementTimer: (any Cancellable)?
    @ObservationIgnored private var demoTimer: (any Cancellable)?
    @ObservationIgnored private var backgroundDeadline: (any Cancellable)?
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var liveTick = 0
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var lastStreamedSample: [String: Date] = [:]
    @ObservationIgnored private var lastClockSync: Date?
    @ObservationIgnored private var lastGattBatteryRead: Date?
    @ObservationIgnored private var rrWindow = RRIntervalWindow()
    @ObservationIgnored private var historyLastSync: [YCDataType: Date] = [:]
    @ObservationIgnored private var systemObservers: [any NSObjectProtocol] = []

    /// Minimum gap between writes; the vendor's reference client uses ~80–100 ms.
    private let commandSpacing: TimeInterval = 0.1
    private static let lastSyncKey = "HistoryLastSync"
    private static let lastSyncRingKey = "HistoryLastSyncRing"

    private var now: Date { scheduler.now }
    private var isDemo: Bool { settings.demoMode }

    init(transport: any RingTransport, realStore: HealthDataStore, demoStore: HealthDataStore,
         settings: AppSettings, log: DiagnosticsLog, scheduler: any Scheduling = SystemScheduler.shared,
         defaults: UserDefaults = .standard, measurementTimeout: TimeInterval = 90,
         observesSystemTime: Bool = true) {
        self.transport = transport
        self.realStore = realStore
        self.demoStore = demoStore
        self.settings = settings
        self.log = log
        self.scheduler = scheduler
        self.defaults = defaults
        self.measurementTimeout = measurementTimeout
        historyLastSync = Self.loadLastSync(defaults)
        transport.delegate = self
        transport.isSuspended = settings.demoMode
        settings.observe { [weak self] key in self?.settingChanged(key) }
        if settings.demoMode { startDemo() }
        if observesSystemTime { observeSystemTime() }
    }

    // MARK: - Public controls

    /// Called when the app becomes active / inactive.
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground {
            store.refreshDay()
            if isDemo {
                startDemo()
            } else if transport.state.isConnected {
                startTimers()
                pollLive(includeBattery: true)
                syncDueHistory()
                if settings.liveStreaming { enqueueLiveStream(enabled: true) }
            } else {
                // Does nothing while the user has paused the connection.
                transport.connectSavedRing()
            }
        } else {
            stopTimers()
            demoTimer?.cancel()
            demoTimer = nil
            // Pushed frames would use up the background wake-up budget.
            if settings.liveStreaming, transport.state.isConnected {
                enqueueLiveStream(enabled: false)
            }
        }
    }

    /// "Sync now" and pull-to-refresh: live values plus every history type.
    func refreshNow() {
        if isDemo {
            demoStore.applyLive(DemoDataGenerator.live(previous: demoStore.live, now: now), pushed: true)
            lastLivePoll = now
            return
        }
        guard transport.state.isConnected else {
            transport.connectSavedRing()
            return
        }
        pollLive(includeBattery: true)
        syncHistory(types: HistorySchedule.allTypes, force: true)
    }

    /// `refreshNow`, then waits (up to `timeout`) until the requests finish, for `.refreshable`.
    func refresh(timeout: TimeInterval = 20) async {
        refreshNow()
        let deadline = now.addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(300))
        while (isSyncingHistory || inFlight != nil || !queue.isEmpty), now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func startMeasurement(_ kind: MeasurementKind) {
        guard isDemo || (transport.hasProtocolChannel && transport.state.isConnected) else { return }
        if let current = activeMeasurement { stopMeasurement(current) }
        activeMeasurement = kind
        measurementStartedAt = now
        lastMeasurementOutcome = nil
        measurementTimer?.cancel()
        measurementTimer = scheduler.after(measurementDuration) { [weak self] in
            guard let self, let kind = self.activeMeasurement else { return }
            if self.isDemo {
                self.finishDemoMeasurement(kind)
            } else {
                self.finishMeasurement(kind, .failed)
                self.stopMeasurement(kind)
            }
        }
        if !isDemo {
            enqueue(YCCommand.startMeasurement(kind))
        }
        log.add("Measuring \(kind.displayName)")
    }

    func stopMeasurement(_ kind: MeasurementKind) {
        measurementTimer?.cancel()
        measurementTimer = nil
        activeMeasurement = nil
        measurementStartedAt = nil
        if !isDemo {
            enqueue(YCCommand.stopMeasurement(kind))
        }
    }

    /// Background App Refresh: watchOS allows ~15 s, so do the essentials and report back.
    func performBackgroundSync(completion: @escaping () -> Void) {
        guard !isDemo else { completion(); return }
        // Only one refresh task is honoured at a time; finish any earlier one first.
        if let pending = backgroundCompletion {
            backgroundCompletion = nil
            pending()
        }
        backgroundCompletion = completion
        backgroundDeadline?.cancel()
        backgroundDeadline = scheduler.after(12) { [weak self] in
            self?.finishBackgroundSync()
        }
        if transport.state.isConnected {
            enqueueBackgroundEssentials()
        } else {
            transport.connectSavedRing()
            if transport.state == .paused || transport.isSuspended { finishBackgroundSync() }
        }
    }

    /// Erases the cache of the store on screen (real or demo) and pulls history again.
    func eraseCache() {
        store.eraseAll()
        if !isDemo {
            historyLastSync.removeAll()
            saveLastSync()
        }
        refreshNow()
    }

    // MARK: - Settings

    private func settingChanged(_ key: AppSettings.Key) {
        switch key {
        case .demoMode:
            if isDemo {
                stopTimers()
                resetQueue()
                transport.isSuspended = true
                startDemo()
                log.add("Demo mode on")
            } else {
                stopDemo()
                transport.isSuspended = false
                log.add("Demo mode off")
                if transport.state.isConnected, isForeground { startTimers() }
            }
        case .liveRefreshSeconds, .historyRefreshMinutes:
            if isDemo {
                if isForeground { startDemo() }
            } else if transport.state.isConnected, isForeground {
                startTimers()
            }
        case .liveStreaming:
            if !isDemo, transport.state.isConnected { enqueueLiveStream(enabled: settings.liveStreaming) }
        case .showBloodChemistry:
            if settings.showBloodChemistry, !isDemo, transport.state.isConnected {
                syncHistory(types: [.historyComprehensive], force: true)
            }
        default:
            break
        }
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        let liveInterval = TimeInterval(max(5, settings.liveRefreshSeconds))
        liveTimer = scheduler.every(liveInterval) { [weak self] in
            guard let self else { return }
            self.liveTick += 1
            // Battery roughly once a minute.
            let batteryEvery = max(1, Int(60 / liveInterval))
            self.pollLive(includeBattery: self.liveTick % batteryEvery == 0)
        }
        // Each history type has its own interval; check once a minute what is due.
        historyTimer = scheduler.every(60) { [weak self] in
            self?.syncDueHistory()
        }
    }

    private func stopTimers() {
        liveTimer?.cancel()
        historyTimer?.cancel()
        liveTimer = nil
        historyTimer = nil
    }

    private func pollLive(includeBattery: Bool) {
        guard transport.state.isConnected else { return }
        guard transport.hasProtocolChannel else {
            // Standard-GATT rings: the battery characteristic may not notify, so re-read it.
            if lastGattBatteryRead.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
                lastGattBatteryRead = now
                transport.readBattery()
            }
            return
        }
        let snapshot = commandStatus[.getAllRealData] ?? CommandStatus()
        if snapshot.state != .unsupported && snapshot.failures < 3 {
            enqueue(YCCommand.allRealData)
        } else {
            // Older firmware: fall back to the individual queries.
            enqueue(YCCommand.nowStep)
            enqueue(YCCommand.realTemperature)
            enqueue(YCCommand.realBloodOxygen)
        }
        if includeBattery { enqueue(YCCommand.deviceInfo) }
        // The ring's clock drifts; set it again once a day while connected.
        if lastClockSync.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true {
            syncClock()
        }
        lastLivePoll = now
    }

    private func syncClock() {
        guard enqueue(YCCommand.syncClock(now, timeZone: .autoupdatingCurrent)) else { return }
        lastClockSync = now
    }

    private var historySchedule: HistorySchedule {
        HistorySchedule(baseInterval: TimeInterval(settings.historyRefreshMinutes * 60),
                        includesBloodChemistry: settings.showBloodChemistry)
    }

    /// Requests every history type whose interval has passed.
    private func syncDueHistory() {
        syncHistory(types: HistorySchedule.allTypes, force: false)
    }

    /// Requests history. Unless `force`, only types that are due; never types the ring
    /// said it doesn't support, or that are waiting out a retry backoff.
    private func syncHistory(types: [YCDataType], force: Bool) {
        guard transport.hasProtocolChannel else { return }
        let schedule = historySchedule
        let newestSleep = realStore.sleep.last?.end
        for type in types where canRequest(type) {
            if type == .historyComprehensive && !settings.showBloodChemistry { continue }
            if !force && !schedule.isDue(type, lastSync: historyLastSync[type], newestSleepEnd: newestSleep, now: now) {
                continue
            }
            // A long history can take a while over BLE; the timeout is extended while data flows.
            enqueue(YCCommand.history(type), timeout: 20)
        }
    }

    private func enqueueBackgroundEssentials() {
        enqueue(YCCommand.allRealData)
        enqueue(YCCommand.deviceInfo)
        // Only heart rate and steps fit in the time watchOS allows; the rest keep their
        // own "last synced" dates, so opening the app still fetches them.
        syncHistory(types: [.historyHeart, .historySport], force: false)
    }

    private func enqueueLiveStream(enabled: Bool) {
        guard transport.hasProtocolChannel else { return }
        enqueue(YCCommand.liveStream(enabled: enabled, kind: 0))
        enqueue(YCCommand.liveStream(enabled: enabled, kind: 1))
    }

    // MARK: - Failure tracking

    private func canRequest(_ type: YCDataType) -> Bool {
        guard let status = commandStatus[type] else { return true }
        switch status.state {
        case .ok: return true
        case .unsupported: return false
        case .failing: return status.retryAt.map { now >= $0 } ?? true
        }
    }

    private func recordResult(_ type: YCDataType, _ result: CommandResult) {
        var status = commandStatus[type] ?? CommandStatus()
        switch result {
        case .success:
            status.state = .ok
            status.failures = 0
            status.retryAt = nil
            status.lastSuccess = now
            if type.group == YCGroup.health {
                historyLastSync[type] = now
                saveLastSync()
            }
        case .unsupported:
            status.state = .unsupported
            status.retryAt = nil
            log.add("Not supported by this ring: \(Self.name(of: type))")
        case .failed:
            // A timeout or a bad transfer is usually a patch of poor radio: retry with backoff
            // (30 s, 1 min, 2 min … up to 30 min) instead of giving up for the whole connection.
            status.state = .failing
            status.failures += 1
            let backoff = min(30 * 60, 30 * pow(2, Double(status.failures - 1)))
            status.retryAt = now.addingTimeInterval(backoff)
            log.add("\(Self.name(of: type)) failed (\(status.failures)×), retry in \(Int(backoff)) s", isError: true)
        }
        commandStatus[type] = status
    }

    private func recordTransfer(_ type: YCDataType, bytes: Int, records: Int) {
        var status = commandStatus[type] ?? CommandStatus()
        status.lastBytes = bytes
        status.lastRecords = records
        commandStatus[type] = status
        log.add("\(Self.name(of: type)): \(records) records, \(bytes) bytes")
    }

    static func name(of type: YCDataType) -> String {
        switch type {
        case .historyHeart: return "HR history"
        case .historySport: return "Step history"
        case .historySleep: return "Sleep history"
        case .historyBlood: return "BP history"
        case .historyBloodOxygen: return "SpO₂ history"
        case .historyAll: return "Combined history"
        case .historyBody: return "Body data history"
        case .historyTemperature: return "Temperature history"
        case .historyComprehensive: return "Blood chemistry history"
        case .getAllRealData: return "Live snapshot"
        case .getDeviceInfo: return "Device info"
        case .settingTime: return "Clock"
        case .appStartMeasurement: return "Measurement"
        case .appRealDataSwitch: return "Live streaming"
        default: return type.description
        }
    }

    // MARK: - Command queue

    /// Returns false when an identical request is already waiting (avoids pile-ups
    /// when the ring is slower than the refresh interval).
    @discardableResult
    private func enqueue(_ frame: YCFrame, timeout: TimeInterval = 4) -> Bool {
        guard transport.hasProtocolChannel else { return false }
        if queue.contains(where: { $0.frame == frame }) || inFlight?.frame == frame { return false }
        queue.append(QueuedCommand(frame: frame, timeout: timeout))
        updateSyncState()
        pump()
        return true
    }

    private func pump() {
        guard inFlight == nil, spacingTimer == nil, !queue.isEmpty, transport.state.isConnected else { return }
        let command = queue.removeFirst()
        inFlight = command
        log.frame(command.frame.data, outgoing: true)
        transport.write(command.frame.data)
        armInFlightTimer(command.timeout)
    }

    private func armInFlightTimer(_ seconds: TimeInterval) {
        inFlightTimer?.cancel()
        inFlightTimer = scheduler.after(seconds) { [weak self] in
            guard let self, let command = self.inFlight else { return }
            self.log.add("Timeout: \(Self.name(of: command.frame.dataType))", isError: true)
            self.recordResult(command.frame.dataType, .failed)
            self.completeInFlight()
        }
    }

    private func completeInFlight() {
        inFlightTimer?.cancel()
        inFlightTimer = nil
        inFlight = nil
        spacingTimer?.cancel()
        spacingTimer = scheduler.after(commandSpacing) { [weak self] in
            guard let self else { return }
            self.spacingTimer = nil
            self.pump()
            self.updateSyncState()
            self.queueDidDrainIfIdle()
        }
    }

    private func updateSyncState() {
        let syncing = inFlight?.isHistory == true || queue.contains { $0.isHistory }
        guard syncing != isSyncingHistory else { return }
        isSyncingHistory = syncing
        if !syncing {
            lastHistorySync = now
            realStore.save()
        }
    }

    private func queueDidDrainIfIdle() {
        guard inFlight == nil, queue.isEmpty else { return }
        onSyncFinished?()
        if backgroundCompletion != nil { finishBackgroundSync() }
    }

    private func resetQueue() {
        queue.removeAll()
        inFlight = nil
        inFlightTimer?.cancel()
        inFlightTimer = nil
        spacingTimer?.cancel()
        spacingTimer = nil
        isSyncingHistory = false
    }

    private func finishBackgroundSync() {
        backgroundDeadline?.cancel()
        backgroundDeadline = nil
        realStore.save()
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
    }

    // MARK: - Protocol events

    private func handle(_ output: YCProtocolSession.Output) {
        for reply in output.replies {
            log.frame(reply.data, outgoing: true)
            transport.write(reply.data)
        }
        for event in output.events {
            switch event {
            case .live(let patch, let pushed):
                realStore.applyLive(patch, pushed: pushed)
                if pushed { recordStreamedSamples(patch) }
            case .samples(let batch):
                realStore.apply(batch)
            case .deviceInfo(let info):
                realStore.setDeviceInfo(info)
            case .completed(let type, let result):
                recordResult(type, result)
                if inFlight?.frame.dataType == type { completeInFlight() }
            case .historyReceived(let type, let bytes, let records):
                recordTransfer(type, bytes: bytes, records: records)
            case .measurementFinished(let kind, let outcome):
                measurementFinished(kind, outcome)
            }
        }
        if session.crcErrors != crcErrors { crcErrors = session.crcErrors }
        // History arrives as many frames; keep the request alive while data flows.
        if session.isReceivingHistory, let command = inFlight, command.isHistory {
            armInFlightTimer(8)
        }
    }

    private func measurementFinished(_ kind: MeasurementKind?, _ outcome: MeasurementOutcome) {
        // A result without a kind while nothing is being measured can't be attributed.
        guard let finished = kind ?? activeMeasurement else {
            log.add("Ignored a measurement result of unknown kind (\(outcome.rawValue))")
            return
        }
        finishMeasurement(finished, outcome)
        guard outcome == .success, !isDemo else { return }
        // Results are stored on the ring; fetch them.
        let type: YCDataType
        switch finished {
        case .heartRate: type = .historyHeart
        case .bloodPressure: type = .historyBlood
        case .bloodOxygen: type = .historyBloodOxygen
        case .temperature: type = .historyTemperature
        case .respiratoryRate: type = .historyAll
        case .bloodGlucose, .uricAcid, .bloodKetone: type = .historyComprehensive
        }
        enqueue(YCCommand.history(type), timeout: 20)
        enqueue(YCCommand.allRealData)
    }

    private func finishMeasurement(_ kind: MeasurementKind, _ outcome: MeasurementOutcome) {
        log.add("\(kind.displayName): \(outcome.rawValue)")
        let startedAt = activeMeasurement == kind ? measurementStartedAt : nil
        measurementTimer?.cancel()
        measurementTimer = nil
        if activeMeasurement == kind {
            activeMeasurement = nil
            measurementStartedAt = nil
        }
        lastMeasurementOutcome = MeasurementResult(kind: kind, outcome: outcome,
                                                   startedAt: startedAt ?? now.addingTimeInterval(-measurementDuration), date: now)
        onMeasurementFinished?(kind, outcome)
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
        realStore.apply(batch)
    }

    private func shouldRecord(_ key: String, _ date: Date, every seconds: TimeInterval = 30) -> Bool {
        if let last = lastStreamedSample[key], date.timeIntervalSince(last) < seconds { return false }
        lastStreamedSample[key] = date
        return true
    }

    // MARK: - Time zone and clock changes

    private func observeSystemTime() {
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            systemObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemTimeDidChange() }
            })
        }
    }

    /// After travel or a DST change: ring timestamps are local wall-clock time, so the ring
    /// needs the new time now rather than at the next reconnect. (History is decoded with the
    /// auto-updating time zone.)
    func systemTimeDidChange() {
        log.add("Time zone or clock changed; setting the ring clock")
        store.refreshDay()
        guard !isDemo, transport.state.isConnected else { return }
        lastClockSync = nil
        syncClock()
    }

    // MARK: - Persistence of per-type sync dates

    private static func loadLastSync(_ defaults: UserDefaults) -> [YCDataType: Date] {
        let raw = defaults.dictionary(forKey: lastSyncKey) as? [String: Double] ?? [:]
        var result: [YCDataType: Date] = [:]
        for (key, value) in raw {
            if let rawType = UInt16(key) { result[YCDataType(rawValue: rawType)] = Date(timeIntervalSince1970: value) }
        }
        return result
    }

    private func saveLastSync() {
        let raw = Dictionary(uniqueKeysWithValues: historyLastSync.map { (String($0.key.rawValue), $0.value.timeIntervalSince1970) })
        defaults.set(raw, forKey: Self.lastSyncKey)
    }

    // MARK: - Demo mode

    private func startDemo() {
        let stale = demoStore.lastChange.map { now.timeIntervalSince($0) > 3600 } ?? true
        if demoStore.heartRate.isEmpty || stale {
            demoStore.replaceAll(with: DemoDataGenerator.history(now: now),
                                 live: DemoDataGenerator.live(previous: LiveSnapshot(), now: now),
                                 device: DemoDataGenerator.deviceInfo)
            lastHistorySync = now
        }
        demoTimer?.cancel()
        guard isForeground else { return }
        demoTimer = scheduler.every(TimeInterval(max(5, settings.liveRefreshSeconds))) { [weak self] in
            guard let self else { return }
            self.demoStore.applyLive(DemoDataGenerator.live(previous: self.demoStore.live, now: self.now), pushed: true)
            self.lastLivePoll = self.now
        }
    }

    private func stopDemo() {
        demoTimer?.cancel()
        demoTimer = nil
        if let kind = activeMeasurement { stopMeasurement(kind) }
    }

    private func finishDemoMeasurement(_ kind: MeasurementKind) {
        let now = self.now
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
        demoStore.apply(batch)
        measurementFinished(kind, .success)
    }
}

// MARK: - RingTransportDelegate

extension RingSyncEngine: RingTransportDelegate {
    func transportDidBecomeReady(_ transport: any RingTransport) {
        session.reset()
        resetQueue()
        commandStatus.removeAll()
        rrWindow.reset()
        log.add("Connected (\(transport.protocolName ?? "?"))", category: .ble)
        onRingContact?()
        guard !isDemo else { return }
        // A different ring than the one the sync dates belong to: start over.
        if let id = transport.connectedRingID?.uuidString, defaults.string(forKey: Self.lastSyncRingKey) != id {
            defaults.set(id, forKey: Self.lastSyncRingKey)
            historyLastSync.removeAll()
            saveLastSync()
        }
        if transport.hasProtocolChannel {
            lastClockSync = nil
            syncClock()
            if backgroundCompletion != nil {
                // Woken for background refresh: only the essentials.
                enqueueBackgroundEssentials()
            } else {
                enqueue(YCCommand.deviceInfo)
                pollLive(includeBattery: false)
                syncDueHistory()
                if settings.liveStreaming && isForeground { enqueueLiveStream(enabled: true) }
            }
        } else {
            lastGattBatteryRead = now
            if backgroundCompletion != nil { finishBackgroundSync() }
        }
        if isForeground { startTimers() }
    }

    func transportDidDisconnect(_ transport: any RingTransport) {
        log.add("Disconnected", category: .ble)
        stopTimers()
        resetQueue()
        session.reset()
        rrWindow.reset()
        realStore.clearWearState()
        if activeMeasurement != nil {
            measurementTimer?.cancel()
            measurementTimer = nil
            activeMeasurement = nil
            measurementStartedAt = nil
        }
    }

    func transport(_ transport: any RingTransport, didReceive data: Data) {
        guard !isDemo else { return }
        log.frame(data, outgoing: false)
        onRingContact?()
        handle(session.receive(data))
    }

    /// Standard Heart Rate Measurement. RR intervals are collected over a rolling minute and
    /// HRV (RMSSD) is reported only once there are enough clean beats.
    func transport(_ transport: any RingTransport, didReceiveHeartRate bpm: Int, rrIntervals: [Double]) {
        guard !isDemo, let bpm = Plausible.heartRate(bpm) else { return }
        let now = self.now
        var patch = LiveSnapshot(updatedAt: now)
        patch.heartRate = bpm
        var batch = HealthBatch()
        if shouldRecord("gatt-hr", now) {
            batch.heartRate.append(HeartRateSample(date: now, bpm: bpm))
        }
        rrWindow.add(rrIntervals, at: now)
        if let rmssd = rrWindow.rmssd, let hrv = Plausible.hrv(rmssd) {
            patch.hrv = hrv.rounded()
            patch.hrvKind = .rmssd
            if shouldRecord("gatt-hrv", now, every: 60) {
                batch.hrv.append(HRVSample(date: now, milliseconds: hrv.rounded(), kind: .rmssd))
            }
        }
        realStore.applyLive(patch, pushed: true)
        realStore.apply(batch)
    }

    func transport(_ transport: any RingTransport, didReadBattery percent: Int) {
        guard !isDemo else { return }
        var patch = LiveSnapshot()
        patch.batteryPercent = min(100, percent)
        realStore.applyLive(patch, pushed: true)
    }
}
