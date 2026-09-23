import Foundation

/// Little-endian readers for the ring's packed binary records.
///
/// Callers are responsible for checking lengths before reading; every parser in
/// `YCParsers` guards its record size first, so these helpers stay branch-free.
extension Array where Element == UInt8 {
    func u8(_ index: Int) -> Int {
        Int(self[index])
    }

    func u16le(_ index: Int) -> Int {
        Int(self[index]) | Int(self[index + 1]) << 8
    }

    func u24le(_ index: Int) -> Int {
        Int(self[index]) | Int(self[index + 1]) << 8 | Int(self[index + 2]) << 16
    }

    func u32le(_ index: Int) -> UInt32 {
        let low = UInt32(self[index]) | UInt32(self[index + 1]) << 8
        let high = UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
        return low | high
    }

    /// Hex dump such as `05 04 06 00 7B 1C`, used for diagnostics.
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

extension UInt16 {
    var littleEndianBytes: [UInt8] {
        [UInt8(self & 0xFF), UInt8(self >> 8)]
    }
}

/// The vendor encodes decimals as two bytes, "integer part" and "fraction part",
/// and the SDK rebuilds them by string concatenation (`"36" + "." + "5"`).
/// We do the same so a fraction byte of 12 means `.12`, exactly as the vendor app shows it.
func vendorDecimal(integer: Int, fraction: Int) -> Double {
    Double("\(integer).\(fraction)") ?? Double(integer)
}
