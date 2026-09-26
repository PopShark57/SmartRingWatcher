import Foundation
import WidgetKit

/// Keeps the complication's summary file current and asks WidgetKit to reload it.
///
/// Reloads are budgeted by the system, so they are requested only when something shown
/// changed, at most every few minutes, plus when the app leaves the screen and after
/// background refresh.
@MainActor
final class WidgetBridge {
    private var lastSummary: RingSummary?
    private var lastReload = Date.distantPast
    private var pending: (any Cancellable)?
    private let scheduler: any Scheduling
    private let minimumReloadInterval: TimeInterval = 5 * 60

    init(scheduler: any Scheduling = SystemScheduler.shared) {
        self.scheduler = scheduler
    }

    /// Coalesces bursts of store changes into one update a couple of seconds later.
    func scheduleUpdate(_ makeSummary: @escaping @MainActor () -> RingSummary) {
        guard pending == nil else { return }
        pending = scheduler.after(2) { [weak self] in
            self?.pending = nil
            self?.update(makeSummary(), force: false)
        }
    }

    func update(_ summary: RingSummary, force: Bool) {
        let changed = lastSummary.map { !Self.looksTheSame($0, summary) } ?? true
        guard changed || force else { return }
        guard SharedContainer.write(summary) else { return }
        lastSummary = summary
        let now = scheduler.now
        if force || now.timeIntervalSince(lastReload) >= minimumReloadInterval {
            lastReload = now
            WidgetCenter.shared.reloadTimelines(ofKind: SharedContainer.summaryWidgetKind)
        }
    }

    /// Small step changes don't justify spending the reload budget.
    private static func looksTheSame(_ a: RingSummary, _ b: RingSummary) -> Bool {
        a.heartRate == b.heartRate && a.heartRateDate == b.heartRateDate
            && abs(a.steps - b.steps) < 100 && a.stepGoal == b.stepGoal && a.stepsDay == b.stepsDay
            && a.batteryPercent == b.batteryPercent && a.isCharging == b.isCharging
            && a.ringName == b.ringName && a.isDemo == b.isDemo
    }
}
