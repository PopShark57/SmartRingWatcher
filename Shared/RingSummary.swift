import Foundation

/// The little bit of state the complication shows. The app writes it to the shared App Group
/// container after syncing; the widget extension reads it.
struct RingSummary: Codable, Equatable, Sendable {
    var updatedAt: Date
    var heartRate: Int?
    var heartRateDate: Date?
    var steps: Int
    var stepGoal: Int
    /// The day `steps` belongs to.
    var stepsDay: Date
    var batteryPercent: Int?
    var isCharging: Bool
    var ringName: String?
    var isDemo: Bool

    /// Today's steps as of `date`: zero once the day has rolled over without a new sync.
    func steps(on date: Date, calendar: Calendar = .current) -> Int {
        calendar.isDate(stepsDay, inSameDayAs: date) ? steps : 0
    }

    func stepProgress(on date: Date) -> Double {
        min(1, Double(steps(on: date)) / Double(max(stepGoal, 1)))
    }

    static let placeholder = RingSummary(
        updatedAt: .now, heartRate: 68, heartRateDate: .now.addingTimeInterval(-300), steps: 6_240,
        stepGoal: 10_000, stepsDay: .now, batteryPercent: 76, isCharging: false, ringName: "Ring", isDemo: false)
}

/// The App Group container shared by the app and the widget extension.
enum SharedContainer {
    /// Kind string of the summary widget, for `WidgetCenter.reloadTimelines(ofKind:)`.
    static let summaryWidgetKind = "RingSummary"

    /// From Info.plist (`RingAppGroup`), which gets it from the `RING_APP_GROUP` build setting,
    /// so changing the bundle identifier prefix in one place updates the group too.
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "RingAppGroup") as? String
    }

    static var summaryURL: URL? {
        guard let group = appGroup,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return nil
        }
        return container.appendingPathComponent("summary.json")
    }

    static func readSummary() -> RingSummary? {
        guard let url = summaryURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RingSummary.self, from: data)
    }

    /// Returns false when there is no App Group (for example a signing team without it).
    @discardableResult
    static func write(_ summary: RingSummary) -> Bool {
        guard let url = summaryURL, let data = try? JSONEncoder().encode(summary) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
