import SwiftUI

/// Home screen: connection status and one live-updating tile per metric, grouped into
/// Today / Heart / Vitals, each opening a detail page. Tiles appear once they have data.
struct RootView: View {
    @Environment(HealthDataStore.self) private var store
    @Environment(RingSyncEngine.self) private var engine
    @Environment(RingBluetoothManager.self) private var transport
    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { DeviceView() } label: { ConnectionHeader() }
                }

                if showsOnboarding {
                    Section { OnboardingCard() }
                }

                ForEach(HomeTile.Section.allCases, id: \.self) { section in
                    let tiles = settings.tiles(in: section).filter(hasData)
                    if !tiles.isEmpty {
                        Section(section.title) {
                            ForEach(tiles) { tile in
                                HomeTileRow(tile: tile)
                            }
                        }
                    }
                }

                if !showsOnboarding && !HomeTile.allCases.contains(where: hasData) {
                    Section {
                        Text(transport.state.isConnected
                             ? "Waiting for the ring's first data…"
                             : "Values appear here once the ring has synced.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.demoMode || transport.hasProtocolChannel {
                    Section {
                        Button {
                            engine.refreshNow()
                        } label: {
                            Label(engine.isSyncingHistory ? "Syncing…" : "Sync now", systemImage: "arrow.clockwise")
                        }
                        .disabled(engine.isSyncingHistory)
                    } footer: {
                        SyncFooter()
                    }
                }
            }
            .refreshable {
                await engine.refresh()
            }
            .navigationTitle("SmartRing")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: {
                        Image(systemName: "gearshape")
                            .accessibilityLabel("Settings")
                    }
                }
            }
        }
    }

    /// First run: no ring, no data, not in demo mode.
    private var showsOnboarding: Bool {
        !settings.demoMode && transport.savedRingID == nil && store.lastChange == nil
    }

    /// Tiles that never had data stay hidden, rather than showing a list of "--".
    private func hasData(_ tile: HomeTile) -> Bool {
        switch tile {
        case .activity: return store.today.steps > 0 || !store.activity.isEmpty
        case .sleep: return store.lastNightSleep != nil
        case .heartRate: return store.latestHeartRate != nil
        case .hrv: return store.latestHRV != nil
        case .stress: return store.latestStress != nil
        case .bloodPressure: return store.latestBloodPressure != nil
        case .bloodOxygen: return store.latestBloodOxygen != nil
        case .temperature: return store.latestTemperature != nil
        case .respiration: return store.latestRespiration != nil
        case .bloodChemistry: return settings.showBloodChemistry && store.latestMetabolic != nil
        }
    }
}

extension HomeTile {
    var style: MetricStyle {
        switch self {
        case .activity: return .activity
        case .sleep: return .sleep
        case .heartRate: return .heartRate
        case .hrv: return .hrv
        case .stress: return .stress
        case .bloodPressure: return .bloodPressure
        case .bloodOxygen: return .bloodOxygen
        case .temperature: return .temperature
        case .respiration: return .respiration
        case .bloodChemistry: return .metabolic
        }
    }
}

/// One home-screen tile and the page it opens. Each reads only the store values it shows.
struct HomeTileRow: View {
    @Environment(HealthDataStore.self) private var store
    @Environment(AppSettings.self) private var settings
    let tile: HomeTile

    var body: some View {
        NavigationLink {
            destination
        } label: {
            label
                // While the ring is off the finger, live readings aren't being taken.
                .opacity(store.isWorn == false && tile.section != .today ? 0.6 : 1)
        }
        .metricRowBackground(tile.style)
    }

    @ViewBuilder
    private var destination: some View {
        switch tile {
        case .activity: ActivityView()
        case .sleep: SleepView()
        case .heartRate: HeartRateView()
        case .hrv: HRVView()
        case .stress: StressView()
        case .bloodPressure: BloodPressureView()
        case .bloodOxygen: BloodOxygenView()
        case .temperature: TemperatureView()
        case .respiration: RespirationView()
        case .bloodChemistry: MetabolicView()
        }
    }

    @ViewBuilder
    private var label: some View {
        switch tile {
        case .activity:
            let today = store.today
            MetricTile(style: .activity, value: today.steps.grouped, unit: String(localized: "steps"),
                       detail: String(localized: "\(today.kilocalories) kcal · \(distance(today.distanceMeters))"))
        case .sleep:
            MetricTile(style: .sleep, value: store.lastNightSleep?.asleepSeconds.hoursMinutes ?? "--",
                       date: store.lastNightSleep?.end,
                       detail: store.lastNightSleep.map {
                           String(localized: "Score \($0.estimatedScore) · Deep \($0.deepSeconds.hoursMinutes)")
                       })
        case .heartRate:
            HeartRateTile()
        case .hrv:
            MetricTile(style: .hrv, value: store.latestHRV?.value.noDecimals ?? "--", unit: "ms",
                       date: store.latestHRV?.date, detail: store.hrvKind?.displayName)
        case .stress:
            MetricTile(style: .stress, value: store.latestStress?.value.oneDecimal ?? "--", unit: "/ 10",
                       date: store.latestStress?.date, detail: store.latestStress.map { StressView.level(for: $0.value) })
        case .bloodPressure:
            MetricTile(style: .bloodPressure,
                       value: store.latestBloodPressure.map { "\($0.value.systolic)/\($0.value.diastolic)" } ?? "--",
                       unit: "mmHg", date: store.latestBloodPressure?.date)
        case .bloodOxygen:
            MetricTile(style: .bloodOxygen, value: store.latestBloodOxygen.map { "\($0.value)" } ?? "--", unit: "%",
                       date: store.latestBloodOxygen?.date)
        case .temperature:
            MetricTile(style: .temperature, value: store.latestTemperature.map { settings.formatTemperature($0.value) } ?? "--",
                       date: store.latestTemperature?.date)
        case .respiration:
            MetricTile(style: .respiration, value: store.latestRespiration.map { "\($0.value)" } ?? "--",
                       unit: String(localized: "br/min"), date: store.latestRespiration?.date)
        case .bloodChemistry:
            let glucose = store.latestMetabolic?.glucose.map {
                ChemistryMarker.glucose.format($0, milligramsPerDeciliter: settings.usesMilligramsPerDeciliter)
            }
            MetricTile(style: .metabolic, value: glucose?.value ?? "--", unit: glucose?.unit ?? "",
                       date: store.latestMetabolic?.date, detail: String(localized: "Glucose (estimate)"))
        }
    }

    private func distance(_ meters: Int) -> String {
        Measurement(value: Double(meters), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// Heart rate reads the engine too (the icon pulses while streaming), so it is its own view.
private struct HeartRateTile: View {
    @Environment(HealthDataStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(RingBluetoothManager.self) private var transport

    var body: some View {
        MetricTile(style: .heartRate, value: store.latestHeartRate.map { "\($0.value)" } ?? "--", unit: "BPM",
                   date: store.latestHeartRate?.date,
                   detail: store.restingHeartRate.map { String(localized: "Resting \($0) BPM") },
                   isLive: settings.liveStreaming && transport.state.isConnected)
    }
}

private struct SyncFooter: View {
    @Environment(RingSyncEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let last = engine.lastHistorySync {
            TimelineView(.everyMinute) { _ in
                Text("History synced \(last, format: .relative(presentation: .named)). Live values refresh every \(settings.liveRefreshSeconds) s.")
            }
        } else {
            Text("Live values refresh every \(settings.liveRefreshSeconds) s while the app is open.")
        }
    }
}

/// First-run card: pair a ring, or look around with demo data.
struct OnboardingCard: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Welcome", systemImage: "circle.circle")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            NavigationLink { DeviceView() } label: {
                Label("Pair your ring", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                settings.demoMode = true
            } label: {
                Label("Try demo data", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("A ring accepts one connection at a time: close Smarthealth on your iPhone while pairing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Color.clear)
    }
}

/// Connection state, ring name and battery at the top of the home screen.
struct ConnectionHeader: View {
    @Environment(HealthDataStore.self) private var store
    @Environment(RingSyncEngine.self) private var engine
    @Environment(RingBluetoothManager.self) private var transport
    @Environment(AppSettings.self) private var settings
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: isBusy && !isLuminanceReduced)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(subtitleIsWarning ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let battery = store.batteryPercent {
                Label("\(battery)%", systemImage: BatterySymbol.name(percent: battery, charging: store.isCharging))
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(battery <= 20 && !store.isCharging ? Color.red : Color.secondary)
                    .accessibilityLabel(store.isCharging ? "Ring battery \(battery)%, charging" : "Ring battery \(battery)%")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if settings.demoMode { return String(localized: "Demo ring") }
        return transport.connectedName ?? transport.savedRingName ?? String(localized: "No ring")
    }

    private var subtitle: String {
        if settings.demoMode { return String(localized: "Showing sample data") }
        if transport.state == .paused { return String(localized: "Paused · tap to reconnect") }
        if transport.savedRingID == nil && !transport.state.isConnected { return String(localized: "Tap to pair a ring") }
        if transport.isWaitingForRing { return String(localized: "Waiting for ring") }
        if transport.state.isConnected && store.isWorn == false { return String(localized: "Connected · not worn") }
        if engine.isSyncingHistory { return String(localized: "Syncing history…") }
        return transport.state.label
    }

    private var subtitleIsWarning: Bool {
        !settings.demoMode && (transport.state == .paused || (transport.state.isConnected && store.isWorn == false))
    }

    private var isBusy: Bool {
        if settings.demoMode { return false }
        if engine.isSyncingHistory { return true }
        // After half a minute of reconnecting, stop pulsing: nothing is actively happening.
        if transport.isWaitingForRing { return false }
        switch transport.state {
        case .scanning, .connecting, .discovering, .reconnecting: return true
        default: return false
        }
    }

    private var statusSymbol: String {
        if settings.demoMode { return "sparkles" }
        switch transport.state {
        case .ready: return store.isWorn == false ? "hand.raised.slash" : "dot.radiowaves.left.and.right"
        case .paused: return "pause.circle"
        case .bluetoothUnavailable: return "exclamationmark.triangle"
        default: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        if settings.demoMode { return .yellow }
        switch transport.state {
        case .ready: return store.isWorn == false ? .orange : .green
        case .paused: return .orange
        default: return .secondary
        }
    }
}

enum BatterySymbol {
    static func name(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
