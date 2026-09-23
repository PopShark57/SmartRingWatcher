import XCTest
@testable import RingProtocol

final class SessionTests: XCTestCase {

    private func makeSession() -> YCProtocolSession {
        YCProtocolSession(timeZone: utc, clock: { baseDate })
    }

    /// Header → data → end marker, exactly as the ring sends a heart-rate history.
    func testHistoryTransferIsReassembledVerifiedAndAcknowledged() {
        let session = makeSession()
        let data = Vectors.heart // two 6-byte records, CRC 0x6FA5 per the vendor SDK
        let header = YCFrame(YCDataType(group: 0x05, key: 0x06), hex("0200 01000000 0C000000"))
        let block = YCFrame(YCDataType(group: 0x05, key: 0x15), data)
        let end = YCFrame(.historyBlock, hex("0100 0C00 A56F"))

        XCTAssertEqual(session.receive(header.data), .init())
        XCTAssertTrue(session.isReceivingHistory)
        XCTAssertEqual(session.receive(block.data), .init())

        let out = session.receive(end.data)
        XCTAssertFalse(session.isReceivingHistory)
        XCTAssertEqual(out.replies, [YCCommand.historyTransferOK])
        var expected = HealthBatch()
        expected.heartRate = [HeartRateSample(date: baseDate, bpm: 72)]
        XCTAssertEqual(out.events, [.samples(expected), .completed(.historyHeart, success: true)])
    }

    func testHistoryTransferWithBadCRCAsksForRetry() {
        let session = makeSession()
        _ = session.receive(YCFrame(YCDataType(group: 0x05, key: 0x06), hex("0200 01000000 0C000000")).data)
        _ = session.receive(YCFrame(YCDataType(group: 0x05, key: 0x15), Vectors.heart).data)
        let out = session.receive(YCFrame(.historyBlock, hex("0100 0C00 0000")).data)
        XCTAssertEqual(out.replies, [YCCommand.historyTransferFailed])
        XCTAssertEqual(out.events, [.completed(.historyHeart, success: false)])
    }

    func testEmptyHistoryCompletesImmediately() {
        let session = makeSession()
        let out = session.receive(YCFrame(.historySleep, [0x00, 0x00]).data)
        XCTAssertEqual(out.events, [.completed(.historySleep, success: true)])
        XCTAssertFalse(session.isReceivingHistory)
    }

    func testUnsupportedCommandCompletesWithFailure() {
        let session = makeSession()
        let out = session.receive(YCFrame(.historyBody, [0xFC]).data)
        XCTAssertEqual(out.events, [.completed(.historyBody, success: false)])
    }

    func testDeviceEventsAreAcknowledged() {
        let session = makeSession()
        let out = session.receive(YCFrame(.deviceMeasurementResult, [0x01, 0x01]).data)
        XCTAssertEqual(out.replies, [YCCommand.acknowledge(.deviceMeasurementResult)])
        XCTAssertEqual(out.events, [.measurementFinished(.bloodPressure, .success)])
    }

    func testMeasurementResultProducesSample() {
        let session = makeSession()
        // type 1 (BP), state 1, 125/82, padded to the SDK's minimum of 24 bytes.
        let payload: [UInt8] = [0x01, 0x01, 125, 82] + Array(repeating: 0, count: 20)
        let out = session.receive(YCFrame(.deviceMeasureStatusAndResults, payload).data)
        var expected = HealthBatch()
        expected.bloodPressure = [BloodPressureSample(date: baseDate, systolic: 125, diastolic: 82, heartRate: nil)]
        XCTAssertEqual(out.events, [.samples(expected)])
        XCTAssertEqual(out.replies.count, 1)
    }

    func testLiveHeartRateAndDeviceInfo() {
        let session = makeSession()
        var hr = LiveSnapshot(updatedAt: baseDate)
        hr.heartRate = 68
        XCTAssertEqual(session.receive(YCFrame(.realHeart, [68]).data).events, [.live(hr)])

        let out = session.receive(YCFrame(.getDeviceInfo, hex("3412 05 01 01 32 01 00")).data)
        XCTAssertEqual(out.events.first, .deviceInfo(DeviceInfo(deviceID: 0x1234, firmwareVersion: "1.05",
                                                                batteryPercent: 50, batteryState: 1)))
        XCTAssertEqual(out.events.last, .completed(.getDeviceInfo, success: true))
    }

    func testZeroHeartRateIsNotReported() {
        let session = makeSession()
        XCTAssertEqual(session.receive(YCFrame(.realHeart, [0]).data).events, [])
    }
}
