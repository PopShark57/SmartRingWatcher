import HealthKit
import SwiftUI
import WatchKit

/// Long-lived objects shared by the UI, the background-refresh handler and the services.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let log = DiagnosticsLog()
    let settings = AppSettings()
    let realStore: HealthDataStore
    let transport: RingBluetoothManager
    let engine: RingSyncEngine
    let widgets = WidgetBridge()
    let health: HealthKitExporter
    let notifier: RingNotifier
    private(set) var isActive = false

    private init() {
        realStore = HealthDataStore(log: log)
        transport = RingBluetoothManager(log: log)
        engine = RingSyncEngine(transport: transport, realStore: realStore,
                                demoStore: HealthDataStore(fileName: nil, log: log),
                                settings: settings, log: log)
        health = HealthKitExporter(log: log)
        notifier = RingNotifier(settings: settings)
        wireUp()
    }

    private func wireUp() {
        realStore.onNewSamples = { [weak self] batch in
            guard let self, self.settings.healthKitExport else { return }
            let device = self.healthDevice
            Task { await self.health.export(batch, device: device) }
        }
        for store in [realStore, engine.demoStore] {
            store.onChange = { [weak self] in
                guard let self, store === self.engine.store else { return }
                self.widgets.scheduleUpdate { [weak self] in self?.summary ?? .placeholder }
                if store === self.realStore {
                    self.notifier.batteryChanged(percent: store.batteryPercent, charging: store.isCharging)
                }
            }
        }
        engine.onRingContact = { [weak self] in self?.notifier.ringSeen() }
        engine.onSyncFinished = { [weak self] in
            guard let self else { return }
            self.widgets.update(self.summary, force: false)
        }
        engine.onMeasurementFinished = { [weak self] kind, outcome in
            guard let self else { return }
            self.notifier.measurementFinished(kind, outcome, appIsActive: self.isActive)
        }
        settings.observe { [weak self] key in self?.settingChanged(key) }
    }

    private func settingChanged(_ key: AppSettings.Key) {
        switch key {
        case .healthKitExport where settings.healthKitExport:
            Task {
                guard await health.requestAuthorization() else {
                    settings.healthKitExport = false
                    return
                }
                await health.exportAll(from: realStore, device: healthDevice)
            }
        case .notifyLowBattery, .notifyRingNotSeen, .notifyMeasurement:
            notifier.settingsChanged()
            if settings.notifyLowBattery || settings.notifyRingNotSeen || settings.notifyMeasurement {
                Task { _ = await notifier.requestAuthorization() }
            }
        case .demoMode, .stepGoal:
            widgets.update(summary, force: true)
        default:
            break
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        isActive = phase == .active
        engine.setForeground(isActive)
        if !isActive {
            realStore.save(synchronously: true)
            widgets.update(summary, force: true)
        }
    }

    /// What the complication shows, from the store on screen.
    var summary: RingSummary {
        let store = engine.store
        return RingSummary(
            updatedAt: Date(), heartRate: store.latestHeartRate?.value, heartRateDate: store.latestHeartRate?.date,
            steps: store.today.steps, stepGoal: settings.stepGoal, stepsDay: store.todayStart,
            batteryPercent: store.batteryPercent, isCharging: store.isCharging,
            ringName: settings.demoMode ? String(localized: "Demo ring") : (transport.connectedName ?? transport.savedRingName),
            isDemo: settings.demoMode)
    }

    private var healthDevice: HKDevice {
        HealthKitExporter.device(name: transport.connectedName ?? transport.savedRingName,
                                 deviceID: transport.savedRingID, info: realStore.deviceInfo, gattInfo: transport.gattInfo)
    }
}

@main
struct SmartRingWatcherApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView(model: AppModel.shared)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    AppModel.shared.scenePhaseChanged(phase)
                }
        }
    }
}

/// Injects the model objects. Reading `engine.store` here (which depends on demo mode) means
/// toggling demo mode swaps the store every view sees.
struct AppRootView: View {
    let model: AppModel

    var body: some View {
        RootView()
            .environment(model.settings)
            .environment(model.engine.store)
            .environment(model.transport)
            .environment(model.engine)
            .environment(model.log)
    }
}

/// Schedules and handles Background App Refresh so the data stays fresh even when the
/// app is not on screen. watchOS decides the timing; with the complication on the active
/// watch face it allows up to about four refreshes an hour.
final class AppDelegate: NSObject, WKApplicationDelegate {
    static let refreshIdentifier = "com.smartringwatcher.refresh"

    func applicationDidFinishLaunching() {
        Self.scheduleBackgroundRefresh()
    }

    func applicationDidEnterBackground() {
        Self.scheduleBackgroundRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                let model = AppModel.shared
                model.engine.performBackgroundSync {
                    model.widgets.update(model.summary, force: true)
                    Self.scheduleBackgroundRefresh()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            case let snapshot as WKSnapshotRefreshBackgroundTask:
                snapshot.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    static func scheduleBackgroundRefresh(in interval: TimeInterval = 15 * 60) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: refreshIdentifier as NSString
        ) { error in
            if let error {
                Log.sync.error("Background refresh scheduling failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
