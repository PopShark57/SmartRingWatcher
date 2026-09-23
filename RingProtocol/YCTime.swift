import Foundation

/// Time conventions of the YC protocol.
///
/// The ring keeps a *local wall-clock* time and stores record timestamps as seconds since
/// 2000-01-01 00:00:00 of that local clock. The vendor SDK converts them back with
/// `(raw + 946684800) * 1000 - timeZoneOffset`, which is what `date(fromRingSeconds:)` does.
enum YCTime {
    /// Seconds between 1970-01-01 and 2000-01-01 (the SDK's `SecFrom30Year`).
    static let epochOffset: TimeInterval = 946_684_800

    static func date(fromRingSeconds raw: UInt32, timeZone: TimeZone = .current) -> Date {
        let wallClockAsUTC = Date(timeIntervalSince1970: TimeInterval(raw) + epochOffset)
        let offset = timeZone.secondsFromGMT(for: wallClockAsUTC)
        return wallClockAsUTC.addingTimeInterval(-TimeInterval(offset))
    }

    static func ringSeconds(from date: Date, timeZone: TimeZone = .current) -> UInt32 {
        let local = date.timeIntervalSince1970 + TimeInterval(timeZone.secondsFromGMT(for: date))
        return UInt32(clamping: Int64(local - epochOffset))
    }

    /// Payload for `settingTime` (0x0100), matching the SDK's `TimeUtil.makeBleTime()`:
    /// `[yearLo, yearHi, month, day, hour, minute, second, weekday]` where weekday is
    /// Monday = 0 … Sunday = 6.
    static func clockPayload(for date: Date, timeZone: TimeZone = .current) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let year = UInt16(clamping: c.year ?? 2000)
        // Calendar weekday: Sunday = 1 … Saturday = 7.
        let weekday = c.weekday ?? 2
        let ringWeekday = weekday == 1 ? 6 : weekday - 2
        return year.littleEndianBytes + [
            UInt8(clamping: c.month ?? 1),
            UInt8(clamping: c.day ?? 1),
            UInt8(clamping: c.hour ?? 0),
            UInt8(clamping: c.minute ?? 0),
            UInt8(clamping: c.second ?? 0),
            UInt8(clamping: ringWeekday),
        ]
    }
}
