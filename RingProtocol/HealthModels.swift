import Foundation

/// Anything with a timestamp that the store can merge and de-duplicate.
protocol TimedSample: Codable, Hashable {
    var date: Date { get }
}

struct HeartRateSample: TimedSample {
    var date: Date
    var bpm: Int
}

struct BloodPressureSample: TimedSample {
    var date: Date
    var systolic: Int
    var diastolic: Int
    var heartRate: Int?
}

struct BloodOxygenSample: TimedSample {
    var date: Date
    var percent: Int
}

struct TemperatureSample: TimedSample {
    var date: Date
    var celsius: Double
}

struct HRVSample: TimedSample {
    var date: Date
    /// Heart-rate variability as reported by the ring (milliseconds).
    var milliseconds: Double
}

struct RespirationSample: TimedSample {
    var date: Date
    var breathsPerMinute: Int
}

/// Stress and autonomic metrics from the ring's "body data" records (SDK: `Health_History_Body_Data`).
///
/// The first five fields are the vendor's "health norm" indices (SDK `HealthNormBean`), scored
/// 0–10 where higher means more strain. They are scores, not measurements: the HRV index rises
/// as heart-rate variability *falls* (vendor `calc_HRV_norm`: 10 ms → 10, 150 ms → ≈ 0.9).
/// SDNN and RMSSD are the actual HRV in milliseconds.
struct BodyMetricsSample: TimedSample {
    var date: Date
    /// Stress ("pressure") index, 0–10. Higher = more stress.
    var stress: Double?
    /// Fatigue ("heavy load") index, 0–10. Higher = more fatigue.
    var fatigue: Double?
    /// Body-status index, 0–10.
    var bodyIndex: Double?
    /// Sympathetic–parasympathetic balance, −10…10 (positive = sympathetic dominant).
    var sympatheticBalance: Double?
    /// HRV index, 0–10. Higher = LOWER heart-rate variability.
    var hrvIndex: Double?
    /// Milliseconds.
    var sdnn: Int?
    /// Milliseconds.
    var rmssd: Int?
    var pnn50: Int?
    var lf: Int?
    var hf: Int?
    var lfHfRatio: Double?
    var vo2max: Int?

    /// Heart-rate variability in milliseconds (RMSSD, else SDNN).
    var hrvMilliseconds: Double? {
        (rmssd ?? sdnn).map { Double($0) }
    }
}

/// Steps, distance and energy for one interval (history records cover minutes to an hour).
struct ActivitySample: TimedSample {
    var date: Date
    var end: Date
    var steps: Int
    var distanceMeters: Int
    var kilocalories: Int
}

/// Blood chemistry estimates some rings report (glucose, uric acid, lipids, ketones).
struct MetabolicSample: TimedSample {
    var date: Date
    /// mmol/L
    var glucose: Double?
    /// µmol/L
    var uricAcid: Int?
    /// mmol/L
    var ketone: Double?
    /// mmol/L
    var totalCholesterol: Double?
    var hdl: Double?
    var ldl: Double?
    var triglycerides: Double?
}

enum SleepStageKind: Int, Codable, CaseIterable {
    case deep = 241
    case light = 242
    case rem = 243
    case awake = 244
    case nap = 245

    var displayName: String {
        switch self {
        case .deep: return "Deep"
        case .light: return "Light"
        case .rem: return "REM"
        case .awake: return "Awake"
        case .nap: return "Nap"
        }
    }
}

struct SleepStage: Codable, Hashable {
    var start: Date
    var duration: TimeInterval
    var kind: SleepStageKind

    var end: Date { start.addingTimeInterval(duration) }
}

struct SleepSession: TimedSample {
    /// Session start (bedtime).
    var date: Date
    var end: Date
    var stages: [SleepStage]
    var deepSeconds: TimeInterval
    var lightSeconds: TimeInterval
    var remSeconds: TimeInterval
    var awakeSeconds: TimeInterval
    var awakeCount: Int

    var asleepSeconds: TimeInterval { deepSeconds + lightSeconds + remSeconds }
    var inBedSeconds: TimeInterval { max(end.timeIntervalSince(date), asleepSeconds + awakeSeconds) }

    /// Transparent 0–100 estimate (the vendor's own score is computed server-side and
    /// is not part of the ring protocol): 50 pts for 7–9 h asleep, 20 pts for ≥ 20 % deep,
    /// 20 pts for ≥ 20 % REM, 10 pts for ≥ 90 % efficiency, each scaled linearly below target.
    var estimatedScore: Int {
        let asleep = asleepSeconds
        guard asleep > 0 else { return 0 }
        let hours = asleep / 3600
        let durationScore: Double
        if hours < 7 {
            durationScore = 50 * hours / 7
        } else if hours <= 9 {
            durationScore = 50
        } else {
            durationScore = max(30, 50 - (hours - 9) * 10)
        }
        let deepScore = 20 * min(1, (deepSeconds / asleep) / 0.20)
        let remScore = 20 * min(1, (remSeconds / asleep) / 0.20)
        let efficiency = asleep / max(inBedSeconds, 1)
        let efficiencyScore = 10 * min(1, efficiency / 0.90)
        return Int((durationScore + deepScore + remScore + efficiencyScore).rounded())
    }
}

struct DeviceInfo: Codable, Hashable {
    var deviceID: Int
    var firmwareVersion: String
    var batteryPercent: Int
    /// Raw battery state byte; non-zero typically means charging.
    var batteryState: Int
    var isCharging: Bool { batteryState != 0 }
}

/// The latest live values, from `getAllRealData`, real-time uploads and measurement results.
struct LiveSnapshot: Codable, Hashable {
    var updatedAt: Date?
    var heartRate: Int?
    var systolic: Int?
    var diastolic: Int?
    var bloodOxygen: Int?
    var respiratoryRate: Int?
    var temperature: Double?
    /// Heart-rate variability in milliseconds.
    var hrv: Double?
    /// Stress index, 0–10 (see `BodyMetricsSample.stress`).
    var stress: Double?
    var stepsToday: Int?
    var distanceTodayMeters: Int?
    var kilocaloriesToday: Int?
    var batteryPercent: Int?
    var isWorn: Bool?
}

/// A bag of decoded samples; every parser returns one so the store merges them uniformly.
struct HealthBatch: Equatable {
    var heartRate: [HeartRateSample] = []
    var bloodPressure: [BloodPressureSample] = []
    var bloodOxygen: [BloodOxygenSample] = []
    var temperature: [TemperatureSample] = []
    var hrv: [HRVSample] = []
    var respiration: [RespirationSample] = []
    var bodyMetrics: [BodyMetricsSample] = []
    var activity: [ActivitySample] = []
    var sleep: [SleepSession] = []
    var metabolic: [MetabolicSample] = []

    var isEmpty: Bool { totalCount == 0 }

    var totalCount: Int {
        heartRate.count + bloodPressure.count + bloodOxygen.count + temperature.count + hrv.count
            + respiration.count + bodyMetrics.count + activity.count + sleep.count + metabolic.count
    }

    mutating func merge(_ other: HealthBatch) {
        heartRate += other.heartRate
        bloodPressure += other.bloodPressure
        bloodOxygen += other.bloodOxygen
        temperature += other.temperature
        hrv += other.hrv
        respiration += other.respiration
        bodyMetrics += other.bodyMetrics
        activity += other.activity
        sleep += other.sleep
        metabolic += other.metabolic
    }
}

/// Plausibility filters. The vendor app drops blood-pressure readings outside
/// 60–250 / 30–160 mmHg and zero values; we apply similar bounds everywhere so a
/// ring that reports "0" for "not measured" never shows up as a reading.
enum Plausible {
    static func heartRate(_ v: Int) -> Int? { (25...250).contains(v) ? v : nil }
    static func systolic(_ v: Int) -> Int? { (60...250).contains(v) ? v : nil }
    static func diastolic(_ v: Int) -> Int? { (30...160).contains(v) ? v : nil }
    static func bloodOxygen(_ v: Int) -> Int? { (70...100).contains(v) ? v : nil }
    static func respiration(_ v: Int) -> Int? { (4...60).contains(v) ? v : nil }
    static func temperature(_ v: Double) -> Double? { (30.0...43.0).contains(v) ? v : nil }
    static func hrv(_ v: Double) -> Double? { (1.0...300.0).contains(v) ? v : nil }
    /// Vendor health-norm indices (stress, fatigue, HRV index, body): 0–10.
    static func healthIndex(_ v: Double) -> Double? { (0.0...10.0).contains(v) ? v : nil }
    /// Sympathetic–parasympathetic balance: −10…10.
    static func balance(_ v: Double) -> Double? { (-10.0...10.0).contains(v) ? v : nil }
}
