import Foundation
import Observation

/// A value together with the time it was measured.
struct Reading<Value> {
    var value: Value
    var date: Date
}

extension Reading: Equatable where Value: Equatable {}
extension Reading: Sendable where Value: Sendable {}

/// A point for charts and daily/hourly totals.
struct DatedValue: Identifiable, Hashable, Sendable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Today's activity totals.
struct ActivityTotals: Equatable, Sendable {
    var steps = 0
    var distanceMeters = 0
    var kilocalories = 0
}

/// Live values that carry their own "last reported" time.
enum LiveField: String, Codable, CaseIterable, Sendable {
    case heartRate, bloodPressure, bloodOxygen, temperature, respiration, hrv, stress, activity

    func isPresent(in patch: LiveSnapshot) -> Bool {
        switch self {
        case .heartRate: return patch.heartRate != nil
        case .bloodPressure: return patch.systolic != nil && patch.diastolic != nil
        case .bloodOxygen: return patch.bloodOxygen != nil
        case .temperature: return patch.temperature != nil
        case .respiration: return patch.respiratoryRate != nil
        case .hrv: return patch.hrv != nil
        case .stress: return patch.stress != nil
        case .activity: return patch.stepsToday != nil
        }
    }

    /// Whether `patch` carries a different value for this field than `current`.
    func differs(_ patch: LiveSnapshot, from current: LiveSnapshot) -> Bool {
        switch self {
        case .heartRate: return patch.heartRate != current.heartRate
        case .bloodPressure: return patch.systolic != current.systolic || patch.diastolic != current.diastolic
        case .bloodOxygen: return patch.bloodOxygen != current.bloodOxygen
        case .temperature: return patch.temperature != current.temperature
        case .respiration: return patch.respiratoryRate != current.respiratoryRate
        case .hrv: return patch.hrv != current.hrv || patch.hrvKind != current.hrvKind
        case .stress: return patch.stress != current.stress
        case .activity: return patch.stepsToday != current.stepsToday
        }
    }
}

/// Everything the UI shows.
///
/// Samples from the ring are merged, de-duplicated and trimmed to `retentionDays`, and
/// persisted as JSON so the app opens with the last data even before the ring reconnects.
///
/// Values the views need (latest readings, 24 h series, today's totals, resting heart rate…)
/// are computed once per data change and stored, and each is only reassigned when it actually
/// changes. With `@Observable`, a view then re-renders only when something it shows changed,
/// not on every live poll.
@MainActor
@Observable
final class HealthDataStore {
    // MARK: Raw data

    private(set) var live = LiveSnapshot()
    /// When the ring last reported each live value. A patch usually carries only some fields,
    /// and a poll repeats the ring's last value, so one snapshot-wide timestamp would make
    /// old values look fresh.
    private(set) var liveDates: [LiveField: Date] = [:]
    private(set) var deviceInfo: DeviceInfo?
    private(set) var heartRate: [HeartRateSample] = []
    private(set) var bloodPressure: [BloodPressureSample] = []
    private(set) var bloodOxygen: [BloodOxygenSample] = []
    private(set) var temperature: [TemperatureSample] = []
    private(set) var hrv: [HRVSample] = []
    private(set) var respiration: [RespirationSample] = []
    private(set) var bodyMetrics: [BodyMetricsSample] = []
    private(set) var activity: [ActivitySample] = []
    private(set) var sleep: [SleepSession] = []
    private(set) var metabolic: [MetabolicSample] = []
    /// When any value last changed.
    private(set) var lastChange: Date?

    // MARK: Derived (recomputed on change)

    private(set) var latestHeartRate: Reading<Int>?
    private(set) var latestBloodPressure: Reading<BloodPressureSample>?
    private(set) var latestBloodOxygen: Reading<Int>?
    private(set) var latestTemperature: Reading<Double>?
    private(set) var latestRespiration: Reading<Int>?
    /// Latest HRV of `hrvKind`, the kind the HRV page charts.
    private(set) var latestHRV: Reading<Double>?
    private(set) var latestStress: Reading<Double>?
    private(set) var latestBodyMetrics: BodyMetricsSample?
    private(set) var latestMetabolic: MetabolicSample?
    private(set) var batteryPercent: Int?
    private(set) var isCharging = false
    /// From the ring's wear-state upload; nil when unknown.
    private(set) var isWorn: Bool?

    private(set) var heartRateDay: [HeartRateSample] = []
    /// Resting heart rate estimate: 10th percentile over the last 24 h, excluding sleep and
    /// intervals with walking.
    private(set) var restingHeartRate: Int?
    /// The HRV statistic shown (RMSSD, else SDNN, else the ring's own value); never mixed.
    private(set) var hrvKind: HRVKind?
    private(set) var hrvDay: [HRVSample] = []
    private(set) var bloodPressureDay: [BloodPressureSample] = []
    private(set) var bloodOxygenDay: [BloodOxygenSample] = []
    private(set) var temperatureDay: [TemperatureSample] = []
    private(set) var respirationDay: [RespirationSample] = []
    private(set) var bodyMetricsDay: [BodyMetricsSample] = []
    private(set) var today = ActivityTotals()
    private(set) var hourlyStepsToday: [DatedValue] = []
    /// Step totals for the last seven days, oldest first; days without data are zero.
    private(set) var dailySteps: [DatedValue] = []
    /// The most recent main sleep (the longest session that ended in the last 36 h).
    private(set) var lastNightSleep: SleepSession?
    /// Hours asleep per night for the last seven nights (keyed by the morning), oldest first;
    /// nights without data are zero, like `dailySteps`.
    private(set) var weeklySleep: [DatedValue] = []
    /// Start of the current day. Changes at midnight even when no data arrives, so "today"
    /// values roll over on screen.
    private(set) var todayStart: Date

    let retentionDays = 14

    /// Called with the samples each `apply` added or changed (used by the HealthKit export).
    @ObservationIgnored var onNewSamples: (@MainActor (HealthBatch) -> Void)?
    /// Called after any committed change (used by the widget and notifications).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let files: Files?
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private let log: DiagnosticsLog?
    @ObservationIgnored private var saveTimer: (any Cancellable)?
    @ObservationIgnored private var historyDirty = false
    @ObservationIgnored private var liveDirty = false
    @ObservationIgnored private var dayObserver: (any NSObjectProtocol)?

    private var calendar: Calendar { .current }
    private var now: Date { scheduler.now }

    /// - Parameters:
    ///   - fileName: base name of the cache in Application Support; `nil` keeps everything in
    ///     memory (demo mode).
    ///   - directory: overrides the cache directory (tests).
    init(fileName: String? = "health-store", directory: URL? = nil,
         scheduler: any Scheduling = SystemScheduler.shared, log: DiagnosticsLog? = nil,
         observesDayChanges: Bool = true) {
        self.scheduler = scheduler
        self.log = log
        todayStart = Calendar.current.startOfDay(for: scheduler.now)
        if let fileName {
            let base = directory
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            files = Files(directory: base, name: fileName)
            load()
        } else {
            files = nil
        }
        refreshAll()
        if observesDayChanges {
            dayObserver = NotificationCenter.default.addObserver(
                forName: .NSCalendarDayChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDay() }
            }
        }
    }

    // MARK: - Ingest

    /// Merges a batch of samples. Returns the samples that were new or changed.
    @discardableResult
    func apply(_ batch: HealthBatch) -> HealthBatch {
        guard !batch.isEmpty else { return HealthBatch() }
        let cutoff = retentionCutoff
        var added = HealthBatch()
        merge(\.heartRate, batch.heartRate, cutoff, into: &added.heartRate)
        merge(\.bloodPressure, batch.bloodPressure, cutoff, into: &added.bloodPressure)
        merge(\.bloodOxygen, batch.bloodOxygen, cutoff, into: &added.bloodOxygen)
        merge(\.temperature, batch.temperature, cutoff, into: &added.temperature)
        merge(\.hrv, batch.hrv, cutoff, into: &added.hrv)
        merge(\.respiration, batch.respiration, cutoff, into: &added.respiration)
        merge(\.bodyMetrics, batch.bodyMetrics, cutoff, into: &added.bodyMetrics)
        merge(\.activity, batch.activity, cutoff, into: &added.activity)
        merge(\.sleep, batch.sleep, cutoff, into: &added.sleep)
        merge(\.metabolic, batch.metabolic, cutoff, into: &added.metabolic)
        // Re-downloaded history is usually identical; then nothing is published or saved.
        guard !added.isEmpty else { return added }
        lastChange = now
        historyDirty = true
        refreshAll()
        scheduleSave()
        onNewSamples?(added)
        onChange?()
        return added
    }

    /// Applies live values. `pushed` is true for values the ring streamed by itself (a new
    /// measurement) and false for poll replies, which repeat the ring's last value: an
    /// unchanged polled value keeps the date it was first seen, so a morning blood-pressure
    /// reading doesn't show as "just now" all day.
    func applyLive(_ patch: LiveSnapshot, pushed: Bool) {
        let at = patch.updatedAt ?? now
        var dates = liveDates
        for field in LiveField.allCases where field.isPresent(in: patch) {
            if pushed || dates[field] == nil || field.differs(patch, from: live) {
                dates[field] = at
            }
        }
        var updated = live
        updated.apply(patch)
        // `updatedAt` alone changing (every poll) is not a change worth publishing or saving.
        updated.updatedAt = live.updatedAt
        guard updated != live || dates != liveDates else { return }
        updated.updatedAt = at
        live = updated
        if dates != liveDates { liveDates = dates }
        lastChange = now
        liveDirty = true
        let shownKind = hrvKind
        refreshLatest()
        refreshActivity()
        if hrvKind != shownKind { refreshSeries() }
        scheduleSave()
        onChange?()
    }

    func setDeviceInfo(_ info: DeviceInfo) {
        guard info != deviceInfo else { return }
        deviceInfo = info
        liveDirty = true
        refreshLatest()
        scheduleSave()
        onChange?()
    }

    /// The wear state is only pushed when it changes, so it is unknown after a disconnect.
    func clearWearState() {
        guard live.isWorn != nil else { return }
        live.isWorn = nil
        liveDirty = true
        refreshLatest()
        scheduleSave()
    }

    func eraseAll() {
        live = LiveSnapshot()
        liveDates = [:]
        deviceInfo = nil
        heartRate = []
        bloodPressure = []
        bloodOxygen = []
        temperature = []
        hrv = []
        respiration = []
        bodyMetrics = []
        activity = []
        sleep = []
        metabolic = []
        lastChange = nil
        saveTimer?.cancel()
        saveTimer = nil
        historyDirty = false
        liveDirty = false
        files?.removeAll()
        refreshAll()
        onChange?()
    }

    /// Replaces everything at once (demo data).
    func replaceAll(with batch: HealthBatch, live snapshot: LiveSnapshot, device: DeviceInfo?) {
        eraseAll()
        deviceInfo = device
        applyLive(snapshot, pushed: true)
        apply(batch)
    }

    /// Re-evaluates "today" and the 24 h windows. Called at midnight and when the app comes
    /// to the foreground, since time passing alone doesn't change any stored value.
    func refreshDay() {
        let start = calendar.startOfDay(for: now)
        if start != todayStart {
            todayStart = start
            trimExpired()
        }
        refreshAll()
    }

    /// Newest sample wins for the same `mergeKey`; samples older than `cutoff` and
    /// future-dated samples (a ring with a wrong clock) are dropped.
    static func merge<T: TimedSample>(_ existing: [T], _ incoming: [T], cutoff: Date,
                                      now: Date = Date()) -> (merged: [T], added: [T]) {
        guard !incoming.isEmpty else { return (existing, []) }
        let latestAllowed = now.addingTimeInterval(3600)
        var byKey: [Int: T] = [:]
        for sample in existing where sample.date >= cutoff {
            byKey[sample.mergeKey] = sample
        }
        var added: [Int: T] = [:]
        for sample in incoming where sample.date >= cutoff && sample.date <= latestAllowed {
            let key = sample.mergeKey
            if byKey[key] != sample {
                byKey[key] = sample
                added[key] = sample
            }
        }
        guard !added.isEmpty else { return (existing, []) }
        let merged = byKey.values.sorted { $0.date < $1.date || ($0.date == $1.date && $0.mergeKey < $1.mergeKey) }
        return (merged, added.values.sorted { $0.date < $1.date })
    }

    private func merge<T: TimedSample>(_ keyPath: ReferenceWritableKeyPath<HealthDataStore, [T]>, _ incoming: [T],
                                       _ cutoff: Date, into added: inout [T]) {
        guard !incoming.isEmpty else { return }
        let result = Self.merge(self[keyPath: keyPath], incoming, cutoff: cutoff, now: now)
        guard !result.added.isEmpty else { return }
        self[keyPath: keyPath] = result.merged
        added = result.added
    }

    private var retentionCutoff: Date {
        calendar.date(byAdding: .day, value: -retentionDays, to: now) ?? .distantPast
    }

    private func trimExpired() {
        let cutoff = retentionCutoff
        func trim<T: TimedSample>(_ keyPath: ReferenceWritableKeyPath<HealthDataStore, [T]>) {
            let kept = self[keyPath: keyPath].filter { $0.date >= cutoff }
            if kept.count != self[keyPath: keyPath].count {
                self[keyPath: keyPath] = kept
                historyDirty = true
            }
        }
        trim(\.heartRate)
        trim(\.bloodPressure)
        trim(\.bloodOxygen)
        trim(\.temperature)
        trim(\.hrv)
        trim(\.respiration)
        trim(\.bodyMetrics)
        trim(\.activity)
        trim(\.sleep)
        trim(\.metabolic)
        if historyDirty { scheduleSave() }
    }

    // MARK: - Derived values

    /// Assigns only when the value changed, so observers of unchanged values stay quiet.
    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<HealthDataStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func refreshAll() {
        refreshLatest()
        refreshActivity()
        refreshSeries()
    }

    private func refreshLatest() {
        set(\.latestHeartRate, latest(.heartRate, live: live.heartRate,
                                      history: heartRate.last.map { Reading(value: $0.bpm, date: $0.date) }))
        var liveBP: BloodPressureSample?
        if let sys = live.systolic, let dia = live.diastolic, let at = liveDates[.bloodPressure] {
            liveBP = BloodPressureSample(date: at, systolic: sys, diastolic: dia, heartRate: nil)
        }
        set(\.latestBloodPressure, latest(.bloodPressure, live: liveBP,
                                          history: bloodPressure.last.map { Reading(value: $0, date: $0.date) }))
        set(\.latestBloodOxygen, latest(.bloodOxygen, live: live.bloodOxygen,
                                        history: bloodOxygen.last.map { Reading(value: $0.percent, date: $0.date) }))
        set(\.latestTemperature, latest(.temperature, live: live.temperature,
                                        history: temperature.last.map { Reading(value: $0.celsius, date: $0.date) }))
        set(\.latestRespiration, latest(.respiration, live: live.respiratoryRate,
                                        history: respiration.last.map { Reading(value: $0.breathsPerMinute, date: $0.date) }))
        let kind = preferredHRVKind
        set(\.hrvKind, kind)
        let hrvHistory = hrv.last(where: { $0.kind == kind }).map { Reading(value: $0.milliseconds, date: $0.date) }
        set(\.latestHRV, latest(.hrv, live: live.hrvKind == kind ? live.hrv : nil, history: hrvHistory))
        let stressSample = bodyMetrics.last(where: { $0.stress != nil })
        set(\.latestStress, latest(.stress, live: live.stress, history: stressSample.flatMap { sample in
            sample.stress.map { Reading(value: $0, date: sample.date) }
        }))
        set(\.latestBodyMetrics, bodyMetrics.last)
        set(\.latestMetabolic, metabolic.last)
        set(\.batteryPercent, live.batteryPercent ?? deviceInfo?.batteryPercent)
        set(\.isCharging, deviceInfo?.isCharging ?? false)
        set(\.isWorn, live.isWorn)
    }

    /// The live value when the ring reported it at least as recently as the newest stored sample.
    private func latest<V>(_ field: LiveField, live value: V?, history: Reading<V>?) -> Reading<V>? {
        if let value, let at = liveDates[field], history.map({ at >= $0.date }) ?? true {
            return Reading(value: value, date: at)
        }
        return history
    }

    /// RMSSD when the ring reports it, else SDNN, else the ring's own HRV value.
    private var preferredHRVKind: HRVKind? {
        let recentStart = now.addingTimeInterval(-7 * 86_400)
        let recentKinds = Set(hrv.filter { $0.date >= recentStart }.map(\.kind))
            .union(live.hrvKind.map { [$0] } ?? [])
        return [HRVKind.rmssd, .sdnn, .vendor].first { recentKinds.contains($0) }
            ?? [HRVKind.rmssd, .sdnn, .vendor].first { kind in hrv.contains { $0.kind == kind } }
    }

    private func refreshActivity() {
        let todays = activity.filter { $0.date >= todayStart }
        let liveToday = liveIsFromToday
        var totals = ActivityTotals()
        totals.steps = max(liveToday ? (live.stepsToday ?? 0) : 0, todays.reduce(0) { $0 + $1.steps })
        totals.distanceMeters = max(liveToday ? (live.distanceTodayMeters ?? 0) : 0, todays.reduce(0) { $0 + $1.distanceMeters })
        totals.kilocalories = max(liveToday ? (live.kilocaloriesToday ?? 0) : 0, todays.reduce(0) { $0 + $1.kilocalories })
        set(\.today, totals)

        var hourly: [Date: Int] = [:]
        for sample in todays {
            let hour = calendar.dateInterval(of: .hour, for: sample.date)?.start ?? sample.date
            hourly[hour, default: 0] += sample.steps
        }
        set(\.hourlyStepsToday, hourly.map { DatedValue(date: $0.key, value: Double($0.value)) }.sorted { $0.date < $1.date })

        var daily: [Date: Int] = [:]
        for sample in activity {
            daily[calendar.startOfDay(for: sample.date), default: 0] += sample.steps
        }
        daily[todayStart] = totals.steps
        // After midnight the ring's live total belongs to the day it was reported; keep it in
        // the 7-day chart until history for that day arrives.
        if !liveToday, let at = liveDates[.activity], let liveSteps = live.stepsToday {
            let day = calendar.startOfDay(for: at)
            daily[day] = max(daily[day] ?? 0, liveSteps)
        }
        set(\.dailySteps, lastSevenDays.map { DatedValue(date: $0, value: Double(daily[$0] ?? 0)) })
    }

    private var liveIsFromToday: Bool {
        guard let at = liveDates[.activity] else { return false }
        return at >= todayStart
    }

    private var lastSevenDays: [Date] {
        (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: todayStart) }
    }

    private func refreshSeries() {
        let dayStart = now.addingTimeInterval(-24 * 3600)
        func day<T: TimedSample>(_ samples: [T]) -> [T] {
            // Samples are sorted, so the window is a suffix.
            let first = samples.firstIndex { $0.date >= dayStart } ?? samples.endIndex
            return Array(samples[first...])
        }
        let hrDay = day(heartRate)
        set(\.heartRateDay, hrDay)
        set(\.restingHeartRate, Self.restingHeartRate(hrDay, sleep: sleep.filter { $0.end >= dayStart },
                                                        activity: activity.filter { $0.end >= dayStart }))
        set(\.hrvDay, day(hrv).filter { $0.kind == hrvKind })
        set(\.bloodPressureDay, day(bloodPressure))
        set(\.bloodOxygenDay, day(bloodOxygen))
        set(\.temperatureDay, day(temperature))
        set(\.respirationDay, day(respiration))
        set(\.bodyMetricsDay, day(bodyMetrics))

        let recentSleep = sleep.filter { $0.end >= now.addingTimeInterval(-36 * 3600) }
        set(\.lastNightSleep, recentSleep.max { $0.asleepSeconds < $1.asleepSeconds } ?? sleep.last)
        var nights: [Date: Double] = [:]
        for session in sleep {
            nights[calendar.startOfDay(for: session.end), default: 0] += session.asleepSeconds / 3600
        }
        set(\.weeklySleep, lastSevenDays.map { DatedValue(date: $0, value: nights[$0] ?? 0) })
    }

    /// 10th percentile of heart rate, leaving out sleep (lower than resting HR while awake)
    /// and intervals with more than 10 steps a minute.
    static func restingHeartRate(_ samples: [HeartRateSample], sleep: [SleepSession],
                                 activity: [ActivitySample]) -> Int? {
        let active = activity.filter { interval in
            let minutes = max(1, interval.end.timeIntervalSince(interval.date) / 60)
            return Double(interval.steps) / minutes > 10
        }
        let values = samples.filter { sample in
            !sleep.contains { sample.date >= $0.date && sample.date <= $0.end }
                && !active.contains { sample.date >= $0.date && sample.date < $0.end }
        }.map(\.bpm).sorted()
        guard values.count >= 5 else { return nil }
        return values[values.count / 10]
    }

    // MARK: - Persistence

    /// Bump when the meaning of cached values changes.
    /// 2: body-data HRV/stress are 0–10 indices (version 1 stored the HRV index as milliseconds).
    /// 3: HRV samples carry their kind (RMSSD, SDNN or the ring's own value).
    static let schemaVersion = 3

    /// The history file. Live values moved to their own small file in version 3; they are
    /// still read from here for older caches.
    private struct Snapshot: Codable, Sendable {
        var schemaVersion: Int?
        var live: LiveSnapshot?
        var deviceInfo: DeviceInfo?
        var heartRate: [HeartRateSample]
        var bloodPressure: [BloodPressureSample]
        var bloodOxygen: [BloodOxygenSample]
        var temperature: [TemperatureSample]
        var hrv: [HRVSample]
        var respiration: [RespirationSample]
        var bodyMetrics: [BodyMetricsSample]
        var activity: [ActivitySample]
        var sleep: [SleepSession]
        var metabolic: [MetabolicSample]
        var lastChange: Date?
        var liveDates: [LiveField: Date]?
    }

    /// Written on every live change, so it stays small.
    private struct LiveState: Codable, Sendable {
        var schemaVersion: Int
        var live: LiveSnapshot
        var liveDates: [LiveField: Date]
        var deviceInfo: DeviceInfo?
    }

    private struct Files: Sendable {
        let history: URL
        let live: URL
        var backup: URL { history.appendingPathExtension("bak") }

        init(directory: URL, name: String) {
            history = directory.appendingPathComponent("\(name).json")
            live = directory.appendingPathComponent("\(name)-live.json")
        }

        func removeAll() {
            try? FileManager.default.removeItem(at: history)
            try? FileManager.default.removeItem(at: live)
        }
    }

    /// Encoding and writing happen off the main thread, one at a time and in order.
    private static let ioQueue = DispatchQueue(label: "HealthDataStore.io", qos: .utility)

    private func scheduleSave() {
        guard files != nil, saveTimer == nil else { return }
        saveTimer = scheduler.after(2) { [weak self] in
            self?.saveTimer = nil
            self?.save()
        }
    }

    /// Writes whatever changed. `synchronously` waits for the write (used when the app is
    /// about to be suspended).
    func save(synchronously: Bool = false) {
        saveTimer?.cancel()
        saveTimer = nil
        guard let files, historyDirty || liveDirty else { return }
        let history: Snapshot? = historyDirty ? Snapshot(
            schemaVersion: Self.schemaVersion, live: nil, deviceInfo: deviceInfo, heartRate: heartRate,
            bloodPressure: bloodPressure, bloodOxygen: bloodOxygen, temperature: temperature, hrv: hrv,
            respiration: respiration, bodyMetrics: bodyMetrics, activity: activity, sleep: sleep,
            metabolic: metabolic, lastChange: lastChange, liveDates: nil) : nil
        let liveState = LiveState(schemaVersion: Self.schemaVersion, live: live, liveDates: liveDates, deviceInfo: deviceInfo)
        historyDirty = false
        liveDirty = false
        let log = log
        let work: @Sendable () -> Void = {
            do {
                let encoder = JSONEncoder()
                if let history {
                    try encoder.encode(history).write(to: files.history, options: .atomic)
                }
                try encoder.encode(liveState).write(to: files.live, options: .atomic)
            } catch {
                Task { @MainActor in log?.add("Saving the cache failed: \(error.localizedDescription)", category: .store, isError: true) }
                Log.store.error("Save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if synchronously {
            Self.ioQueue.sync(execute: work)
        } else {
            Self.ioQueue.async(execute: work)
        }
    }

    private func load() {
        guard let files else { return }
        let decoder = JSONDecoder()
        var snapshot: Snapshot?
        if let data = try? Data(contentsOf: files.history) {
            do {
                snapshot = try decoder.decode(Snapshot.self, from: data)
            } catch {
                // Keep the unreadable file for diagnosis instead of overwriting it on the next save.
                try? FileManager.default.removeItem(at: files.backup)
                try? FileManager.default.copyItem(at: files.history, to: files.backup)
                let message = "Cached history could not be read (kept as .bak): \(error)"
                Log.store.error("\(message, privacy: .public)")
                log?.add(message, category: .store, isError: true)
            }
        }
        if let snapshot {
            deviceInfo = snapshot.deviceInfo
            heartRate = snapshot.heartRate
            bloodPressure = snapshot.bloodPressure
            bloodOxygen = snapshot.bloodOxygen
            temperature = snapshot.temperature
            hrv = snapshot.hrv
            respiration = snapshot.respiration
            bodyMetrics = snapshot.bodyMetrics
            activity = snapshot.activity
            sleep = snapshot.sleep
            metabolic = snapshot.metabolic
            lastChange = snapshot.lastChange
            live = snapshot.live ?? LiveSnapshot()
            liveDates = snapshot.liveDates ?? [:]
        }
        // Caches from before schema versioning have no version field: that is version 1.
        var version = snapshot.map { $0.schemaVersion ?? 1 } ?? Self.schemaVersion
        if let data = try? Data(contentsOf: files.live), let state = try? decoder.decode(LiveState.self, from: data) {
            live = state.live
            liveDates = state.liveDates
            deviceInfo = state.deviceInfo ?? deviceInfo
            version = min(version, state.schemaVersion)
        } else if snapshot == nil {
            return
        }
        migrate(from: version)
    }

    private func migrate(from version: Int) {
        guard version < Self.schemaVersion else { return }
        if version < 2 {
            // Version 1 mixed the ring's inverted HRV index into the HRV (ms) series and read
            // stress on a 0–100 scale. Drop those values; the ring still holds its history and
            // the next sync restores them with the right meaning.
            bodyMetrics = []
            live.stress = nil
            liveDates[.stress] = nil
        }
        // Before version 3, HRV samples didn't record whether they were RMSSD, SDNN or the
        // ring's own value; they are re-synced with their kind.
        hrv = []
        live.hrv = nil
        live.hrvKind = nil
        liveDates[.hrv] = nil
        historyDirty = true
        liveDirty = true
        log?.add("Migrated the cache from version \(version) to \(Self.schemaVersion)", category: .store)
        scheduleSave()
    }
}
