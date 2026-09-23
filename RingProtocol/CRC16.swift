import Foundation

/// CRC-16/CCITT-FALSE (polynomial 0x1021, initial value 0xFFFF, no reflection, no final XOR).
///
/// This is the byte-wise variant used by Nordic's `crc16_compute` and by the ring
/// vendor's SDK (`com.yucheng.ycbtsdk.utils.ByteUtil.crc16_compute`). Every YC frame
/// ends with this checksum, and multi-frame history transfers are verified with it.
enum CRC16 {
    static func ccittFalse<S: Sequence>(_ bytes: S, seed: UInt16 = 0xFFFF) -> UInt16 where S.Element == UInt8 {
        var crc = seed
        for byte in bytes {
            crc = (crc >> 8) | (crc << 8)
            crc ^= UInt16(byte)
            crc ^= (crc & 0x00FF) >> 4
            crc ^= crc << 12
            crc ^= (crc & 0x00FF) << 5
        }
        return crc
    }
}
