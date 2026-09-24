import Foundation
@testable import RingProtocol

/// "05 04 06 00" → [0x05, 0x04, 0x06, 0x00]. Spaces are ignored.
func hex(_ string: String) -> [UInt8] {
    let digits = string.filter { !$0.isWhitespace }
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        bytes.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

let utc = TimeZone(identifier: "UTC")!

/// Ring timestamp 0x30000000 used by all vectors = 2025-07-08T16:12:48Z.
let baseRingSeconds: UInt32 = 0x3000_0000
let baseDate = Date(timeIntervalSince1970: 1_751_991_168)

/// Test vectors. Expected values were produced by running the vendor SDK's own
/// `DataUnpack.unpackHealthData` (from ycbtsdk-release.aar) on the JVM with TZ=UTC.
enum Vectors {
    static let heart = hex("00000030 00 48 2C010030 00 00")
    static let blood = hex("00000030 00 78 50 46")
    static let sport = hex("00000030 100E0030 D204 5203 2D00")
    static let all = hex("00000030 6400 41 76 4C 62 10 2D 05 24 05 00 00 00 0000")
    static let bloodOxygen = hex("00000030 00 61")
    static let temperature = hex("00000030 00 24 07")
    static let sleep = hex("""
        AFFA 3400 00000030 44160030 FFFF 0807 0807 0807
        F2 00000030 080700  F1 08070030 080700  F3 100E0030 080700  F4 18150030 2C0100
        AFFA 1C00 00000130 100E0130 0200 0300 1E00 3C00
        F1 00000130 080700
        """)
    /// Fatigue 3.5, HRV index 4.2, stress 5.5, body 6.0, balance 1.3 (0–10 indices),
    /// SDNN 50 ms, VO2max 38, pNN50 12, RMSSD 35 ms, LF 500, HF 400, LF/HF 1.2.
    static let body = hex("00000030 0305 0402 0505 0600 0103 3200 26 0C 2300 F401 9001 0C 000000")
    static let comprehensive = hex("00000030 01 05 06 01 4001 01 00 03 01 0405 0102 0208 0105" + String(repeating: "00", count: 22))
}
