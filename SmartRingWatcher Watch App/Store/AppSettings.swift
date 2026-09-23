import Foundation

/// User preferences, persisted in `UserDefaults`.
final class AppSettings: ObservableObject {
    /// How often live values are polled from the ring while the app is on screen.
    @Published var liveRefreshSeconds: Int { didSet { save(liveRefreshSeconds, Keys.live) } }
    /// How often stored history (sleep, steps, HR, …) is pulled from the ring.
    @Published var historyRefreshMinutes: Int { didSet { save(historyRefreshMinutes, Keys.history) } }
    /// Shows generated data instead of talking to a ring (the watch simulator has no Bluetooth).
    @Published var demoMode: Bool { didSet { save(demoMode, Keys.demo) } }
    @Published var useFahrenheit: Bool { didSet { save(useFahrenheit, Keys.fahrenheit) } }
    /// Ask the ring to push steps and heart rate every 2 s while the app is open.
    @Published var liveStreaming: Bool { didSet { save(liveStreaming, Keys.stream) } }

    static let liveRefreshOptions = [5, 10, 30, 60]
    static let historyRefreshOptions = [1, 5, 15, 30]

    private enum Keys {
        static let live = "liveRefreshSeconds"
        static let history = "historyRefreshMinutes"
        static let demo = "demoMode"
        static let fahrenheit = "useFahrenheit"
        static let stream = "liveStreaming"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        liveRefreshSeconds = defaults.object(forKey: Keys.live) as? Int ?? 10
        historyRefreshMinutes = defaults.object(forKey: Keys.history) as? Int ?? 5
        #if targetEnvironment(simulator)
        demoMode = defaults.object(forKey: Keys.demo) as? Bool ?? true
        #else
        demoMode = defaults.object(forKey: Keys.demo) as? Bool ?? false
        #endif
        let usesMetric = Locale.current.measurementSystem != .us
        useFahrenheit = defaults.object(forKey: Keys.fahrenheit) as? Bool ?? !usesMetric
        liveStreaming = defaults.object(forKey: Keys.stream) as? Bool ?? false
    }

    private let defaults: UserDefaults

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    func formatTemperature(_ celsius: Double) -> String {
        if useFahrenheit {
            return String(format: "%.1f°F", celsius * 9 / 5 + 32)
        }
        return String(format: "%.1f°C", celsius)
    }
}
