import Foundation

/// One YC protocol frame.
///
/// Wire format (all little-endian):
/// ```
/// [group][key][totalLength lo][totalLength hi][payload …][crc lo][crc hi]
/// ```
/// `totalLength` counts every byte including the 4-byte header and the 2-byte CRC,
/// and the CRC-16/CCITT-FALSE covers everything before it.
struct YCFrame: Equatable, CustomStringConvertible, Sendable {
    static let overhead = 6

    let dataType: YCDataType
    let payload: [UInt8]

    init(_ dataType: YCDataType, _ payload: [UInt8] = []) {
        self.dataType = dataType
        self.payload = payload
    }

    var bytes: [UInt8] {
        let total = UInt16(payload.count + YCFrame.overhead)
        var out: [UInt8] = [dataType.group, dataType.key]
        out += total.littleEndianBytes
        out += payload
        out += CRC16.ccittFalse(out).littleEndianBytes
        return out
    }

    var data: Data { Data(bytes) }

    /// A one-byte payload of 0xFB…0xFF is the ring's way of saying "unsupported command",
    /// "unsupported key", or a length / CRC error (SDK: `YCBTClientImpl.isError`).
    var isErrorReply: Bool {
        payload.count == 1 && payload[0] >= 0xFB
    }

    var description: String {
        "\(dataType) [\(payload.hexString)]"
    }

    /// Decodes exactly one complete frame. Returns `nil` if the length field disagrees
    /// with the byte count. The CRC is reported but not enforced, because the vendor SDK
    /// does not enforce it either and some firmware revisions are sloppy about it.
    static func decode(_ bytes: [UInt8]) -> (frame: YCFrame, crcValid: Bool)? {
        guard bytes.count >= overhead else { return nil }
        let total = bytes.u16le(2)
        guard total == bytes.count else { return nil }
        let payload = Array(bytes[4..<(total - 2)])
        let receivedCRC = UInt16(bytes.u16le(total - 2))
        let computedCRC = CRC16.ccittFalse(bytes[0..<(total - 2)])
        let frame = YCFrame(YCDataType(group: bytes[0], key: bytes[1]), payload)
        return (frame, receivedCRC == computedCRC)
    }
}

/// Reassembles frames that the ring splits across several BLE notifications
/// (anything longer than the negotiated ATT MTU arrives in pieces).
struct YCFrameAssembler {
    /// Partial data older than this is assumed to be a lost fragment and is discarded.
    var staleAfter: TimeInterval = 3

    private(set) var buffer: [UInt8] = []
    private var lastAppend: Date = .distantPast
    private(set) var crcErrors = 0

    mutating func append(_ chunk: [UInt8], at now: Date = Date()) -> [YCFrame] {
        guard !chunk.isEmpty else { return [] }

        if !buffer.isEmpty {
            let stale = now.timeIntervalSince(lastAppend) > staleAfter
            // A notification that is itself a complete, valid frame always starts fresh:
            // it means whatever we were holding was an orphaned fragment.
            let chunkIsWholeFrame = YCFrame.decode(chunk)?.crcValid == true
            if stale || chunkIsWholeFrame {
                buffer.removeAll()
            }
        }
        lastAppend = now
        buffer += chunk

        var frames: [YCFrame] = []
        while buffer.count >= 4 {
            let total = buffer.u16le(2)
            guard total >= YCFrame.overhead else {
                // Not a frame header; drop everything and wait for the next notification.
                buffer.removeAll()
                break
            }
            guard buffer.count >= total else { break }
            let candidate = Array(buffer[0..<total])
            buffer.removeFirst(total)
            if let decoded = YCFrame.decode(candidate) {
                if !decoded.crcValid { crcErrors += 1 }
                frames.append(decoded.frame)
            }
        }
        return frames
    }

    mutating func reset() {
        buffer.removeAll()
    }
}
