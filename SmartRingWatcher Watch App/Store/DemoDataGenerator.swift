import Foundation

/// Realistic synthetic data so the UI can be explored in the watch simulator, which has
/// no Bluetooth. Nothing here is sent to or read from a ring.
enum DemoDataGenerator {
    static let deviceInfo = DeviceInfo(deviceID: 0xD3E0, firmwareVersion: "1.07", batteryPercent: 76, batteryState: 0)

    static func history(days: Int = 7, now: Date = Date()) -> HealthBatch {
        var rng = SeededGenerator(seed: 42)
        var batch = HealthBatch()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(-days * 86_400))

        // Vitals every 10 minutes with a day/night rhythm.
        var t = start
        while t <= now {
            let hour = Double(calendar.component(.hour, from: t)) + Double(calendar.component(.minute, from: t)) / 60
            let asleep = hour < 7 || hour >= 23
            let circadian = asleep ? -12.0 : 6 * sin((hour - 9) / 24 * 2 * .pi)
            let bpm = Int(66 + circadian + rng.gaussian() * 4)
            batch.heartRate.append(HeartRateSample(date: t, bpm: bpm))

            if calendar.component(.minute, from: t) == 0 {
                let sys = Int(116 + circadian * 0.6 + rng.gaussian() * 4)
                let dia = Int(76 + circadian * 0.3 + rng.gaussian() * 3)
                batch.bloodPressure.append(BloodPressureSample(date: t, systolic: sys, diastolic: dia, heartRate: bpm))
                batch.bloodOxygen.append(BloodOxygenSample(date: t, percent: min(100, Int(97.5 + rng.gaussian()))))
                let celsius: Double = 36.4 + (asleep ? -0.3 : 0.1) + rng.gaussian() * 0.1
                batch.temperature.append(TemperatureSample(date: t, celsius: (celsius * 10).rounded() / 10))
                batch.respiration.append(RespirationSample(date: t, breathsPerMinute: Int(15 + (asleep ? -2 : 1) + rng.gaussian())))
                let hrvValue: Double = max(15, 48 + (asleep ? 14 : -6) + rng.gaussian() * 6)
                batch.hrv.append(HRVSample(date: t, milliseconds: hrvValue.rounded()))
                // Same direction as the ring: lower HRV → higher HRV index → higher stress.
                let hrvIndex = vendorHRVIndex(hrvValue)
                let stress: Double = min(9.8, max(0.2, hrvIndex * 0.8 + rng.gaussian() * 0.5))
                let fatigue: Double = min(9.8, max(0.2, 2.5 + hour / 12 + rng.gaussian() * 0.6))
                let balance: Double = (asleep ? -1.5 : 1.0) + rng.gaussian() * 0.8
                batch.bodyMetrics.append(BodyMetricsSample(
                    date: t, stress: roundedToTenth(stress), fatigue: roundedToTenth(fatigue),
                    bodyIndex: roundedToTenth(min(9.8, max(1.7, hrvIndex * 0.9))),
                    sympatheticBalance: roundedToTenth(balance), hrvIndex: roundedToTenth(hrvIndex),
                    sdnn: Int(hrvValue * 1.2), rmssd: Int(hrvValue), pnn50: 14, lf: 520, hf: 430,
                    lfHfRatio: 1.2, vo2max: 41))
                if !asleep {
                    let steps = max(0, Int(420 + rng.gaussian() * 260))
                    batch.activity.append(ActivitySample(date: t, end: t.addingTimeInterval(3600), steps: steps,
                                                         distanceMeters: Int(Double(steps) * 0.72),
                                                         kilocalories: steps / 25))
                }
            }
            t.addTimeInterval(600)
        }

        // A night of sleep ending each morning.
        for day in 0..<days {
            guard let bedtime = calendar.date(byAdding: .minute, value: Int(rng.gaussian() * 20),
                                              to: start.addingTimeInterval(TimeInterval(day * 86_400) + 23 * 3600)) else { continue }
            batch.sleep.append(sleepNight(start: bedtime, rng: &rng))
        }

        batch.metabolic.append(MetabolicSample(date: now.addingTimeInterval(-5400), glucose: 5.4, uricAcid: 310,
                                               ketone: 0.3, totalCholesterol: 4.6, hdl: 1.3, ldl: 2.7, triglycerides: 1.4))
        return batch
    }

    private static func sleepNight(start: Date, rng: inout SeededGenerator) -> SleepSession {
        let cycle: [(SleepStageKind, Double)] = [(.light, 25), (.deep, 35), (.light, 20), (.rem, 18), (.awake, 3)]
        var stages: [SleepStage] = []
        var t = start
        for round in 0..<5 {
            for (kind, minutes) in cycle {
                // Deep sleep shortens and REM lengthens through the night.
                let scale = kind == .deep ? 1.2 - Double(round) * 0.2 : (kind == .rem ? 0.7 + Double(round) * 0.2 : 1)
                let duration = max(2, minutes * scale + rng.gaussian() * 4) * 60
                stages.append(SleepStage(start: t, duration: duration, kind: kind))
                t.addTimeInterval(duration)
            }
        }
        func total(_ kind: SleepStageKind) -> TimeInterval {
            stages.filter { $0.kind == kind }.reduce(0) { $0 + $1.duration }
        }
        return SleepSession(date: start, end: t, stages: stages, deepSeconds: total(.deep),
                            lightSeconds: total(.light), remSeconds: total(.rem),
                            awakeSeconds: total(.awake), awakeCount: stages.filter { $0.kind == .awake }.count)
    }

    /// A fresh live snapshot that drifts a little on every refresh.
    static func live(previous: LiveSnapshot, now: Date = Date()) -> LiveSnapshot {
        var rng = SeededGenerator(seed: UInt64(now.timeIntervalSince1970))
        var s = previous
        s.updatedAt = now
        s.heartRate = min(120, max(50, (previous.heartRate ?? 68) + Int(rng.gaussian() * 2)))
        s.systolic = previous.systolic ?? 118
        s.diastolic = previous.diastolic ?? 77
        s.bloodOxygen = min(100, max(94, (previous.bloodOxygen ?? 98) + Int(rng.gaussian() * 0.6)))
        s.respiratoryRate = previous.respiratoryRate ?? 15
        s.temperature = previous.temperature ?? 36.5
        s.hrv = previous.hrv ?? 46
        s.stress = previous.stress ?? roundedToTenth(vendorHRVIndex(46) * 0.8)
        let steps = (previous.stepsToday ?? 3200) + Int(abs(rng.gaussian()) * 12)
        s.stepsToday = steps
        s.distanceTodayMeters = Int(Double(steps) * 0.72)
        s.kilocaloriesToday = steps / 25
        s.batteryPercent = previous.batteryPercent ?? 76
        return s
    }
}

/// The vendor SDK's HRV-norm mapping (`AIPraseDataUtil.calc_HRV_norm`): raw HRV in ms to a
/// 0–10 index that rises as HRV falls. Used only to make demo data behave like a real ring.
func vendorHRVIndex(_ milliseconds: Double) -> Double {
    let f = max(milliseconds, 10)
    switch f {
    case ..<25: return f * -0.06 + 10.6
    case ..<40: return f * -0.0333 + 9.9333
    case ..<60: return f * -0.045 + 10.4
    case ..<75: return f * -0.1267 + 15.3
    case ..<90: return f * -0.12 + 14.8
    case ..<130: return f * -0.05 + 8.5
    case ..<150: return f * -0.055 + 9.15
    default: return 0
    }
}

private func roundedToTenth(_ value: Double) -> Double {
    (value * 10).rounded() / 10
}

/// Small deterministic PRNG (SplitMix64) so demo data looks the same on every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal sample (Box–Muller).
    mutating func gaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), .leastNonzeroMagnitude)
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
