import Foundation

/// Builders for every frame the app sends to the ring.
///
/// Deliberately read-mostly: apart from setting the clock and the user-initiated
/// measurement commands, nothing here changes the ring's configuration, so it keeps
/// working with Smarthealth on the phone. Stored history is never deleted.
enum YCCommand {
    static func syncClock(_ date: Date = Date(), timeZone: TimeZone = .current) -> YCFrame {
        YCFrame(.settingTime, YCTime.clockPayload(for: date, timeZone: timeZone))
    }

    static let deviceInfo = YCFrame(.getDeviceInfo, [0x47, 0x43])
    static let allRealData = YCFrame(.getAllRealData)
    static let nowStep = YCFrame(.getNowStep)
    static let realTemperature = YCFrame(.getRealTemp)
    static let realBloodOxygen = YCFrame(.getRealBloodOxygen, [0x49, 0x53])

    static func history(_ type: YCDataType) -> YCFrame {
        YCFrame(type)
    }

    /// Every history type the app syncs, most important first.
    static let historyTypes: [YCDataType] = [
        .historyHeart, .historySport, .historySleep, .historyBlood, .historyBloodOxygen,
        .historyAll, .historyBody, .historyTemperature, .historyComprehensive,
    ]

    static func startMeasurement(_ kind: MeasurementKind) -> YCFrame {
        YCFrame(.appStartMeasurement, [1, kind.rawValue])
    }

    static func stopMeasurement(_ kind: MeasurementKind) -> YCFrame {
        YCFrame(.appStartMeasurement, [0, kind.rawValue])
    }

    /// Live upload switch (SDK `appRealDataFromDevice`): `[enable, kind, intervalSeconds]`.
    /// Kind 0 streams steps (0x0600) and kind 1 streams heart rate (0x0601).
    static func liveStream(enabled: Bool, kind: UInt8, intervalSeconds: UInt8 = 2) -> YCFrame {
        YCFrame(.appRealDataSwitch, [enabled ? 1 : 0, kind, intervalSeconds])
    }

    static let historyTransferOK = YCFrame(.historyBlock, [0x00])
    static let historyTransferFailed = YCFrame(.historyBlock, [0x04])

    /// Every ring-initiated event (group 0x04) must be acknowledged with `[0x00]`.
    static func acknowledge(_ event: YCDataType) -> YCFrame {
        YCFrame(event, [0x00])
    }
}
