import XCTest
@testable import RingCore

final class RRIntervalWindowTests: XCTestCase {
    func testNeedsThirtyCleanBeats() {
        var window = RRIntervalWindow()
        window.add(Array(repeating: 0.8, count: 29), at: baseDate)
        XCTAssertNil(window.rmssd)
        window.add([0.8], at: baseDate)
        XCTAssertEqual(window.rmssd ?? -1, 0, accuracy: 0.0001)
    }

    func testRMSSDOfAlternatingIntervals() {
        var window = RRIntervalWindow()
        window.add((0..<40).map { $0.isMultiple(of: 2) ? 0.80 : 0.85 }, at: baseDate)
        // Every successive difference is 50 ms.
        XCTAssertEqual(window.rmssd ?? 0, 50, accuracy: 0.001)
    }

    func testArtifactsAreRejectedAndNotBridged() {
        var window = RRIntervalWindow()
        var intervals = Array(repeating: 0.8, count: 40)
        intervals[10] = 1.6 // missed beat: > 20 % jump
        intervals[20] = 0.1 // implausible
        window.add(intervals, at: baseDate)
        XCTAssertEqual(window.beatCount, 38)
        XCTAssertEqual(window.rmssd ?? -1, 0, accuracy: 0.0001, "no difference is taken across a rejected beat")
    }

    func testOldBeatsLeaveTheWindow() {
        var window = RRIntervalWindow()
        window.add(Array(repeating: 0.8, count: 40), at: baseDate)
        window.add([0.8], at: baseDate.addingTimeInterval(61))
        XCTAssertEqual(window.beatCount, 1)
        XCTAssertNil(window.rmssd)
    }
}
