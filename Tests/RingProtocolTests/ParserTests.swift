import XCTest
@testable import RingProtocol

/// Each expectation mirrors what the vendor SDK decoded from the same bytes
/// (see `Vectors`), minus values the app deliberately filters out (zeros).
final class ParserTests: XCTestCase {

    func testHeartHistory() {
        let batch = YCParsers.heartHistory(Vectors.heart, timeZone: utc)
        // SDK: [{heartValue=72, t=…168000}, {heartValue=0, t=…468000}] – the zero is "not measured".
        XCTAssertEqual(batch.heartRate, [HeartRateSample(date: baseDate, bpm: 72)])
    }

    func testBloodHistory() {
        let batch = YCParsers.bloodHistory(Vectors.blood, timeZone: utc)
        XCTAssertEqual(batch.bloodPressure, [BloodPressureSample(date: baseDate, systolic: 120, diastolic: 80, heartRate: 70)])
    }

    func testSportHistory() {
        let batch = YCParsers.sportHistory(Vectors.sport, timeZone: utc)
        XCTAssertEqual(batch.activity, [ActivitySample(
            date: baseDate, end: baseDate.addingTimeInterval(3600),
            steps: 1234, distanceMeters: 850, kilocalories: 45)])
    }

    func testAllHistory() {
        let batch = YCParsers.allHistory(Vectors.all, timeZone: utc)
        XCTAssertEqual(batch.heartRate, [HeartRateSample(date: baseDate, bpm: 65)])
        XCTAssertEqual(batch.bloodPressure, [BloodPressureSample(date: baseDate, systolic: 118, diastolic: 76, heartRate: 65)])
        XCTAssertEqual(batch.bloodOxygen, [BloodOxygenSample(date: baseDate, percent: 98)])
        XCTAssertEqual(batch.respiration, [RespirationSample(date: baseDate, breathsPerMinute: 16)])
        XCTAssertEqual(batch.hrv, [HRVSample(date: baseDate, milliseconds: 45)])
        XCTAssertEqual(batch.temperature.first?.celsius ?? 0, 36.5, accuracy: 0.0001)
    }

    func testBloodOxygenAndTemperatureHistory() {
        XCTAssertEqual(YCParsers.bloodOxygenHistory(Vectors.bloodOxygen, timeZone: utc).bloodOxygen,
                       [BloodOxygenSample(date: baseDate, percent: 97)])
        let temps = YCParsers.temperatureHistory(Vectors.temperature, timeZone: utc).temperature
        XCTAssertEqual(temps.count, 1)
        XCTAssertEqual(temps.first?.celsius ?? 0, 36.7, accuracy: 0.0001)
    }

    func testSleepHistoryNewAndOldFormat() throws {
        let sessions = YCParsers.sleepHistory(Vectors.sleep, timeZone: utc).sleep
        XCTAssertEqual(sessions.count, 2)

        let night = try XCTUnwrap(sessions.first)
        XCTAssertEqual(night.date, baseDate)
        XCTAssertEqual(night.end, baseDate.addingTimeInterval(5700))
        XCTAssertEqual(night.deepSeconds, 1800)
        XCTAssertEqual(night.lightSeconds, 1800)
        XCTAssertEqual(night.remSeconds, 1800)
        XCTAssertEqual(night.awakeSeconds, 300)
        XCTAssertEqual(night.awakeCount, 1)
        XCTAssertEqual(night.stages.map(\.kind), [.light, .deep, .rem, .awake])
        XCTAssertEqual(night.stages.map(\.duration), [1800, 1800, 1800, 300])
        XCTAssertEqual(night.asleepSeconds, 5400)

        // Old firmware reports totals in minutes (30 deep, 60 light).
        let nap = sessions[1]
        XCTAssertEqual(nap.date, Date(timeIntervalSince1970: 1_752_056_704))
        XCTAssertEqual(nap.deepSeconds, 1800)
        XCTAssertEqual(nap.lightSeconds, 3600)
        XCTAssertEqual(nap.remSeconds, 0)
        XCTAssertEqual(nap.stages.count, 1)
    }

    func testBodyHistory() throws {
        let batch = YCParsers.bodyHistory(Vectors.body, timeZone: utc)
        let body = try XCTUnwrap(batch.bodyMetrics.first)
        XCTAssertEqual(body.fatigue ?? 0, 30.5, accuracy: 0.0001)
        XCTAssertEqual(body.hrv ?? 0, 42, accuracy: 0.0001)
        XCTAssertEqual(body.stress ?? 0, 55.2, accuracy: 0.0001)
        XCTAssertEqual(body.bodyEnergy ?? 0, 70, accuracy: 0.0001)
        XCTAssertEqual(body.sympathetic ?? 0, 40.1, accuracy: 0.0001)
        XCTAssertEqual(body.sdnn, 50)
        XCTAssertEqual(body.vo2max, 38)
        XCTAssertEqual(body.pnn50, 12)
        XCTAssertEqual(body.rmssd, 35)
        XCTAssertEqual(body.lf, 500)
        XCTAssertEqual(body.hf, 400)
        XCTAssertEqual(body.lfHfRatio ?? 0, 1.2, accuracy: 0.0001)
        XCTAssertEqual(batch.hrv, [HRVSample(date: baseDate, milliseconds: 42)])
    }

    func testComprehensiveHistory() throws {
        let sample = try XCTUnwrap(YCParsers.comprehensiveHistory(Vectors.comprehensive, timeZone: utc).metabolic.first)
        XCTAssertEqual(sample.glucose ?? 0, 5.6, accuracy: 0.0001)
        XCTAssertEqual(sample.uricAcid, 320)
        XCTAssertEqual(sample.ketone ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(sample.totalCholesterol ?? 0, 4.5, accuracy: 0.0001)
        XCTAssertEqual(sample.hdl ?? 0, 1.2, accuracy: 0.0001)
        XCTAssertEqual(sample.ldl ?? 0, 2.8, accuracy: 0.0001)
        XCTAssertEqual(sample.triglycerides ?? 0, 1.5, accuracy: 0.0001)
    }

    func testTruncatedInputIsIgnored() {
        XCTAssertTrue(YCParsers.heartHistory(Array(Vectors.heart.prefix(5)), timeZone: utc).isEmpty)
        XCTAssertTrue(YCParsers.sleepHistory(Array(Vectors.sleep.prefix(19)), timeZone: utc).isEmpty)
        XCTAssertNil(YCParsers.allRealData([1, 2, 3], now: baseDate))
    }

    func testAllRealDataSnapshot() throws {
        // HR 70, 121/79, SpO2 97, resp 15, 36.6 °C, 5432 steps, 210 kcal, 3900 m.
        let bytes = hex("46 79 4F 61 0F 24 06 381500 D200 3C0F") + Array(repeating: 0, count: 8)
        let s = try XCTUnwrap(YCParsers.allRealData(bytes, now: baseDate))
        XCTAssertEqual(s.heartRate, 70)
        XCTAssertEqual(s.systolic, 121)
        XCTAssertEqual(s.diastolic, 79)
        XCTAssertEqual(s.bloodOxygen, 97)
        XCTAssertEqual(s.respiratoryRate, 15)
        XCTAssertEqual(s.temperature ?? 0, 36.6, accuracy: 0.0001)
        XCTAssertEqual(s.stepsToday, 5432)
        XCTAssertEqual(s.kilocaloriesToday, 210)
        XCTAssertEqual(s.distanceTodayMeters, 3900)
    }

    func testDeviceInfo() throws {
        // id 0x1234, version 1.05, battery state 0, 87 %.
        let info = try XCTUnwrap(YCParsers.deviceInfo(hex("3412 05 01 00 57 01 00")))
        XCTAssertEqual(info.deviceID, 0x1234)
        XCTAssertEqual(info.firmwareVersion, "1.05")
        XCTAssertEqual(info.batteryPercent, 87)
        XCTAssertFalse(info.isCharging)
    }

    func testStandardHeartRateCharacteristic() throws {
        let simple = try XCTUnwrap(YCParsers.gattHeartRate([0x00, 72]))
        XCTAssertEqual(simple.bpm, 72)
        XCTAssertTrue(simple.rrIntervals.isEmpty)

        // 16-bit HR + two RR intervals (1024 and 1100 / 1024 s).
        let withRR = try XCTUnwrap(YCParsers.gattHeartRate(hex("11 4800 0004 4C04")))
        XCTAssertEqual(withRR.bpm, 72)
        XCTAssertEqual(withRR.rrIntervals.count, 2)
        XCTAssertEqual(YCParsers.rmssd(withRR.rrIntervals) ?? 0, 76 / 1.024, accuracy: 0.001)
    }

    func testSleepScoreIsBounded() {
        let session = SleepSession(date: baseDate, end: baseDate.addingTimeInterval(8 * 3600), stages: [],
                                   deepSeconds: 2 * 3600, lightSeconds: 4 * 3600, remSeconds: 2 * 3600,
                                   awakeSeconds: 0, awakeCount: 0)
        XCTAssertEqual(session.estimatedScore, 100)
    }
}
