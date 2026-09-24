import Foundation

/// Byte-level parsers for every record type the ring sends.
///
/// Offsets are taken from the vendor SDK's `DataUnpack` class (see `docs/PROTOCOL.md`).
/// Zero or implausible values mean "not measured" and are dropped.
enum YCParsers {

    // MARK: - Stored history (group 0x05)

    /// Parses a reassembled history transfer. `requestKey` is the key of the request
    /// (e.g. `0x04` for sleep), which is how the SDK dispatches too.
    static func history(requestKey: UInt8, bytes: [UInt8], timeZone: TimeZone = .current) -> HealthBatch {
        switch requestKey {
        case YCDataType.historySport.key: return sportHistory(bytes, timeZone: timeZone)
        case YCDataType.historySleep.key: return sleepHistory(bytes, timeZone: timeZone)
        case YCDataType.historyHeart.key: return heartHistory(bytes, timeZone: timeZone)
        case YCDataType.historyBlood.key: return bloodHistory(bytes, timeZone: timeZone)
        case YCDataType.historyAll.key: return allHistory(bytes, timeZone: timeZone)
        case YCDataType.historyBloodOxygen.key: return bloodOxygenHistory(bytes, timeZone: timeZone)
        case YCDataType.historyTemperature.key: return temperatureHistory(bytes, timeZone: timeZone)
        case YCDataType.historyComprehensive.key: return comprehensiveHistory(bytes, timeZone: timeZone)
        case YCDataType.historyBody.key: return bodyHistory(bytes, timeZone: timeZone)
        default: return HealthBatch()
        }
    }

    /// 14-byte records: start u32, end u32, steps u16, distance (m) u16, calories (kcal) u16.
    static func sportHistory(_ b: [UInt8], timeZone: TimeZone) -> HealthBatch {
        var batch = HealthBatch()
        var i = 0
        while i + 14 <= b.count {
            let start = YCTime.date(fromRingSeconds: b.u32le(i), timeZone: timeZone)
            let end = YCTime.date(fromRingSeconds: b.u32le(i + 4), timeZone: timeZone)
            let steps = b.u16le(i + 8)
            let distance = b.u16le(i + 10)
            let kcal = b.u16le(i + 12)
            if steps > 0 || distance > 0 || kcal > 0 {
                batch.activity.append(ActivitySample(
                    date: start, end: max(end, start),
                    steps: steps, distanceMeters: distance, kilocalories: kcal))
            }
            i += 14
        }
        return batch
    }

    /// Variable-length sleep records.
    ///
    /// Header (20 bytes): marker u16 (`AF FA`), record length u16 (header included),
    /// start u32, end u32, then either
    /// - `FF FF`, REM s u16, deep s u16, light s u16 (newer firmware), or
    /// - deep count u16, light count u16, deep min u16, light min u16 (older firmware).
    ///
    /// Followed by 8-byte stages: kind u8 (241 deep, 242 light, 243 REM, 244 awake,
    /// 245 nap), start u32, duration in seconds u24.
    static func sleepHistory(_ b: [UInt8], timeZone: TimeZone) -> HealthBatch {
        var batch = HealthBatch()
        var i = 0
        while i + 20 <= b.count {
            let recordLength = b.u16le(i + 2)
            let start = YCTime.date(fromRingSeconds: b.u32le(i + 4), timeZone: timeZone)
            let end = YCTime.date(fromRingSeconds: b.u32le(i + 8), timeZone: timeZone)
            var deep: TimeInterval
            var light: TimeInterval
            var rem: TimeInterval = 0
            if b.u16le(i + 12) == 0xFFFF {
                rem = TimeInterval(b.u16le(i + 14))
                deep = TimeInterval(b.u16le(i + 16))
                light = TimeInterval(b.u16le(i + 18))
            } else {
                deep = TimeInterval(b.u16le(i + 16) * 60)
                light = TimeInterval(b.u16le(i + 18) * 60)
            }

            var stages: [SleepStage] = []
            var seenStarts = Set<Date>()
            var awake: TimeInterval = 0
            var awakeCount = 0
            var j = i + 20
            let stageBytes = max(0, recordLength - 20)
            while j - (i + 20) + 8 <= stageBytes, j + 8 <= b.count {
                let kindRaw = b.u8(j)
                let stageStart = YCTime.date(fromRingSeconds: b.u32le(j + 1), timeZone: timeZone)
                let duration = TimeInterval(b.u24le(j + 5))
                j += 8
                if kindRaw == SleepStageKind.awake.rawValue {
                    awake += duration
                    awakeCount += 1
                }
                guard let kind = SleepStageKind(rawValue: kindRaw), duration > 0,
                      seenStarts.insert(stageStart).inserted else { continue }
                stages.append(SleepStage(start: stageStart, duration: duration, kind: kind))
            }
            stages.sort { $0.start < $1.start }

            // Prefer totals computed from the stages when the header totals are missing.
            let stageTotal = { (kind: SleepStageKind) in
                stages.filter { $0.kind == kind }.reduce(0) { $0 + $1.duration }
            }
            if deep == 0 { deep = stageTotal(.deep) }
            if light == 0 { light = stageTotal(.light) }
            if rem == 0 { rem = stageTotal(.rem) }

            let sessionEnd = max(end, stages.last?.end ?? end)
            if deep + light + rem > 0 {
                batch.sleep.append(SleepSession(
                    date: start, end: sessionEnd, stages: stages,
                    deepSeconds: deep, lightSeconds: light, remSeconds: rem,
                    awakeSeconds: awake, awakeCount: awakeCount))
            }
            // The SDK resumes right after the last whole stage; guard against a zero length.
            i = max(j, i + 20)
        }
        return batch
    }

    /// 6-byte records: time u32, mode u8, bpm u8.
    static func heartHistory(_ b: [UInt8], timeZone: TimeZone) -> HealthBatch {
        var batch = HealthBatch()
        var i = 0
        while i + 6 <= b.count {
            let date = YCTime.date(fromRingSeconds: b.u32le(i), timeZone: timeZone)
            if let bpm = Plausible.heartRate(b.u8(i + 5)) {
                batch.heartRate.append(HeartRateSample(date: date, bpm: bpm))
            }
            i += 6
        }
        return batch
    }

    /// 8-byte records: time u32, cuff flag u8, systolic u8, diastolic u8, heart rate u8.
    static func bloodHistory(_ b: [UInt8], timeZone: TimeZone) -> HealthBatch {
        var batch = HealthBatch()
        var i = 0
        while i + 8 <= b.count {
            let date = YCTime.date(fromRingSeconds: b.u32le(i), timeZone: timeZone)
            if let sys = Plausible.systolic(b.u8(i + 5)), let dia = Plausible.diastolic(b.u8(i + 6)), sys > dia {
                batch.bloodPressure.append(BloodPressureSample(
                    date: date, systolic: sys, diastolic: dia, heartRate: Plausible.heartRate(b.u8(i + 7))))
            }
            i += 8
        }
        return batch
    }

    /// 20-byte "all metrics" records: time u32, steps u16, HR, SBP, DBP, SpO2, respiration,
    /// HRV, CVRR, temp int, temp frac, body-fat int, body-fat frac, glucose, 2 reserved.
    static func allHistory(_ b: [UInt8], timeZone: TimeZone) -> HealthBatch {
        var batch = HealthBatch()
        var i = 0
        while i + 20 <= b.count {
            let date = YCTime.date(fromRingSeconds: b.u32le(i), timeZone: timeZone)
            let hr = Plausible.heartRate(b.u8(i + 6))
            if let hr {
                batch.heartRate.append(HeartRateSample(date: date, bpm: hr))
            }
            if let sys = Plausible.systolic(b.u8(i + 7)), let dia = Plausible.diastolic(b.u8(i + 8)), sys > dia {
                batch.bloodPressure.append(BloodPressureSample(date: date, systolic: sys, diastolic: dia, heartRate: hr))
            }
            if let spo2 = Plausible.bloodOxygen(b.u8(i + 9)) {
                batch.bloodOxygen.append(BloodOxygenSample(date: date, percent: spo2))
            }
            if let resp = Plausible.respiration(b.u8(i + 10)) {
                batch.respiration.append(RespirationSample(date: date, breathsPerMinute: resp))
            }
            if let hrv = Plausible.hrv(Double(b.u8(i + 11))) {
                batch.hrv.append(HRVSample(date: date, milliseconds: hrv))
            }
            if b.u8(i + 13) > 0, let temp = Plausible.temperature(vendorDecimal(integer: b.u8(i + 13), fraction: b.u8(i + 14))) {
                batch.temperature.append(TemperatureSample(date: date, celsius: temp))
            }
            i += 20
        }
        return batch
    }

    /// 6-byte records: time u32, type u8, SpO2 % u8.
    static func bloodOxygenHistory(_ b: [UInt8], timeZone: TimeZone) -> HealthBatch {
        var batch = HealthBatch()
        var i = 0
        while i + 6 <= b.count {
            let date = YCTime.date(fromRingSeconds: b.u32le(i), timeZone: timeZone)
            if let spo2 = Plausible.bloodOxygen(b.u8(i + 5)) {
                batch.bloodOxygen.append(BloodOxygenSample(date: date, percent: spo2))
            }
            i += 6
        }
        return batch
    }

    /// 7-byte records: time u32, type u8, temp int u8, temp frac u8.
    static func temperatureHistory(_ b: [UInt8], timeZone: TimeZone) -> HealthBatch {
        var batch = HealthBatch()
        var i = 0
        while i + 7 <= b.count {
            let date = YCTime.date(fromRingSeconds: b.u32le(i), timeZone: timeZone)
            if b.u8(i + 5) > 0, let temp = Plausible.temperature(vendorDecimal(integer: b.u8(i + 5), fraction: b.u8(i + 6))) {
                batch.temperature.append(TemperatureSample(date: date, celsius: temp))
            }
            i += 7
        }
        return batch
    }

    /// 44-byte blood-chemistry records: time u32, glucose (model, int, frac), uric acid
    /// (model, u16), ketone (model, int, frac), lipids (model, TC, HDL, LDL, TG as int/frac pairs).
    static func comprehensiveHistory(_ b: [UInt8], timeZone: TimeZone) -> HealthBatch {
        var batch = HealthBatch()
        var i = 0
        func decimal(_ at: Int) -> Double? {
            b.u8(at) == 0 && b.u8(at + 1) == 0 ? nil : vendorDecimal(integer: b.u8(at), fraction: b.u8(at + 1))
        }
        while i + 44 <= b.count {
            let date = YCTime.date(fromRingSeconds: b.u32le(i), timeZone: timeZone)
            let uric = b.u16le(i + 8)
            let sample = MetabolicSample(
                date: date,
                glucose: decimal(i + 5),
                uricAcid: uric > 0 ? uric : nil,
                ketone: decimal(i + 11),
                totalCholesterol: decimal(i + 14),
                hdl: decimal(i + 16),
                ldl: decimal(i + 18),
                triglycerides: decimal(i + 20))
            if sample.glucose != nil || sample.uricAcid != nil || sample.ketone != nil || sample.totalCholesterol != nil {
                batch.metabolic.append(sample)
            }
            i += 44
        }
        return batch
    }

    /// 28-byte body-data records: time u32 followed by the same layout as the live
    /// body-data upload (see `bodyMetrics(_:date:)`).
    static func bodyHistory(_ b: [UInt8], timeZone: TimeZone) -> HealthBatch {
        var batch = HealthBatch()
        var i = 0
        while i + 28 <= b.count {
            let date = YCTime.date(fromRingSeconds: b.u32le(i), timeZone: timeZone)
            let sample = bodyMetrics(Array(b[(i + 4)..<(i + 28)]), date: date)
            if let sample {
                batch.bodyMetrics.append(sample)
                // The record's "HRV" field is an inverted 0–10 index; RMSSD/SDNN are the real HRV.
                if let ms = sample.hrvMilliseconds.flatMap(Plausible.hrv) {
                    batch.hrv.append(HRVSample(date: date, milliseconds: ms))
                }
            }
            i += 28
        }
        return batch
    }

    /// Body-data layout (no timestamp), each index as int/frac on the vendor's 0–10 scale:
    /// fatigue, HRV index, stress, body index, sympathetic balance; then SDNN ms u16 and
    /// (≥ 21 bytes) VO2max u8, pNN50 u8, RMSSD ms u16, LF u16, HF u16, LF/HF ×10 u8.
    static func bodyMetrics(_ b: [UInt8], date: Date) -> BodyMetricsSample? {
        guard b.count >= 12 else { return nil }
        /// Integer byte + fraction byte; both zero means "not measured".
        func index(_ at: Int) -> Double? {
            guard b.u8(at) != 0 || b.u8(at + 1) != 0 else { return nil }
            return Plausible.healthIndex(vendorDecimal(integer: b.u8(at), fraction: b.u8(at + 1)))
        }
        /// The balance can be negative, so its integer byte is read as two's complement.
        func balance(_ at: Int) -> Double? {
            guard b.u8(at) != 0 || b.u8(at + 1) != 0 else { return nil }
            let whole = Int(Int8(bitPattern: b[at]))
            let magnitude = vendorDecimal(integer: abs(whole), fraction: b.u8(at + 1))
            return Plausible.balance(whole < 0 ? -magnitude : magnitude)
        }
        var sample = BodyMetricsSample(
            date: date,
            stress: index(4),
            fatigue: index(0),
            bodyIndex: index(6),
            sympatheticBalance: balance(8),
            hrvIndex: index(2),
            sdnn: b.u16le(10) > 0 ? b.u16le(10) : nil)
        if b.count >= 21 {
            sample.vo2max = b.u8(12) > 0 ? b.u8(12) : nil
            sample.pnn50 = b.u8(13) > 0 ? b.u8(13) : nil
            sample.rmssd = b.u16le(14) > 0 ? b.u16le(14) : nil
            sample.lf = b.u16le(16) > 0 ? b.u16le(16) : nil
            sample.hf = b.u16le(18) > 0 ? b.u16le(18) : nil
            sample.lfHfRatio = b.u8(20) > 0 ? Double(b.u8(20)) / 10 : nil
        }
        let hasValue = sample.stress != nil || sample.fatigue != nil || sample.bodyIndex != nil
            || sample.hrvIndex != nil || sample.hrvMilliseconds != nil
        return hasValue ? sample : nil
    }

    // MARK: - Live values (groups 0x02 and 0x06)

    /// `getAllRealData` (0x0220): HR, SBP, DBP, SpO2, respiration, temp int, temp frac,
    /// steps u24, kcal u16, distance u16, …
    static func allRealData(_ b: [UInt8], now: Date) -> LiveSnapshot? {
        guard b.count >= 14 else { return nil }
        var s = LiveSnapshot(updatedAt: now)
        s.heartRate = Plausible.heartRate(b.u8(0))
        s.systolic = Plausible.systolic(b.u8(1))
        s.diastolic = Plausible.diastolic(b.u8(2))
        s.bloodOxygen = Plausible.bloodOxygen(b.u8(3))
        s.respiratoryRate = Plausible.respiration(b.u8(4))
        s.temperature = b.u8(5) > 0 ? Plausible.temperature(vendorDecimal(integer: b.u8(5), fraction: b.u8(6))) : nil
        s.stepsToday = b.u24le(7)
        s.kilocaloriesToday = b.u16le(10)
        s.distanceTodayMeters = b.u16le(12)
        return s
    }

    /// Real-time upload 0x060A: steps u24, distance u16, kcal u16, HR, SBP, DBP, SpO2,
    /// respiration, temp int, temp frac, wearing state, battery %, PPI u32, …
    static func realComprehensive(_ b: [UInt8], now: Date) -> LiveSnapshot? {
        guard b.count >= 16 else { return nil }
        var s = LiveSnapshot(updatedAt: now)
        s.stepsToday = b.u24le(0)
        s.distanceTodayMeters = b.u16le(3)
        s.kilocaloriesToday = b.u16le(5)
        s.heartRate = Plausible.heartRate(b.u8(7))
        s.systolic = Plausible.systolic(b.u8(8))
        s.diastolic = Plausible.diastolic(b.u8(9))
        s.bloodOxygen = Plausible.bloodOxygen(b.u8(10))
        s.respiratoryRate = Plausible.respiration(b.u8(11))
        s.temperature = b.u8(12) > 0 ? Plausible.temperature(vendorDecimal(integer: b.u8(12), fraction: b.u8(13))) : nil
        s.batteryPercent = b.u8(15) <= 100 ? b.u8(15) : nil
        return s
    }

    /// Real-time blood upload 0x0603: SBP, DBP, HR, then optional HRV, SpO2, temp int/frac.
    static func realBlood(_ b: [UInt8], now: Date) -> LiveSnapshot? {
        guard b.count >= 3 else { return nil }
        var s = LiveSnapshot(updatedAt: now)
        s.systolic = Plausible.systolic(b.u8(0))
        s.diastolic = Plausible.diastolic(b.u8(1))
        s.heartRate = Plausible.heartRate(b.u8(2))
        if b.count > 3 { s.hrv = Plausible.hrv(Double(b.u8(3))) }
        if b.count > 4 { s.bloodOxygen = Plausible.bloodOxygen(b.u8(4)) }
        if b.count > 6, b.u8(5) > 0 {
            s.temperature = Plausible.temperature(vendorDecimal(integer: b.u8(5), fraction: b.u8(6)))
        }
        return s
    }

    /// Real-time sport upload 0x0600 and `getNowStep` 0x020C both report today's totals,
    /// but with different layouts.
    static func realSport(_ b: [UInt8], now: Date) -> LiveSnapshot? {
        guard b.count >= 6 else { return nil }
        var s = LiveSnapshot(updatedAt: now)
        s.stepsToday = b.u16le(0)
        s.distanceTodayMeters = b.u16le(2)
        s.kilocaloriesToday = b.u16le(4)
        return s
    }

    static func nowStep(_ b: [UInt8], now: Date) -> LiveSnapshot? {
        guard b.count > 6 else { return nil }
        var s = LiveSnapshot(updatedAt: now)
        s.stepsToday = b.u24le(0)
        s.kilocaloriesToday = b.u16le(3)
        s.distanceTodayMeters = b.u16le(5)
        return s
    }

    /// `getDeviceInfo` 0x0200: device id u16, minor version, major version, battery state,
    /// battery %, bind state, sync state, …
    static func deviceInfo(_ b: [UInt8]) -> DeviceInfo? {
        guard b.count >= 6 else { return nil }
        let minor = b.u8(2)
        let major = b.u8(3)
        let version = minor < 10 ? "\(major).0\(minor)" : "\(major).\(minor)"
        return DeviceInfo(deviceID: b.u16le(0), firmwareVersion: version,
                          batteryPercent: min(b.u8(5), 100), batteryState: b.u8(4))
    }

    // MARK: - Standard Bluetooth GATT characteristics

    /// Heart Rate Measurement (0x2A37). Returns the BPM and any RR intervals in seconds.
    static func gattHeartRate(_ b: [UInt8]) -> (bpm: Int, rrIntervals: [Double])? {
        guard b.count >= 2 else { return nil }
        let flags = b[0]
        var i = 1
        let bpm: Int
        if flags & 0x01 != 0 {
            guard b.count >= 3 else { return nil }
            bpm = b.u16le(1)
            i = 3
        } else {
            bpm = b.u8(1)
            i = 2
        }
        if flags & 0x08 != 0 { i += 2 } // energy expended
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while i + 2 <= b.count {
                rr.append(Double(b.u16le(i)) / 1024)
                i += 2
            }
        }
        return (bpm, rr)
    }

    /// RMSSD in milliseconds from successive RR intervals (seconds).
    static func rmssd(_ rrIntervals: [Double]) -> Double? {
        guard rrIntervals.count >= 2 else { return nil }
        var sum = 0.0
        for k in 1..<rrIntervals.count {
            let d = (rrIntervals[k] - rrIntervals[k - 1]) * 1000
            sum += d * d
        }
        return (sum / Double(rrIntervals.count - 1)).squareRoot()
    }
}

extension LiveSnapshot {
    /// Overwrites fields that `patch` provides and keeps the rest.
    mutating func apply(_ patch: LiveSnapshot) {
        updatedAt = patch.updatedAt ?? updatedAt
        heartRate = patch.heartRate ?? heartRate
        systolic = patch.systolic ?? systolic
        diastolic = patch.diastolic ?? diastolic
        bloodOxygen = patch.bloodOxygen ?? bloodOxygen
        respiratoryRate = patch.respiratoryRate ?? respiratoryRate
        temperature = patch.temperature ?? temperature
        hrv = patch.hrv ?? hrv
        stress = patch.stress ?? stress
        stepsToday = patch.stepsToday ?? stepsToday
        distanceTodayMeters = patch.distanceTodayMeters ?? distanceTodayMeters
        kilocaloriesToday = patch.kilocaloriesToday ?? kilocaloriesToday
        batteryPercent = patch.batteryPercent ?? batteryPercent
        isWorn = patch.isWorn ?? isWorn
    }
}
