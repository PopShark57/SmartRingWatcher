import SwiftUI
import WatchKit

/// Long-lived objects shared by the UI and the background-refresh handler.
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    let store = HealthDataStore()
    let transport = RingBluetoothManager()
    let engine: RingSyncEngine

    private init() {
        engine = RingSyncEngine(transport: transport, store: store, settings: settings)
    }
}

@main
struct SmartRingWatcherApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model.settings)
                .environmentObject(model.store)
                .environmentObject(model.transport)
                .environmentObject(model.engine)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.engine.setForeground(phase == .active)
                    if phase != .active { model.store.save() }
                }
        }
    }
}

/// Schedules and handles Background App Refresh so the data stays fresh even when the
/// app is not on screen (watchOS decides the exact timing, at most ~4 times per hour).
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
                AppModel.shared.engine.performBackgroundSync {
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
            if let error { print("Background refresh scheduling failed: \(error)") }
        }
    }
}
