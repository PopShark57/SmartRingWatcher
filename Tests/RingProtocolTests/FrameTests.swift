import XCTest
@testable import RingProtocol

final class FrameTests: XCTestCase {

    func testCRCMatchesCCITTFalseCheckValue() {
        // Standard check value for CRC-16/CCITT-FALSE; also what the vendor SDK returns.
        XCTAssertEqual(CRC16.ccittFalse(Array("123456789".utf8)), 0x29B1)
    }

    /// Expected bytes produced by the vendor SDK's `sendData2Device` framing code.
    func testEncodingMatchesVendorSDK() {
        XCTAssertEqual(YCCommand.history(.historySleep).bytes, hex("05 04 06 00 E3 4E"))
        XCTAssertEqual(YCCommand.deviceInfo.bytes, hex("02 00 08 00 47 43 6F EC"))
        XCTAssertEqual(YCCommand.allRealData.bytes, hex("02 20 06 00 C8 45"))
        XCTAssertEqual(YCCommand.startMeasurement(.bloodPressure).bytes, hex("03 2F 08 00 01 01 6E 0B"))
        XCTAssertEqual(YCCommand.historyTransferOK.bytes, hex("05 80 07 00 00 F3 6A"))
        XCTAssertEqual(YCCommand.acknowledge(.deviceMeasurementResult).bytes, hex("04 0E 07 00 00 C0 BF"))
    }

    func testDecodeRoundTrip() throws {
        let frame = YCFrame(.realBlood, [120, 80, 70])
        let decoded = try XCTUnwrap(YCFrame.decode(frame.bytes))
        XCTAssertEqual(decoded.frame, frame)
        XCTAssertTrue(decoded.crcValid)
    }

    func testDecodeRejectsLengthMismatch() {
        var bytes = YCFrame(.realHeart, [72]).bytes
        bytes.append(0x00)
        XCTAssertNil(YCFrame.decode(bytes))
    }

    func testAssemblerJoinsFragments() {
        let frame = YCFrame(.historyHeart, Array(repeating: 0x11, count: 40))
        let bytes = frame.bytes
        var assembler = YCFrameAssembler()
        let t0 = Date()
        XCTAssertEqual(assembler.append(Array(bytes[0..<20]), at: t0), [])
        XCTAssertEqual(assembler.append(Array(bytes[20...]), at: t0.addingTimeInterval(0.05)), [frame])
        XCTAssertTrue(assembler.buffer.isEmpty)
    }

    func testAssemblerSplitsBackToBackFrames() {
        let a = YCFrame(.realHeart, [72])
        let b = YCFrame(.realBloodOxygen, [98])
        var assembler = YCFrameAssembler()
        XCTAssertEqual(assembler.append(a.bytes + b.bytes), [a, b])
    }

    func testAssemblerDropsStaleFragment() {
        let full = YCFrame(.historyHeart, Array(repeating: 0x22, count: 40)).bytes
        var assembler = YCFrameAssembler()
        let t0 = Date()
        _ = assembler.append(Array(full[0..<20]), at: t0)
        // The rest of the frame never arrives; a new, unrelated frame starts later.
        let next = YCFrame(.realHeart, [65])
        XCTAssertEqual(assembler.append(next.bytes, at: t0.addingTimeInterval(10)), [next])
    }

    func testErrorReplyDetection() {
        XCTAssertTrue(YCFrame(.getAllRealData, [0xFC]).isErrorReply)
        XCTAssertFalse(YCFrame(.appStartMeasurement, [0x00]).isErrorReply)
    }

    func testRingTimeConversion() {
        XCTAssertEqual(YCTime.date(fromRingSeconds: baseRingSeconds, timeZone: utc), baseDate)
        XCTAssertEqual(YCTime.ringSeconds(from: baseDate, timeZone: utc), baseRingSeconds)

        // The ring stores local wall-clock time: 16:12:48 local in UTC+2 is 14:12:48Z.
        let plus2 = TimeZone(secondsFromGMT: 7200)!
        XCTAssertEqual(YCTime.date(fromRingSeconds: baseRingSeconds, timeZone: plus2),
                       baseDate.addingTimeInterval(-7200))
    }

    func testClockPayloadMatchesSDKLayout() {
        // 2025-07-08 (a Tuesday) 16:12:48 → year LE, month, day, h, m, s, weekday (Mon = 0).
        XCTAssertEqual(YCTime.clockPayload(for: baseDate, timeZone: utc),
                       [0xE9, 0x07, 7, 8, 16, 12, 48, 1])
    }
}
