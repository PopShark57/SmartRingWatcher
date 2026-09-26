import XCTest
@testable import RingCore

@MainActor
final class EngineTests: XCTestCase {

    func testFirstSyncRequestsEveryHistoryTypeExceptHiddenBloodChemistry() {
        let h = EngineHarness()
        h.connect()
        var expected = Set(HistorySchedule.allTypes)
        expected.remove(.historyComprehensive)
        XCTAssertEqual(h.historyRequests, expected)
        XCTAssertTrue(h.requests.contains(.settingTime), "the ring clock is set on connect")
        XCTAssertFalse(h.engine.isSyncingHistory)
        XCTAssertNotNil(h.engine.lastHistorySync)
    }

    /// F9: later syncs only pull what is due instead of the whole history every time.
    func testLaterSyncsFollowPerTypeIntervals() {
        let h = EngineHarness()
        h.connect()
        h.clear()

        h.run(for: 15 * 60)
        XCTAssertEqual(h.historyRequests, [.historyHeart, .historySport, .historyAll])

        h.clear()
        h.run(for: 30 * 60) // 45 min after connecting
        XCTAssertTrue(h.historyRequests.isSuperset(of: [.historyBlood, .historyBloodOxygen, .historyTemperature, .historyBody]))
        XCTAssertFalse(h.historyRequests.contains(.historySleep), "sleep was synced this morning already")
    }

    func testSyncNowRequestsEverythingAgain() {
        let h = EngineHarness()
        h.connect()
        h.clear()
        h.engine.refreshNow()
        h.run(for: 5)
        XCTAssertTrue(h.historyRequests.contains(.historySleep))
        XCTAssertTrue(h.requests.contains(.getAllRealData))
    }

    /// F5: a background refresh only records heart rate and steps as synced.
    func testBackgroundRefreshFetchesOnlyHeartAndStepsAndLeavesTheRestDue() {
        let h = EngineHarness()
        h.engine.setForeground(false)
        var completed = false
        h.engine.performBackgroundSync { completed = true }
        XCTAssertEqual(h.transport.connectCalls, 1)
        h.connect()
        XCTAssertTrue(completed)
        XCTAssertEqual(h.historyRequests, [.historyHeart, .historySport])

        h.clear()
        h.engine.setForeground(true)
        h.run(for: 5)
        XCTAssertTrue(h.historyRequests.contains(.historySleep), "opening the app still fetches sleep")
        XCTAssertFalse(h.historyRequests.contains(.historyHeart), "heart rate was just synced in the background")
    }

    /// F6: a result of unknown kind while nothing is measured isn't shown as heart rate.
    func testMeasurementResultOfUnknownKindIsIgnored() {
        let h = EngineHarness()
        h.connect()
        h.clear()
        h.transport.receive(YCFrame(.deviceMeasurementResult, [0x09, 0x01]))
        h.run(for: 1)
        XCTAssertNil(h.engine.lastMeasurementOutcome)
        XCTAssertFalse(h.historyRequests.contains(.historyHeart))
    }

    func testSuccessfulMeasurementFetchesItsHistory() {
        let h = EngineHarness()
        h.connect()
        h.engine.startMeasurement(.bloodPressure)
        h.run(for: 1)
        XCTAssertEqual(h.engine.activeMeasurement, .bloodPressure)
        h.clear()
        h.transport.receive(YCFrame(.deviceMeasurementResult, [0x01, 0x01]))
        h.run(for: 2)
        XCTAssertNil(h.engine.activeMeasurement)
        XCTAssertEqual(h.engine.lastMeasurementOutcome?.outcome, .success)
        XCTAssertTrue(h.historyRequests.contains(.historyBlood))
    }

    func testMeasurementTimesOut() {
        let h = EngineHarness()
        h.connect()
        h.engine.startMeasurement(.heartRate)
        h.run(for: 91)
        XCTAssertNil(h.engine.activeMeasurement)
        XCTAssertEqual(h.engine.lastMeasurementOutcome?.outcome, .failed)
    }

    /// F8: "unsupported" disables a type for the connection…
    func testUnsupportedTypeIsNotRequestedAgain() {
        let h = EngineHarness()
        h.reply = { $0 == .historyBody ? [0xFC] : EngineHarness.defaultReply($0) }
        h.connect()
        XCTAssertEqual(h.engine.commandStatus[.historyBody]?.state, .unsupported)
        h.clear()
        h.engine.refreshNow()
        h.run(for: 5)
        XCTAssertFalse(h.historyRequests.contains(.historyBody))
        XCTAssertTrue(h.historyRequests.contains(.historyHeart))
    }

    /// …while a timeout is retried with backoff instead of being given up on.
    func testTimeoutIsRetriedWithBackoff() {
        let h = EngineHarness()
        var sleepSilent = true
        h.reply = { type in
            if type == .historySleep && sleepSilent { return nil }
            return EngineHarness.defaultReply(type)
        }
        h.connect()
        h.run(for: 20)
        XCTAssertEqual(h.engine.commandStatus[.historySleep]?.state, .failing)
        XCTAssertEqual(h.engine.commandStatus[.historySleep]?.failures, 1)

        h.clear()
        h.engine.refreshNow()
        h.run(for: 2)
        XCTAssertFalse(h.historyRequests.contains(.historySleep), "still backing off")

        sleepSilent = false
        h.run(for: 30)
        h.clear()
        h.engine.refreshNow()
        h.run(for: 2)
        XCTAssertTrue(h.historyRequests.contains(.historySleep), "retried after the backoff")
        XCTAssertEqual(h.engine.commandStatus[.historySleep]?.state, .ok)
    }

    /// F4: travelling or a DST change sets the ring clock right away.
    func testTimeZoneChangeSetsTheRingClock() {
        let h = EngineHarness()
        h.connect()
        h.clear()
        h.engine.systemTimeDidChange()
        h.run(for: 1)
        XCTAssertEqual(h.requests, [.settingTime])
    }

    func testClockIsSetAgainDaily() {
        let h = EngineHarness()
        h.connect()
        h.clear()
        h.run(for: 24 * 3600 + 30, step: 5)
        XCTAssertTrue(h.requests.contains(.settingTime))
    }

    /// F1: the engine passes "polled" through, so a repeated poll keeps its date.
    func testPolledSnapshotDoesNotRestampUnchangedValues() {
        let h = EngineHarness()
        h.connect()
        let firstBP = h.realStore.latestBloodPressure?.date
        XCTAssertNotNil(firstBP)
        h.run(for: 60)
        XCTAssertEqual(h.realStore.latestBloodPressure?.date, firstBP)
    }

    /// F3: demo mode has its own store and releases the ring.
    func testDemoModeUsesItsOwnStoreAndSuspendsTheTransport() {
        let h = EngineHarness()
        h.connect()
        let realHeartRate = h.realStore.latestHeartRate
        XCTAssertNotNil(realHeartRate)

        h.settings.demoMode = true
        XCTAssertTrue(h.transport.isSuspended)
        XCTAssertTrue(h.engine.store === h.demoStore)
        XCTAssertFalse(h.demoStore.heartRate.isEmpty)
        XCTAssertEqual(h.realStore.latestHeartRate, realHeartRate, "the real cache is untouched")

        h.settings.demoMode = false
        XCTAssertFalse(h.transport.isSuspended)
        XCTAssertTrue(h.engine.store === h.realStore)
        XCTAssertEqual(h.realStore.latestHeartRate, realHeartRate)
    }

    /// A3: a setting changed anywhere reaches the engine.
    func testStreamingSettingIsSentWithoutAnyView() {
        let h = EngineHarness()
        h.connect()
        h.clear()
        h.settings.liveStreaming = true
        h.run(for: 1)
        XCTAssertEqual(h.requests.filter { $0 == .appRealDataSwitch }.count, 2)
    }

    /// F13: rings without the YC protocol get their battery re-read.
    func testStandardGATTRingBatteryIsReRead() {
        let h = EngineHarness()
        h.transport.hasProtocolChannel = false
        h.connect()
        h.run(for: 6 * 60, step: 5)
        XCTAssertGreaterThanOrEqual(h.transport.batteryReads, 1)
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testPairingADifferentRingResetsSyncDates() {
        let h = EngineHarness()
        h.connect()
        h.transport.drop()
        h.transport.connectedRingID = UUID()
        h.clear()
        h.connect()
        XCTAssertTrue(h.historyRequests.contains(.historySleep))
    }

    /// S2: HRV from standard RR intervals only appears after a minute's worth of clean beats.
    func testGattHRVNeedsEnoughBeats() {
        let h = EngineHarness()
        h.transport.hasProtocolChannel = false
        h.connect()
        for beat in 0..<10 {
            h.engine.transport(h.transport, didReceiveHeartRate: 72, rrIntervals: [beat.isMultiple(of: 2) ? 0.82 : 0.84])
            h.scheduler.advance(by: 0.8)
        }
        XCTAssertNil(h.realStore.live.hrv, "10 beats aren't enough")
        for beat in 0..<30 {
            h.engine.transport(h.transport, didReceiveHeartRate: 72, rrIntervals: [beat.isMultiple(of: 2) ? 0.82 : 0.84])
            h.scheduler.advance(by: 0.8)
        }
        XCTAssertEqual(h.realStore.live.hrv ?? 0, 20, accuracy: 1)
        XCTAssertEqual(h.realStore.live.hrvKind, .rmssd)
    }
}
