import Foundation

/// A value together with the time it was measured.
struct Reading<Value> {
    var value: Value
    var date: Date
}

/// Everything the UI shows. Samples from the ring are merged, de-duplicated by timestamp,
/// trimmed to `retentionDays`, and persisted as JSON so the app opens with the last data
/// even before the ring reconnects.
final class HealthDataStore: ObservableObject {
    @Published private(set) var live = LiveSnapshot()
    @Published private(set) var deviceInfo: DeviceInfo?
    @Published private(set) var heartRate: [HeartRateSample] = []
    @Published private(set) var bloodPressure: [BloodPressureSample] = []
    @Published private(set) var bloodOxygen: [BloodOxygenSample] = []
    @Published private(set) var temperature: [TemperatureSample] = []
    @Published private(set) var hrv: [HRVSample] = []
    @Published private(set) var respiration: [RespirationSample] = []
    @Published private(set) var bodyMetrics: [BodyMetricsSample] = []
    @Published private(set) var activity: [ActivitySample] = []
    @Published private(set) var sleep: [SleepSession] = []
    @Published private(set) var metabolic: [MetabolicSample] = []
    /// When any value last changed (drives the "Updated … ago" labels).
    @Published private(set) var lastChange: Date?

    let retentionDays = 14

    private let fileURL: URL
    private var saveTimer: Timer?

    init(fileName: String = "health-store.json") {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(fileName)
        load()
    }

    // MARK: - Ingest

    func apply(_ batch: HealthBatch) {
        guard !batch.isEmpty else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        heartRate = Self.merge(heartRate, batch.heartRate, cutoff: cutoff)
        bloodPressure = Self.merge(bloodPressure, batch.bloodPressure, cutoff: cutoff)
        bloodOxygen = Self.merge(bloodOxygen, batch.bloodOxygen, cutoff: cutoff)
        temperature = Self.merge(temperature, batch.temperature, cutoff: cutoff)
        hrv = Self.merge(hrv, batch.hrv, cutoff: cutoff)
        respiration = Self.merge(respiration, batch.respiration, cutoff: cutoff)
        bodyMetrics = Self.merge(bodyMetrics, batch.bodyMetrics, cutoff: cutoff)
        activity = Self.merge(activity, batch.activity, cutoff: cutoff)
        sleep = Self.merge(sleep, batch.sleep, cutoff: cutoff)
        metabolic = Self.merge(metabolic, batch.metabolic, cutoff: cutoff)
        lastChange = Date()
        scheduleSave()
    }

    func applyLive(_ patch: LiveSnapshot) {
        var updated = live
        updated.apply(patch)
        guard updated != live else { return }
        live = updated
        lastChange = Date()
        scheduleSave()
    }

    func setDeviceInfo(_ info: DeviceInfo) {
        guard info != deviceInfo else { return }
        deviceInfo = info
        scheduleSave()
    }

    func eraseAll() {
        live = LiveSnapshot()
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
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Replaces everything at once (used by demo mode).
    func replaceAll(with batch: HealthBatch, live snapshot: LiveSnapshot, device: DeviceInfo?) {
        eraseAll()
        live = snapshot
        deviceInfo = device
        apply(batch)
    }

    /// Newest sample wins for identical timestamps (to the second); future-dated samples
    /// (a ring with a wrong clock) are dropped.
    static func merge<T: TimedSample>(_ existing: [T], _ incoming: [T], cutoff: Date) -> [T] {
        guard !incoming.isEmpty else { return existing }
        let latestAllowed = Date().addingTimeInterval(3600)
        var byKey: [Int: T] = [:]
        for sample in existing where sample.date >= cutoff {
            byKey[Int(sample.date.timeIntervalSince1970)] = sample
        }
        for sample in incoming where sample.date >= cutoff && sample.date <= latestAllowed {
            byKey[Int(sample.date.timeIntervalSince1970)] = sample
        }
        return byKey.values.sorted { $0.date < $1.date }
    }

    // MARK: - Derived values used by the views

    var todayStart: Date { Calendar.current.startOfDay(for: Date()) }

    func last24h<T: TimedSample>(_ samples: [T]) -> [T] {
        let start = Date().addingTimeInterval(-24 * 3600)
        return samples.filter { $0.date >= start }
    }

    func today<T: TimedSample>(_ samples: [T]) -> [T] {
        let start = todayStart
        return samples.filter { $0.date >= start }
    }

    var latestHeartRate: Reading<Int>? {
        latest(live: live.heartRate, history: heartRate.last.map { Reading(value: $0.bpm, date: $0.date) })
    }

    var latestBloodPressure: Reading<BloodPressureSample>? {
        let history = bloodPressure.last.map { Reading(value: $0, date: $0.date) }
        var fromLive: BloodPressureSample?
        if let sys = live.systolic, let dia = live.diastolic, let at = live.updatedAt {
            fromLive = BloodPressureSample(date: at, systolic: sys, diastolic: dia, heartRate: live.heartRate)
        }
        return latest(live: fromLive, history: history)
    }

    var latestBloodOxygen: Reading<Int>? {
        latest(live: live.bloodOxygen, history: bloodOxygen.last.map { Reading(value: $0.percent, date: $0.date) })
    }

    var latestTemperature: Reading<Double>? {
        latest(live: live.temperature, history: temperature.last.map { Reading(value: $0.celsius, date: $0.date) })
    }

    var latestRespiration: Reading<Int>? {
        latest(live: live.respiratoryRate, history: respiration.last.map { Reading(value: $0.breathsPerMinute, date: $0.date) })
    }

    var latestHRV: Reading<Double>? {
        latest(live: live.hrv, history: hrv.last.map { Reading(value: $0.milliseconds, date: $0.date) })
    }

    var latestStress: Reading<Double>? {
        let history = bodyMetrics.last(where: { $0.stress != nil })
        return latest(live: live.stress, history: history.flatMap { sample in
            sample.stress.map { Reading(value: $0, date: sample.date) }
        })
    }

    var latestBodyMetrics: BodyMetricsSample? { bodyMetrics.last }
    var latestMetabolic: MetabolicSample? { metabolic.last }

    /// The live value when it is at least as new as the newest stored sample.
    private func latest<V>(live value: V?, history: Reading<V>?) -> Reading<V>? {
        if let value, let at = live.updatedAt, history.map({ at >= $0.date }) ?? true {
            return Reading(value: value, date: at)
        }
        return history
    }

    var stepsToday: Int {
        let fromHistory = today(activity).reduce(0) { $0 + $1.steps }
        return max(liveIsFromToday ? (live.stepsToday ?? 0) : 0, fromHistory)
    }

    var distanceTodayMeters: Int {
        let fromHistory = today(activity).reduce(0) { $0 + $1.distanceMeters }
        return max(liveIsFromToday ? (live.distanceTodayMeters ?? 0) : 0, fromHistory)
    }

    var kilocaloriesToday: Int {
        let fromHistory = today(activity).reduce(0) { $0 + $1.kilocalories }
        return max(liveIsFromToday ? (live.kilocaloriesToday ?? 0) : 0, fromHistory)
    }

    private var liveIsFromToday: Bool {
        guard let at = live.updatedAt else { return false }
        return at >= todayStart
    }

    /// Steps per hour for today's chart.
    var hourlyStepsToday: [(hour: Date, steps: Int)] {
        let calendar = Calendar.current
        var buckets: [Date: Int] = [:]
        for sample in today(activity) {
            let hour = calendar.dateInterval(of: .hour, for: sample.date)?.start ?? sample.date
            buckets[hour, default: 0] += sample.steps
        }
        return buckets.map { (hour: $0.key, steps: $0.value) }.sorted { $0.hour < $1.hour }
    }

    /// Daily step totals for the last seven days (oldest first).
    var dailySteps: [(day: Date, steps: Int)] {
        let calendar = Calendar.current
        var buckets: [Date: Int] = [:]
        for sample in activity {
            buckets[calendar.startOfDay(for: sample.date), default: 0] += sample.steps
        }
        let today = calendar.startOfDay(for: Date())
        if liveIsFromToday, let liveSteps = live.stepsToday {
            buckets[today] = max(buckets[today] ?? 0, liveSteps)
        }
        return (0..<7).reversed().compactMap { offset -> (day: Date, steps: Int)? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day: day, steps: buckets[day] ?? 0)
        }
    }

    /// The most recent main sleep (the longest session that ended in the last 36 h).
    var lastNightSleep: SleepSession? {
        let recent = sleep.filter { $0.end >= Date().addingTimeInterval(-36 * 3600) }
        return recent.max { $0.asleepSeconds < $1.asleepSeconds } ?? sleep.last
    }

    /// Lowest 10th-percentile heart rate over the last 24 h, a common resting-HR estimate.
    var restingHeartRate: Int? {
        let values = last24h(heartRate).map(\.bpm).sorted()
        guard values.count >= 5 else { return values.first }
        return values[values.count / 10]
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var live: LiveSnapshot
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
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.save()
        }
    }

    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        let snapshot = Snapshot(
            live: live, deviceInfo: deviceInfo, heartRate: heartRate, bloodPressure: bloodPressure,
            bloodOxygen: bloodOxygen, temperature: temperature, hrv: hrv, respiration: respiration,
            bodyMetrics: bodyMetrics, activity: activity, sleep: sleep, metabolic: metabolic,
            lastChange: lastChange)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("HealthDataStore: save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        live = snapshot.live
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
    }
}
