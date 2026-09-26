import Foundation

/// A YC protocol "data type": the command group in the high byte and the key in the low byte.
///
/// Values come from the vendor SDK (`Constants.DATATYPE` in `ycbtsdk-release.aar`), which
/// is the SDK the Smarthealth app is built on. See `docs/PROTOCOL.md` for the full table.
struct YCDataType: RawRepresentable, Hashable, Codable, CustomStringConvertible, Sendable {
    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    init(group: UInt8, key: UInt8) {
        rawValue = UInt16(group) << 8 | UInt16(key)
    }

    var group: UInt8 { UInt8(rawValue >> 8) }
    var key: UInt8 { UInt8(rawValue & 0xFF) }

    var description: String { String(format: "0x%04X", rawValue) }
}

/// Command groups (high byte of a data type).
enum YCGroup {
    static let setting: UInt8 = 0x01
    static let get: UInt8 = 0x02
    static let appControl: UInt8 = 0x03
    static let deviceControl: UInt8 = 0x04
    static let health: UInt8 = 0x05
    static let realTime: UInt8 = 0x06
}

extension YCDataType {
    // MARK: Group 0x01 – settings

    /// Set the ring clock. Payload: 8-byte local wall-clock time (see `YCTime.clockPayload`).
    static let settingTime = YCDataType(rawValue: 0x0100)

    // MARK: Group 0x02 – queries

    /// Device info (firmware, battery). Payload: `[0x47, 0x43]` ("GC").
    static let getDeviceInfo = YCDataType(rawValue: 0x0200)
    /// Today's steps / calories / distance.
    static let getNowStep = YCDataType(rawValue: 0x020C)
    /// Current body temperature.
    static let getRealTemp = YCDataType(rawValue: 0x020E)
    /// Current blood oxygen. Payload: `[0x49, 0x53]` ("IS").
    static let getRealBloodOxygen = YCDataType(rawValue: 0x0211)
    /// Snapshot of every live value the ring currently holds.
    static let getAllRealData = YCDataType(rawValue: 0x0220)

    // MARK: Group 0x03 – app control

    /// Stream live values. Payload: `[enable, kind, intervalSeconds]`.
    static let appRealDataSwitch = YCDataType(rawValue: 0x0309)
    /// Start/stop a one-off measurement. Payload: `[start, MeasurementKind]`.
    static let appStartMeasurement = YCDataType(rawValue: 0x032F)

    // MARK: Group 0x04 – events raised by the ring (the app must acknowledge them)

    static let deviceMeasurementResult = YCDataType(rawValue: 0x040E)
    static let deviceInflatedBloodResult = YCDataType(rawValue: 0x0410)
    static let deviceMeasureStatusAndResults = YCDataType(rawValue: 0x0413)

    // MARK: Group 0x05 – stored history (multi-frame transfers)

    static let historySport = YCDataType(rawValue: 0x0502)
    static let historySleep = YCDataType(rawValue: 0x0504)
    static let historyHeart = YCDataType(rawValue: 0x0506)
    static let historyBlood = YCDataType(rawValue: 0x0508)
    static let historyAll = YCDataType(rawValue: 0x0509)
    static let historyBloodOxygen = YCDataType(rawValue: 0x051A)
    static let historyTemperature = YCDataType(rawValue: 0x051E)
    static let historyComprehensive = YCDataType(rawValue: 0x052F)
    static let historyBody = YCDataType(rawValue: 0x0533)
    /// End-of-transfer marker from the ring, and the app's acknowledgement of it.
    static let historyBlock = YCDataType(rawValue: 0x0580)

    // MARK: Group 0x06 – real-time uploads pushed by the ring

    static let realSport = YCDataType(rawValue: 0x0600)
    static let realHeart = YCDataType(rawValue: 0x0601)
    static let realBloodOxygen = YCDataType(rawValue: 0x0602)
    static let realBlood = YCDataType(rawValue: 0x0603)
    static let realRespiratoryRate = YCDataType(rawValue: 0x0607)
    static let realComprehensive = YCDataType(rawValue: 0x060A)
    static let realBodyData = YCDataType(rawValue: 0x0610)
    static let realWearingStatus = YCDataType(rawValue: 0x0613)
}

/// Measurement kinds shared by `appStartMeasurement` (0x032F) and the ring's
/// measurement status event (0x0413).
enum MeasurementKind: UInt8, Codable, CaseIterable, Identifiable, Sendable {
    case heartRate = 0
    case bloodPressure = 1
    case bloodOxygen = 2
    case respiratoryRate = 3
    case temperature = 4
    case bloodGlucose = 5
    case uricAcid = 6
    case bloodKetone = 7

    var id: UInt8 { rawValue }

    var displayName: String {
        switch self {
        case .heartRate: return String(localized: "Heart rate")
        case .bloodPressure: return String(localized: "Blood pressure")
        case .bloodOxygen: return String(localized: "Blood oxygen")
        case .respiratoryRate: return String(localized: "Respiration")
        case .temperature: return String(localized: "Temperature")
        case .bloodGlucose: return String(localized: "Blood glucose")
        case .uricAcid: return String(localized: "Uric acid")
        case .bloodKetone: return String(localized: "Blood ketone")
        }
    }
}
