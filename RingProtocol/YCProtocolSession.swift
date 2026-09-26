import Foundation

enum MeasurementOutcome: String, Codable, Sendable {
    case success, failed, cancelled, unknown
}

/// How a request/response exchange ended.
enum CommandResult: Equatable, Sendable {
    case success
    /// Transient: a timeout, a bad transfer CRC, or a length/CRC error reply. Worth retrying.
    case failed
    /// The ring answered "unsupported command" (`0xFB`) or "unsupported key" (`0xFC`).
    case unsupported
}

/// Everything the protocol layer can tell the app about.
enum RingEvent: Equatable {
    /// New live values (only the fields the ring reported are set). `pushed` is true for
    /// real-time uploads the ring streams by itself, false for replies to polls, which may
    /// repeat an older measurement.
    case live(LiveSnapshot, pushed: Bool)
    /// Timestamped samples decoded from history or measurement results.
    case samples(HealthBatch)
    case deviceInfo(DeviceInfo)
    /// A request/response exchange finished; the command queue may send the next command.
    case completed(YCDataType, CommandResult)
    /// A history transfer arrived intact: its size on the air and the records it held.
    case historyReceived(YCDataType, bytes: Int, records: Int)
    /// A one-off measurement started with `YCCommand.startMeasurement` has ended.
    case measurementFinished(MeasurementKind?, MeasurementOutcome)
}

/// The pure (Bluetooth-free) half of the ring protocol.
///
/// Feed it every notification from the ring; it reassembles frames, runs the multi-frame
/// history handshake, and returns decoded events plus any frames that must be written back
/// (acknowledgements). Because it has no I/O it is fully unit-testable.
final class YCProtocolSession {
    struct Output: Equatable {
        var events: [RingEvent] = []
        var replies: [YCFrame] = []
    }

    /// Keys of history "header" frames, which carry the request key (SDK `packetHealthHandle`).
    static let historyHeaderKeys: Set<UInt8> = [
        0x02, 0x04, 0x06, 0x08, 0x09, 0x1A, 0x1C, 0x1E, 0x20,
        0x29, 0x2B, 0x2D, 0x2F, 0x31, 0x33, 0x35, 0x37, 0x39, 0x3B, 0x66,
    ]
    /// Key of the end-of-transfer frame (`Health_HistoryBlock`).
    static let historyEndKey: UInt8 = 0x80

    private struct Transfer {
        let requestKey: UInt8
        var bytes: [UInt8] = []
    }

    var timeZone: TimeZone
    private let clock: () -> Date
    private var assembler = YCFrameAssembler()
    private var transfer: Transfer?

    init(timeZone: TimeZone = .current, clock: @escaping () -> Date = { Date() }) {
        self.timeZone = timeZone
        self.clock = clock
    }

    var isReceivingHistory: Bool { transfer != nil }
    var crcErrors: Int { assembler.crcErrors }

    func reset() {
        assembler.reset()
        transfer = nil
    }

    /// Entry point for raw BLE notification bytes.
    func receive(_ chunk: Data) -> Output {
        var output = Output()
        for frame in assembler.append([UInt8](chunk), at: clock()) {
            let result = handle(frame)
            output.events += result.events
            output.replies += result.replies
        }
        return output
    }

    func handle(_ frame: YCFrame) -> Output {
        let type = frame.dataType
        let p = frame.payload
        let now = clock()
        var out = Output()

        // Error replies ("unsupported command/key", length or CRC error). The SDK ignores
        // this check for app-control replies, whose one-byte status is legitimately 0x00.
        if frame.isErrorReply, type.group != YCGroup.appControl, type.group != YCGroup.deviceControl,
           type.group != YCGroup.realTime {
            if type.group == YCGroup.health { transfer = nil }
            let unsupported = p.first == 0xFB || p.first == 0xFC
            out.events.append(.completed(type, unsupported ? .unsupported : .failed))
            return out
        }

        switch type.group {
        case YCGroup.setting, YCGroup.appControl:
            out.events.append(.completed(type, p.first.map { $0 == 0 } ?? true ? .success : .failed))

        case YCGroup.get:
            handleGet(type, p, now: now, into: &out)
            out.events.append(.completed(type, .success))

        case YCGroup.deviceControl:
            handleDeviceEvent(type, p, now: now, into: &out)

        case YCGroup.health:
            handleHistory(type, p, into: &out)

        case YCGroup.realTime:
            handleRealTime(type, p, now: now, into: &out)

        default:
            break
        }
        return out
    }

    // MARK: - Group handlers

    private func handleGet(_ type: YCDataType, _ p: [UInt8], now: Date, into out: inout Output) {
        switch type {
        case .getDeviceInfo:
            if let info = YCParsers.deviceInfo(p) {
                out.events.append(.deviceInfo(info))
                var patch = LiveSnapshot()
                patch.batteryPercent = info.batteryPercent
                out.events.append(.live(patch, pushed: false))
            }
        case .getAllRealData:
            if let s = YCParsers.allRealData(p, now: now) { out.events.append(.live(s, pushed: false)) }
        case .getNowStep:
            if let s = YCParsers.nowStep(p, now: now) { out.events.append(.live(s, pushed: false)) }
        case .getRealTemp:
            if p.count >= 2, p[0] > 0, let t = Plausible.temperature(vendorDecimal(integer: p.u8(0), fraction: p.u8(1))) {
                var s = LiveSnapshot(updatedAt: now)
                s.temperature = t
                out.events.append(.live(s, pushed: false))
            }
        case .getRealBloodOxygen:
            if p.count >= 2, let spo2 = Plausible.bloodOxygen(p.u8(1)) {
                var s = LiveSnapshot(updatedAt: now)
                s.bloodOxygen = spo2
                out.events.append(.live(s, pushed: false))
            }
        default:
            break
        }
    }

    private func handleDeviceEvent(_ type: YCDataType, _ p: [UInt8], now: Date, into out: inout Output) {
        // The SDK acknowledges every device-control key it knows (0x00…0x19).
        if type.key <= 0x19 {
            out.replies.append(YCCommand.acknowledge(type))
        }
        switch type {
        case .deviceMeasurementResult where p.count >= 2:
            let outcome: MeasurementOutcome
            switch p[1] {
            case 1: outcome = .success
            case 2: outcome = .failed
            case 3: outcome = .cancelled
            default: outcome = .unknown
            }
            out.events.append(.measurementFinished(MeasurementKind(rawValue: p[0]), outcome))

        case .deviceInflatedBloodResult where p.count >= 3:
            if p[0] == 0, let sys = Plausible.systolic(p.u8(1)), let dia = Plausible.diastolic(p.u8(2)) {
                var batch = HealthBatch()
                batch.bloodPressure.append(BloodPressureSample(date: now, systolic: sys, diastolic: dia, heartRate: nil))
                out.events.append(.samples(batch))
                out.events.append(.measurementFinished(.bloodPressure, .success))
            } else {
                out.events.append(.measurementFinished(.bloodPressure, .failed))
            }

        case .deviceMeasureStatusAndResults where p.count >= 4:
            if let batch = measurementResult(kind: p[0], values: Array(p[2...]), now: now), !batch.isEmpty {
                out.events.append(.samples(batch))
            }

        default:
            break
        }
    }

    private func measurementResult(kind: UInt8, values v: [UInt8], now: Date) -> HealthBatch? {
        guard let kind = MeasurementKind(rawValue: kind), v.count >= 2 else { return nil }
        var batch = HealthBatch()
        switch kind {
        case .heartRate:
            if let bpm = Plausible.heartRate(v.u8(0)) { batch.heartRate.append(HeartRateSample(date: now, bpm: bpm)) }
        case .bloodPressure:
            if let sys = Plausible.systolic(v.u8(0)), let dia = Plausible.diastolic(v.u8(1)) {
                batch.bloodPressure.append(BloodPressureSample(date: now, systolic: sys, diastolic: dia, heartRate: nil))
            }
        case .bloodOxygen:
            if let spo2 = Plausible.bloodOxygen(v.u8(0)) { batch.bloodOxygen.append(BloodOxygenSample(date: now, percent: spo2)) }
        case .respiratoryRate:
            if let r = Plausible.respiration(v.u8(0)) { batch.respiration.append(RespirationSample(date: now, breathsPerMinute: r)) }
        case .temperature:
            if v.u8(0) > 0, let t = Plausible.temperature(vendorDecimal(integer: v.u8(0), fraction: v.u8(1))) {
                batch.temperature.append(TemperatureSample(date: now, celsius: t))
            }
        case .bloodGlucose:
            if v.u8(0) > 0 {
                batch.metabolic.append(MetabolicSample(date: now, glucose: vendorDecimal(integer: v.u8(0), fraction: v.u8(1))))
            }
        case .uricAcid:
            if v.u16le(0) > 0 { batch.metabolic.append(MetabolicSample(date: now, uricAcid: v.u16le(0))) }
        case .bloodKetone:
            if v.u8(0) > 0 || v.u8(1) > 0 {
                batch.metabolic.append(MetabolicSample(date: now, ketone: vendorDecimal(integer: v.u8(0), fraction: v.u8(1))))
            }
        }
        return batch
    }

    /// History transfers: header (request key) → data frames → end marker (0x80).
    /// The app verifies the CRC of the concatenated data and answers 0x0580 `[0x00]` (OK)
    /// or `[0x04]` (retry), exactly like the vendor SDK.
    private func handleHistory(_ type: YCDataType, _ p: [UInt8], into out: inout Output) {
        let key = type.key
        if Self.historyHeaderKeys.contains(key) {
            if p.count > 9 {
                transfer = Transfer(requestKey: key)
            } else {
                // Nothing stored for this type.
                transfer = nil
                out.events.append(.completed(type, .success))
            }
            return
        }

        if key == Self.historyEndKey {
            guard let current = transfer else { return }
            transfer = nil
            let requestType = YCDataType(group: YCGroup.health, key: current.requestKey)
            let expectedCRC = p.count >= 6 ? UInt16(p.u16le(4)) : nil
            if let expectedCRC, CRC16.ccittFalse(current.bytes) == expectedCRC {
                out.replies.append(YCCommand.historyTransferOK)
                let batch = YCParsers.history(requestKey: current.requestKey, bytes: current.bytes, timeZone: timeZone)
                if !batch.isEmpty { out.events.append(.samples(batch)) }
                out.events.append(.historyReceived(requestType, bytes: current.bytes.count, records: batch.totalCount))
                out.events.append(.completed(requestType, .success))
            } else {
                out.replies.append(YCCommand.historyTransferFailed)
                out.events.append(.completed(requestType, .failed))
            }
            return
        }

        // Replies to delete commands (0x40…0x52) need no handling; anything else is a data block.
        if (0x40...0x52).contains(key) { return }
        transfer?.bytes += p
    }

    private func handleRealTime(_ type: YCDataType, _ p: [UInt8], now: Date, into out: inout Output) {
        switch type {
        case .realSport:
            if let s = YCParsers.realSport(p, now: now) { out.events.append(.live(s, pushed: true)) }
        case .realHeart:
            if let bpm = p.first.flatMap({ Plausible.heartRate(Int($0)) }) {
                var s = LiveSnapshot(updatedAt: now)
                s.heartRate = bpm
                out.events.append(.live(s, pushed: true))
            }
        case .realBloodOxygen:
            if let spo2 = p.first.flatMap({ Plausible.bloodOxygen(Int($0)) }) {
                var s = LiveSnapshot(updatedAt: now)
                s.bloodOxygen = spo2
                out.events.append(.live(s, pushed: true))
            }
        case .realBlood:
            if let s = YCParsers.realBlood(p, now: now) { out.events.append(.live(s, pushed: true)) }
        case .realRespiratoryRate:
            if let r = p.first.flatMap({ Plausible.respiration(Int($0)) }) {
                var s = LiveSnapshot(updatedAt: now)
                s.respiratoryRate = r
                out.events.append(.live(s, pushed: true))
            }
        case .realComprehensive:
            if let s = YCParsers.realComprehensive(p, now: now) { out.events.append(.live(s, pushed: true)) }
        case .realBodyData:
            if let body = YCParsers.bodyMetrics(p, date: now) {
                var s = LiveSnapshot(updatedAt: now)
                if let hrv = body.hrvMilliseconds.flatMap(Plausible.hrv) {
                    s.hrv = hrv
                    s.hrvKind = body.hrvKind
                }
                s.stress = body.stress
                out.events.append(.live(s, pushed: true))
                var batch = HealthBatch()
                batch.bodyMetrics.append(body)
                out.events.append(.samples(batch))
            }
        case .realWearingStatus:
            if p.count >= 5 {
                var s = LiveSnapshot(updatedAt: now)
                s.isWorn = p[4] != 0
                out.events.append(.live(s, pushed: true))
            }
        default:
            break
        }
    }
}
