import Foundation

/// When each history type is due for another download.
///
/// The app never sends `Health_Delete*` (so Smarthealth on the phone still gets everything),
/// which means the ring sends its whole stored history for a type on every request. That is
/// the biggest radio and battery cost for both the watch and the ring, so each type is pulled
/// only as often as it is useful.
struct HistorySchedule: Sendable {
    /// The user's "History sync" setting; heart rate, steps and the combined record use it.
    var baseInterval: TimeInterval
    /// Blood chemistry is only pulled when the user opted in to seeing it.
    var includesBloodChemistry = false
    /// Sleep is pulled once in the morning, from this hour.
    var morningHour = 6

    /// Vitals that are measured every hour or so at most.
    static let vitalsInterval: TimeInterval = 45 * 60
    /// Blood chemistry changes only after a measurement (which fetches it right away).
    static let chemistryInterval: TimeInterval = 12 * 3600
    /// While last night's sleep hasn't arrived, check again this often in the morning.
    static let sleepRetryInterval: TimeInterval = 3600
    /// Timer ticks aren't exact; anything this close to due counts as due.
    static let slack: TimeInterval = 30

    /// Types in the order they are requested (most important first).
    static let allTypes: [YCDataType] = YCCommand.historyTypes

    func isDue(_ type: YCDataType, lastSync: Date?, newestSleepEnd: Date?, now: Date,
               calendar: Calendar = .current) -> Bool {
        if type == .historyComprehensive && !includesBloodChemistry { return false }
        guard let lastSync else { return true }
        let elapsed = now.timeIntervalSince(lastSync) + Self.slack
        switch type {
        case .historyHeart, .historySport, .historyAll:
            return elapsed >= baseInterval
        case .historyBlood, .historyBloodOxygen, .historyTemperature, .historyBody:
            return elapsed >= max(Self.vitalsInterval, baseInterval)
        case .historyComprehensive:
            return elapsed >= Self.chemistryInterval
        case .historySleep:
            guard let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: now),
                  now >= morning else { return false }
            // The first sync of the morning…
            if lastSync < morning { return true }
            // …then hourly until last night shows up (late risers, ring not synced yet).
            let lastNightMissing = newestSleepEnd.map { now.timeIntervalSince($0) > 12 * 3600 } ?? true
            return lastNightMissing && elapsed >= Self.sleepRetryInterval
        default:
            return elapsed >= baseInterval
        }
    }
}
