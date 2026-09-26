import Foundation
import UserNotifications

/// Opt-in local notifications (Settings → Notifications):
/// - the ring's battery is low (15 % or less, once per charge);
/// - the ring hasn't been seen for 24 hours;
/// - a measurement finished while the app was in the background.
@MainActor
final class RingNotifier {
    private let settings: AppSettings
    private let defaults: UserDefaults
    private let scheduler: any Scheduling
    private var lastNotSeenReschedule = Date.distantPast

    private enum ID {
        static let lowBattery = "ring.lowBattery"
        static let notSeen = "ring.notSeen"
        static let measurement = "ring.measurement"
    }

    private static let lowBatteryNotifiedKey = "LowBatteryNotified"
    static let lowBatteryThreshold = 15

    init(settings: AppSettings, defaults: UserDefaults = .standard, scheduler: any Scheduling = SystemScheduler.shared) {
        self.settings = settings
        self.defaults = defaults
        self.scheduler = scheduler
    }

    private var center: UNUserNotificationCenter { .current() }

    /// Asks for permission when a notification setting is turned on.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func settingsChanged() {
        if !settings.notifyRingNotSeen {
            center.removePendingNotificationRequests(withIdentifiers: [ID.notSeen])
        }
    }

    func batteryChanged(percent: Int?, charging: Bool) {
        guard let percent else { return }
        let notified = defaults.bool(forKey: Self.lowBatteryNotifiedKey)
        if charging || percent > Self.lowBatteryThreshold + 5 {
            // Charged (or charging): allow the next low-battery alert.
            if notified { defaults.set(false, forKey: Self.lowBatteryNotifiedKey) }
            return
        }
        guard settings.notifyLowBattery, !notified, percent <= Self.lowBatteryThreshold else { return }
        defaults.set(true, forKey: Self.lowBatteryNotifiedKey)
        post(ID.lowBattery, title: String(localized: "Ring battery low"),
             body: String(localized: "Your ring is at \(percent)%. Charge it to keep recording."))
    }

    /// The ring was reachable: push the "not seen" reminder 24 hours out.
    func ringSeen() {
        guard settings.notifyRingNotSeen else { return }
        let now = scheduler.now
        // Frames arrive every few seconds; rescheduling every 10 minutes is plenty.
        guard now.timeIntervalSince(lastNotSeenReschedule) > 600 else { return }
        lastNotSeenReschedule = now
        post(ID.notSeen, title: String(localized: "Ring not seen for a day"),
             body: String(localized: "Is it charged and nearby? Open SmartRing to reconnect."),
             after: 24 * 3600)
    }

    func measurementFinished(_ kind: MeasurementKind, _ outcome: MeasurementOutcome, appIsActive: Bool) {
        guard settings.notifyMeasurement, !appIsActive else { return }
        let body = outcome == .success
            ? String(localized: "\(kind.displayName) measurement finished.")
            : String(localized: "\(kind.displayName) measurement didn't finish (\(outcome.rawValue)).")
        post(ID.measurement, title: String(localized: "Measurement"), body: body)
    }

    private func post(_ id: String, title: String, body: String, after seconds: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = seconds.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request) { _ in }
    }
}
