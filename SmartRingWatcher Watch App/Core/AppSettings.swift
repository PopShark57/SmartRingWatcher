import Foundation
import Observation

/// Tiles on the home screen, in their default order within each section.
enum HomeTile: String, CaseIterable, Codable, Identifiable, Sendable {
    case activity, sleep
    case heartRate, hrv, stress
    case bloodPressure, bloodOxygen, temperature, respiration, bloodChemistry

    enum Section: String, CaseIterable, Sendable {
        case today, heart, vitals

        var title: String {
            switch self {
            case .today: return String(localized: "Today")
            case .heart: return String(localized: "Heart")
            case .vitals: return String(localized: "Vitals")
            }
        }
    }

    var id: String { rawValue }

    var section: Section {
        switch self {
        case .activity, .sleep: return .today
        case .heartRate, .hrv, .stress: return .heart
        case .bloodPressure, .bloodOxygen, .temperature, .respiration, .bloodChemistry: return .vitals
        }
    }
}

enum TemperatureUnitPreference: String, CaseIterable, Identifiable, Sendable {
    /// Follow the watch's region.
    case automatic, celsius, fahrenheit
    var id: String { rawValue }
}

enum ChemistryUnitPreference: String, CaseIterable, Identifiable, Sendable {
    /// mg/dL in the US (and a few other regions), mmol/L elsewhere.
    case automatic, mmolPerLiter, mgPerDeciliter
    var id: String { rawValue }
}

/// User preferences, persisted in `UserDefaults`. Anything that must react to a change (the
/// sync engine, notifications, HealthKit) registers with `observe(_:)`, so a setting changed
/// from any screen reaches it.
@MainActor
@Observable
final class AppSettings {
    enum Key: String, CaseIterable, Sendable {
        case liveRefreshSeconds, historyRefreshMinutes, demoMode, temperatureUnit, liveStreaming
        case stepGoal, showBloodChemistry, chemistryUnit, tileOrder, hiddenTiles
        case healthKitExport, notifyLowBattery, notifyRingNotSeen, notifyMeasurement
    }

    /// How often live values are polled from the ring while the app is on screen.
    var liveRefreshSeconds: Int { didSet { save(liveRefreshSeconds, .liveRefreshSeconds) } }
    /// How often heart-rate and step history is pulled. Other types follow their own
    /// schedule (see `HistorySchedule`).
    var historyRefreshMinutes: Int { didSet { save(historyRefreshMinutes, .historyRefreshMinutes) } }
    /// Shows generated data from a separate store instead of talking to a ring.
    var demoMode: Bool { didSet { save(demoMode, .demoMode) } }
    var temperatureUnit: TemperatureUnitPreference { didSet { save(temperatureUnit.rawValue, .temperatureUnit) } }
    /// Ask the ring to push steps and heart rate every 2 s while the app is open.
    var liveStreaming: Bool { didSet { save(liveStreaming, .liveStreaming) } }
    var stepGoal: Int { didSet { save(stepGoal, .stepGoal) } }
    /// Blood glucose and other optical blood-chemistry estimates are hidden unless opted in.
    var showBloodChemistry: Bool { didSet { save(showBloodChemistry, .showBloodChemistry) } }
    var chemistryUnit: ChemistryUnitPreference { didSet { save(chemistryUnit.rawValue, .chemistryUnit) } }
    /// Home-screen order (tiles missing from the list keep their default position).
    var tileOrder: [HomeTile] { didSet { save(tileOrder.map(\.rawValue), .tileOrder) } }
    var hiddenTiles: Set<HomeTile> { didSet { save(hiddenTiles.map(\.rawValue).sorted(), .hiddenTiles) } }
    var healthKitExport: Bool { didSet { save(healthKitExport, .healthKitExport) } }
    var notifyLowBattery: Bool { didSet { save(notifyLowBattery, .notifyLowBattery) } }
    var notifyRingNotSeen: Bool { didSet { save(notifyRingNotSeen, .notifyRingNotSeen) } }
    var notifyMeasurement: Bool { didSet { save(notifyMeasurement, .notifyMeasurement) } }

    static let liveRefreshOptions = [5, 10, 30, 60]
    static let historyRefreshOptions = [5, 15, 30, 60]
    static let stepGoalOptions = [4_000, 5_000, 6_000, 7_500, 8_000, 10_000, 12_000, 15_000, 20_000]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [@MainActor (Key) -> Void] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func int(_ key: Key, _ fallback: Int, allowed: [Int]? = nil) -> Int {
            guard let value = defaults.object(forKey: key.rawValue) as? Int else { return fallback }
            if let allowed, !allowed.contains(value) { return fallback }
            return value
        }
        func bool(_ key: Key, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key.rawValue) as? Bool ?? fallback
        }
        liveRefreshSeconds = int(.liveRefreshSeconds, 10, allowed: Self.liveRefreshOptions)
        // The 1-minute option (and the old 5-minute default) re-downloaded everything far too
        // often; stored values that are no longer offered fall back to 15 minutes.
        historyRefreshMinutes = int(.historyRefreshMinutes, 15, allowed: Self.historyRefreshOptions)
        #if targetEnvironment(simulator)
        demoMode = bool(.demoMode, true)
        #else
        demoMode = bool(.demoMode, false)
        #endif
        if let raw = defaults.string(forKey: Key.temperatureUnit.rawValue),
           let unit = TemperatureUnitPreference(rawValue: raw) {
            temperatureUnit = unit
        } else if let legacy = defaults.object(forKey: "useFahrenheit") as? Bool {
            // Versions before the Automatic option stored an explicit °F switch.
            temperatureUnit = legacy ? .fahrenheit : .celsius
        } else {
            temperatureUnit = .automatic
        }
        liveStreaming = bool(.liveStreaming, false)
        stepGoal = int(.stepGoal, 10_000)
        showBloodChemistry = bool(.showBloodChemistry, false)
        chemistryUnit = defaults.string(forKey: Key.chemistryUnit.rawValue)
            .flatMap(ChemistryUnitPreference.init(rawValue:)) ?? .automatic
        tileOrder = (defaults.stringArray(forKey: Key.tileOrder.rawValue) ?? []).compactMap(HomeTile.init(rawValue:))
        hiddenTiles = Set((defaults.stringArray(forKey: Key.hiddenTiles.rawValue) ?? []).compactMap(HomeTile.init(rawValue:)))
        healthKitExport = bool(.healthKitExport, false)
        notifyLowBattery = bool(.notifyLowBattery, false)
        notifyRingNotSeen = bool(.notifyRingNotSeen, false)
        notifyMeasurement = bool(.notifyMeasurement, false)
    }

    /// Calls `handler` after any setting changes, with the setting that changed.
    func observe(_ handler: @escaping @MainActor (Key) -> Void) {
        observers.append(handler)
    }

    private func save(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
        for observer in observers { observer(key) }
    }

    // MARK: - Tiles

    /// Visible tiles of one section, in the user's order.
    func tiles(in section: HomeTile.Section) -> [HomeTile] {
        orderedTiles.filter { $0.section == section && !hiddenTiles.contains($0) }
    }

    /// Every tile, user order first and unknown tiles in their default place.
    var orderedTiles: [HomeTile] {
        var result = tileOrder.filter { HomeTile.allCases.contains($0) }
        for tile in HomeTile.allCases where !result.contains(tile) {
            // Insert after the last tile of the same section so new tiles stay grouped.
            if let index = result.lastIndex(where: { $0.section == tile.section }) {
                result.insert(tile, at: index + 1)
            } else {
                result.append(tile)
            }
        }
        return result
    }

    /// Moves a tile one place up or down within its section.
    func move(_ tile: HomeTile, by offset: Int) {
        var order = orderedTiles
        let peers = order.filter { $0.section == tile.section }
        guard let peerIndex = peers.firstIndex(of: tile) else { return }
        let targetPeer = peerIndex + offset
        guard peers.indices.contains(targetPeer),
              let from = order.firstIndex(of: tile),
              let to = order.firstIndex(of: peers[targetPeer]) else { return }
        order.swapAt(from, to)
        tileOrder = order
    }

    func resetTiles() {
        tileOrder = []
        hiddenTiles = []
    }

    // MARK: - Formatting

    private var locale: Locale { .autoupdatingCurrent }

    /// Whether temperatures are shown in °F.
    var usesFahrenheit: Bool {
        switch temperatureUnit {
        case .automatic:
            return locale.measurementSystem == .us
        case .celsius: return false
        case .fahrenheit: return true
        }
    }

    /// Temperature in the display unit, for charts.
    func temperatureValue(_ celsius: Double) -> Double {
        usesFahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    /// "36.6 °C" / "97.9 °F", with the locale's decimal separator.
    func formatTemperature(_ celsius: Double) -> String {
        let unit: UnitTemperature = usesFahrenheit ? .fahrenheit : .celsius
        return Measurement(value: celsius, unit: UnitTemperature.celsius)
            .converted(to: unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    var temperatureUnitSymbol: String { usesFahrenheit ? "°F" : "°C" }

    var usesMilligramsPerDeciliter: Bool {
        switch chemistryUnit {
        case .automatic:
            // The US reports glucose and lipids in mg/dL; most other regions use mmol/L.
            return ["US", "PR", "GU", "AS", "VI", "MP"].contains(locale.region?.identifier ?? "")
        case .mmolPerLiter: return false
        case .mgPerDeciliter: return true
        }
    }
}
