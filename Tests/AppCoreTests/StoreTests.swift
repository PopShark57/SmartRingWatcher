import XCTest
@testable import RingCore

@MainActor
final class StoreTests: XCTestCase {
    private var scheduler: ManualScheduler!

    private func makeStore(directory: URL? = nil) -> HealthDataStore {
        if scheduler == nil { scheduler = ManualScheduler(now: referenceDate) }
        return HealthDataStore(fileName: directory == nil ? nil : "health-store", directory: directory,
                               scheduler: scheduler, observesDayChanges: false)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RingCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func hours(_ h: Double) -> Date { referenceDate.addingTimeInterval(h * 3600) }

    // MARK: F1 – live values and their dates

    func testPolledUnchangedValueKeepsItsFirstDate() {
        let store = makeStore()
        var poll = LiveSnapshot(updatedAt: hours(-3))
        poll.systolic = 118
        poll.diastolic = 76
        store.applyLive(poll, pushed: false)

        poll.updatedAt = hours(0)
        store.applyLive(poll, pushed: false)
        XCTAssertEqual(store.latestBloodPressure?.date, hours(-3), "a repeated poll is not a new reading")
    }

    func testChangedPolledValueAndPushedValueAreNewReadings() {
        let store = makeStore()
        var poll = LiveSnapshot(updatedAt: hours(-3))
        poll.heartRate = 64
        store.applyLive(poll, pushed: false)

        poll.updatedAt = hours(-1)
        poll.heartRate = 71
        store.applyLive(poll, pushed: false)
        XCTAssertEqual(store.latestHeartRate, Reading(value: 71, date: hours(-1)))

        poll.updatedAt = hours(0)
        store.applyLive(poll, pushed: true)
        XCTAssertEqual(store.latestHeartRate, Reading(value: 71, date: hours(0)), "a push is always a new reading")
    }

    func testUnchangedPollDoesNotPublishOrSave() {
        let store = makeStore()
        var poll = LiveSnapshot(updatedAt: hours(-1))
        poll.heartRate = 64
        store.applyLive(poll, pushed: false)
        let changed = store.lastChange
        var calls = 0
        store.onChange = { calls += 1 }
        scheduler.advance(by: 10)
        poll.updatedAt = scheduler.now
        store.applyLive(poll, pushed: false)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(store.lastChange, changed)
    }

    func testNewerHistoryWinsOverOlderLiveValue() {
        let store = makeStore()
        var poll = LiveSnapshot(updatedAt: hours(-2))
        poll.heartRate = 64
        store.applyLive(poll, pushed: false)
        var batch = HealthBatch()
        batch.heartRate = [HeartRateSample(date: hours(-1), bpm: 80)]
        store.apply(batch)
        XCTAssertEqual(store.latestHeartRate, Reading(value: 80, date: hours(-1)))
    }

    // MARK: Merge and retention

    func testMergeDeduplicatesDropsOldAndFutureSamples() {
        let store = makeStore()
        var batch = HealthBatch()
        batch.heartRate = [
            HeartRateSample(date: hours(-24 * 15), bpm: 60), // beyond 14 days
            HeartRateSample(date: hours(-2), bpm: 61),
            HeartRateSample(date: hours(-1), bpm: 62),
            HeartRateSample(date: hours(3), bpm: 63), // ring clock ahead
        ]
        store.apply(batch)
        XCTAssertEqual(store.heartRate.map(\.bpm), [61, 62])

        batch.heartRate = [HeartRateSample(date: hours(-1), bpm: 65)]
        let added = store.apply(batch)
        XCTAssertEqual(store.heartRate.map(\.bpm), [61, 65], "the newest copy of a reading wins")
        XCTAssertEqual(added.heartRate.map(\.bpm), [65])
    }

    func testReDownloadedHistoryChangesNothing() {
        let store = makeStore()
        var batch = HealthBatch()
        batch.heartRate = [HeartRateSample(date: hours(-2), bpm: 61)]
        store.apply(batch)
        let changed = store.lastChange
        scheduler.advance(by: 60)
        XCTAssertTrue(store.apply(batch).isEmpty)
        XCTAssertEqual(store.lastChange, changed)
    }

    /// S3: an RMSSD and an SDNN at the same time are both kept, and the chart shows one kind.
    func testHRVKindsAreKeptApartAndNotMixed() {
        let store = makeStore()
        var batch = HealthBatch()
        batch.hrv = [
            HRVSample(date: hours(-2), milliseconds: 40, kind: .rmssd),
            HRVSample(date: hours(-2), milliseconds: 55, kind: .sdnn),
            HRVSample(date: hours(-1), milliseconds: 20, kind: .vendor),
        ]
        store.apply(batch)
        XCTAssertEqual(store.hrv.count, 3)
        XCTAssertEqual(store.hrvKind, .rmssd)
        XCTAssertEqual(store.hrvDay.map(\.milliseconds), [40])
        XCTAssertEqual(store.latestHRV, Reading(value: 40, date: hours(-2)), "the newer vendor value is a different measure")
    }

    // MARK: F7 – today

    func testTodayRollsOverAtMidnightWithoutNewData() {
        let store = makeStore()
        var batch = HealthBatch()
        batch.activity = [ActivitySample(date: hours(-1), end: hours(0), steps: 900, distanceMeters: 600, kilocalories: 30)]
        store.apply(batch)
        var poll = LiveSnapshot(updatedAt: hours(0))
        poll.stepsToday = 4_000
        store.applyLive(poll, pushed: false)
        XCTAssertEqual(store.today.steps, 4_000)
        XCTAssertEqual(store.dailySteps.last?.value, 4_000)

        scheduler.advance(by: 15 * 3600) // 01:00 the next day
        store.refreshDay()
        XCTAssertEqual(store.today.steps, 0)
        XCTAssertEqual(store.dailySteps.count, 7)
        XCTAssertEqual(store.dailySteps.last?.value, 0)
        XCTAssertEqual(store.dailySteps[5].value, 4_000, "yesterday keeps its total")
    }

    // MARK: Derived values

    func testLastNightSleepIsTheLongestRecentSession() {
        let store = makeStore()
        func session(start: Double, hours asleep: Double) -> SleepSession {
            SleepSession(date: hours(start), end: hours(start + asleep), stages: [], deepSeconds: asleep * 1800,
                         lightSeconds: asleep * 1800, remSeconds: 0, awakeSeconds: 0, awakeCount: 0)
        }
        var batch = HealthBatch()
        batch.sleep = [session(start: -45, hours: 8), session(start: -11, hours: 7), session(start: -4, hours: 1)]
        store.apply(batch)
        XCTAssertEqual(store.lastNightSleep?.date, hours(-11))
        XCTAssertEqual(store.weeklySleep.count, 7)
    }

    /// S4: resting heart rate leaves out sleep and walking.
    func testRestingHeartRateExcludesSleepAndWalking() {
        let sleep = [SleepSession(date: hours(-12), end: hours(-5), stages: [], deepSeconds: 3600, lightSeconds: 3600,
                                  remSeconds: 0, awakeSeconds: 0, awakeCount: 0)]
        let walk = [ActivitySample(date: hours(-3), end: hours(-2), steps: 3_000, distanceMeters: 2_000, kilocalories: 100)]
        var samples: [HeartRateSample] = []
        for minute in stride(from: 0.0, to: 20 * 60, by: 10) {
            let date = hours(-20).addingTimeInterval(minute * 60)
            let bpm: Int
            if date >= hours(-12) && date <= hours(-5) { bpm = 48 }        // asleep
            else if date >= hours(-3) && date < hours(-2) { bpm = 110 }    // walking
            else { bpm = 62 + Int(minute) % 7 }                            // awake, resting
            samples.append(HeartRateSample(date: date, bpm: bpm))
        }
        let resting = HealthDataStore.restingHeartRate(samples, sleep: sleep, activity: walk)
        XCTAssertEqual(resting, 62)
    }

    // MARK: Persistence and migration

    func testRoundTripKeepsHistoryAndLiveValuesInSeparateFiles() throws {
        let directory = try temporaryDirectory()
        let store = makeStore(directory: directory)
        var batch = HealthBatch()
        batch.heartRate = [HeartRateSample(date: hours(-1), bpm: 66)]
        batch.hrv = [HRVSample(date: hours(-1), milliseconds: 41, kind: .sdnn)]
        store.apply(batch)
        var poll = LiveSnapshot(updatedAt: hours(-2))
        poll.systolic = 121
        poll.diastolic = 79
        store.applyLive(poll, pushed: false)
        store.save(synchronously: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("health-store.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("health-store-live.json").path))
        let reloaded = makeStore(directory: directory)
        XCTAssertEqual(reloaded.heartRate, store.heartRate)
        XCTAssertEqual(reloaded.hrv, store.hrv)
        XCTAssertEqual(reloaded.latestBloodPressure?.date, hours(-2))
    }

    func testVersion2CacheDropsHRVWithoutKindAndKeepsTheRest() throws {
        let directory = try temporaryDirectory()
        let date = hours(-1).timeIntervalSinceReferenceDate
        let json = """
        {"schemaVersion":2,"live":{"hrv":44,"heartRate":70},"liveDates":["hrv",\(date),"heartRate",\(date)],
         "heartRate":[{"date":\(date),"bpm":70}],"bloodPressure":[],"bloodOxygen":[],"temperature":[],
         "hrv":[{"date":\(date),"milliseconds":44}],"respiration":[],
         "bodyMetrics":[{"date":\(date),"stress":4.5}],"activity":[],"sleep":[],"metabolic":[]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("health-store.json"))
        let store = makeStore(directory: directory)
        XCTAssertEqual(store.heartRate.map(\.bpm), [70])
        XCTAssertEqual(store.bodyMetrics.count, 1, "version 2 stress values are valid")
        XCTAssertTrue(store.hrv.isEmpty)
        XCTAssertNil(store.live.hrv)
        XCTAssertEqual(store.latestHeartRate?.value, 70)
    }

    func testVersion1CacheAlsoDropsBodyMetrics() throws {
        let directory = try temporaryDirectory()
        let date = hours(-1).timeIntervalSinceReferenceDate
        let json = """
        {"live":{"stress":55},"heartRate":[{"date":\(date),"bpm":70}],"bloodPressure":[],"bloodOxygen":[],
         "temperature":[],"hrv":[],"respiration":[],"bodyMetrics":[{"date":\(date),"stress":55}],
         "activity":[],"sleep":[],"metabolic":[]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("health-store.json"))
        let store = makeStore(directory: directory)
        XCTAssertEqual(store.heartRate.count, 1)
        XCTAssertTrue(store.bodyMetrics.isEmpty)
        XCTAssertNil(store.live.stress)
    }

    func testUnreadableCacheIsKeptAsBackup() throws {
        let directory = try temporaryDirectory()
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("health-store.json"))
        let store = makeStore(directory: directory)
        XCTAssertTrue(store.heartRate.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("health-store.json.bak").path))
    }
}
