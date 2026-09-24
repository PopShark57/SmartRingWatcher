import SwiftUI

/// Home screen: connection status and one live-updating tile per metric, each opening a
/// detail page. Values update automatically as the sync engine receives data.
struct RootView: View {
    @EnvironmentObject private var store: HealthDataStore
    @EnvironmentObject private var engine: RingSyncEngine
    @EnvironmentObject private var transport: RingBluetoothManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { DeviceView() } label: { ConnectionHeader() }
                }

                Section {
                    NavigationLink { HeartRateView() } label: {
                        MetricTile(style: .heartRate,
                                   value: store.latestHeartRate.map { "\($0.value)" } ?? "--",
                                   unit: "BPM",
                                   date: store.latestHeartRate?.date,
                                   detail: store.restingHeartRate.map { "Resting \($0) BPM" })
                    }
                    NavigationLink { HRVView() } label: {
                        MetricTile(style: .hrv,
                                   value: store.latestHRV?.value.noDecimals ?? "--",
                                   unit: "ms",
                                   date: store.latestHRV?.date)
                    }
                    NavigationLink { SleepView() } label: {
                        MetricTile(style: .sleep,
                                   value: store.lastNightSleep?.asleepSeconds.hoursMinutes ?? "--",
                                   detail: store.lastNightSleep.map { "Score \($0.estimatedScore) · Deep \($0.deepSeconds.hoursMinutes)" })
                    }
                    NavigationLink { ActivityView() } label: {
                        MetricTile(style: .activity,
                                   value: store.stepsToday.formatted(),
                                   unit: "steps",
                                   detail: "\(store.kilocaloriesToday) kcal · \(Measurement(value: Double(store.distanceTodayMeters), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))")
                    }
                }

                Section {
                    NavigationLink { BloodPressureView() } label: {
                        MetricTile(style: .bloodPressure,
                                   value: store.latestBloodPressure.map { "\($0.value.systolic)/\($0.value.diastolic)" } ?? "--",
                                   unit: "mmHg",
                                   date: store.latestBloodPressure?.date)
                    }
                    NavigationLink { BloodOxygenView() } label: {
                        MetricTile(style: .bloodOxygen,
                                   value: store.latestBloodOxygen.map { "\($0.value)" } ?? "--",
                                   unit: "%",
                                   date: store.latestBloodOxygen?.date)
                    }
                    NavigationLink { TemperatureView() } label: {
                        MetricTile(style: .temperature,
                                   value: store.latestTemperature.map { settings.formatTemperature($0.value) } ?? "--",
                                   date: store.latestTemperature?.date)
                    }
                    NavigationLink { StressView() } label: {
                        MetricTile(style: .stress,
                                   value: store.latestStress?.value.oneDecimal ?? "--",
                                   unit: "/ 10",
                                   date: store.latestStress?.date,
                                   detail: store.latestStress.map { StressView.level(for: $0.value) })
                    }
                    NavigationLink { RespirationView() } label: {
                        MetricTile(style: .respiration,
                                   value: store.latestRespiration.map { "\($0.value)" } ?? "--",
                                   unit: "br/min",
                                   date: store.latestRespiration?.date)
                    }
                    if !store.metabolic.isEmpty {
                        NavigationLink { MetabolicView() } label: {
                            MetricTile(style: .metabolic,
                                       value: store.latestMetabolic?.glucose.map { $0.oneDecimal } ?? "--",
                                       unit: "mmol/L",
                                       date: store.latestMetabolic?.date,
                                       detail: "Glucose (estimate)")
                        }
                    }
                }

                Section {
                    Button {
                        engine.refreshNow()
                    } label: {
                        Label(engine.isSyncingHistory ? "Syncing…" : "Sync now", systemImage: "arrow.clockwise")
                    }
                    .disabled(engine.isSyncingHistory)
                } footer: {
                    if let last = engine.lastHistorySync {
                        Text("History synced \(last, style: .relative) ago. Live values refresh every \(settings.liveRefreshSeconds) s.")
                    } else {
                        Text("Live values refresh every \(settings.liveRefreshSeconds) s while the app is open.")
                    }
                }
            }
            .navigationTitle("SmartRing")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }
}

/// Connection state, ring name and battery at the top of the home screen.
struct ConnectionHeader: View {
    @EnvironmentObject private var store: HealthDataStore
    @EnvironmentObject private var engine: RingSyncEngine
    @EnvironmentObject private var transport: RingBluetoothManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: isBusy)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let battery = store.live.batteryPercent ?? store.deviceInfo?.batteryPercent {
                Label("\(battery)%", systemImage: batterySymbol(battery))
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(battery <= 20 ? Color.red : Color.secondary)
            }
        }
    }

    private var title: String {
        if settings.demoMode { return "Demo ring" }
        return transport.connectedName ?? transport.savedRingName ?? "No ring"
    }

    private var subtitle: String {
        if settings.demoMode { return "Showing sample data" }
        if engine.isSyncingHistory { return "Syncing history…" }
        if transport.savedRingID == nil && !transport.state.isConnected { return "Tap to pair a ring" }
        return transport.state.label
    }

    private var isBusy: Bool {
        if engine.isSyncingHistory { return true }
        switch transport.state {
        case .scanning, .connecting, .discovering, .reconnecting: return true
        default: return false
        }
    }

    private var statusSymbol: String {
        if settings.demoMode { return "sparkles" }
        return transport.state.isConnected ? "dot.radiowaves.left.and.right" : "circle.dashed"
    }

    private var statusColor: Color {
        if settings.demoMode { return .yellow }
        return transport.state.isConnected ? .green : .secondary
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
