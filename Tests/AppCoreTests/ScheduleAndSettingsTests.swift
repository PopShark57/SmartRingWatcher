import XCTest
@testable import RingCore

final class HistoryScheduleTests: XCTestCase {
    private let schedule = HistorySchedule(baseInterval: 15 * 60)
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: referenceDate)!
    }

    func testFrequentTypesFollowTheBaseInterval() {
        XCTAssertTrue(schedule.isDue(.historyHeart, lastSync: nil, newestSleepEnd: nil, now: at(10)))
        XCTAssertFalse(schedule.isDue(.historyHeart, lastSync: at(10), newestSleepEnd: nil, now: at(10, 10)))
        XCTAssertTrue(schedule.isDue(.historyHeart, lastSync: at(10), newestSleepEnd: nil, now: at(10, 15)))
        XCTAssertFalse(schedule.isDue(.historyBlood, lastSync: at(10), newestSleepEnd: nil, now: at(10, 15)))
        XCTAssertTrue(schedule.isDue(.historyBlood, lastSync: at(10), newestSleepEnd: nil, now: at(10, 45)))
    }

    func testSleepSyncsOnceInTheMorningThenHourlyUntilLastNightArrives() {
        // Synced at 23:00 yesterday: not due at 05:00, due at the first check after 06:00.
        let lastNight = at(23).addingTimeInterval(-86_400)
        XCTAssertFalse(schedule.isDue(.historySleep, lastSync: lastNight, newestSleepEnd: nil, now: at(5)))
        XCTAssertTrue(schedule.isDue(.historySleep, lastSync: lastNight, newestSleepEnd: nil, now: at(6, 5)))
        // Synced at 06:05 but last night isn't there yet: retry hourly.
        let oldSleep = at(7).addingTimeInterval(-86_400)
        XCTAssertFalse(schedule.isDue(.historySleep, lastSync: at(6, 5), newestSleepEnd: oldSleep, now: at(6, 40)))
        XCTAssertTrue(schedule.isDue(.historySleep, lastSync: at(6, 5), newestSleepEnd: oldSleep, now: at(7, 5)))
        // Last night arrived: done for the day.
        XCTAssertFalse(schedule.isDue(.historySleep, lastSync: at(7, 5), newestSleepEnd: at(6, 50), now: at(15)))
    }

    func testBloodChemistryOnlyWhenOptedIn() {
        XCTAssertFalse(schedule.isDue(.historyComprehensive, lastSync: nil, newestSleepEnd: nil, now: at(10)))
        var optedIn = schedule
        optedIn.includesBloodChemistry = true
        XCTAssertTrue(optedIn.isDue(.historyComprehensive, lastSync: nil, newestSleepEnd: nil, now: at(10)))
        XCTAssertFalse(optedIn.isDue(.historyComprehensive, lastSync: at(8), newestSleepEnd: nil, now: at(10)))
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    func testRemovedHistoryIntervalFallsBackToFifteenMinutes() {
        let defaults = makeDefaults()
        defaults.set(1, forKey: AppSettings.Key.historyRefreshMinutes.rawValue)
        XCTAssertEqual(AppSettings(defaults: defaults).historyRefreshMinutes, 15)
    }

    func testLegacyFahrenheitSwitchIsMigrated() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "useFahrenheit")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.temperatureUnit, .fahrenheit)
        XCTAssertTrue(settings.usesFahrenheit)
        XCTAssertEqual(settings.temperatureValue(37), 98.6, accuracy: 0.001)
    }

    func testObserversHearAboutChanges() {
        let settings = AppSettings(defaults: makeDefaults())
        var keys: [AppSettings.Key] = []
        settings.observe { keys.append($0) }
        settings.stepGoal = 8_000
        settings.liveStreaming = true
        XCTAssertEqual(keys, [.stepGoal, .liveStreaming])
    }

    func testTilesMoveWithinTheirSectionAndCanBeHidden() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.tiles(in: .heart), [.heartRate, .hrv, .stress])
        settings.move(.stress, by: -1)
        XCTAssertEqual(settings.tiles(in: .heart), [.heartRate, .stress, .hrv])
        settings.move(.heartRate, by: -1) // already first: no change
        XCTAssertEqual(settings.tiles(in: .heart), [.heartRate, .stress, .hrv])
        settings.hiddenTiles.insert(.hrv)
        XCTAssertEqual(settings.tiles(in: .heart), [.heartRate, .stress])
        XCTAssertEqual(AppSettings(defaults: defaults).tiles(in: .heart), [.heartRate, .stress])
    }
}

final class BloodChemistryTests: XCTestCase {
    func testUnitConversion() {
        XCTAssertEqual(ChemistryMarker.glucose.format(5.5, milligramsPerDeciliter: true).value, "99")
        XCTAssertEqual(ChemistryMarker.glucose.format(5.5, milligramsPerDeciliter: false).unit, "mmol/L")
        XCTAssertEqual(ChemistryMarker.totalCholesterol.format(5.0, milligramsPerDeciliter: true).value, "193")
        XCTAssertEqual(ChemistryMarker.triglycerides.format(1.5, milligramsPerDeciliter: true).value, "133")
        XCTAssertEqual(ChemistryMarker.uricAcid.format(300, milligramsPerDeciliter: false).unit, "µmol/L")
        XCTAssertEqual(ChemistryMarker.ketone.format(0.3, milligramsPerDeciliter: true).unit, "mmol/L")
    }
}
