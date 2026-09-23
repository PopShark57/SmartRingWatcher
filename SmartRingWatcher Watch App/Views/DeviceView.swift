import SwiftUI

/// Pairing and ring status: scan for rings, connect, see battery/firmware, disconnect.
struct DeviceView: View {
    @EnvironmentObject private var store: HealthDataStore
    @EnvironmentObject private var engine: RingSyncEngine
    @EnvironmentObject private var transport: RingBluetoothManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            if settings.demoMode {
                Section {
                    Text("Demo mode is on: showing generated data. Turn it off in Settings to use a real ring.")
                        .font(.footnote)
                }
            }

            Section("Status") {
                DetailRow(label: "State", value: transport.state.label)
                if let name = transport.connectedName ?? transport.savedRingName {
                    DetailRow(label: "Ring", value: name)
                }
                if let battery = store.live.batteryPercent ?? store.deviceInfo?.batteryPercent {
                    DetailRow(label: "Battery", value: "\(battery)%" + (store.deviceInfo?.isCharging == true ? " ⚡︎" : ""))
                }
                if let firmware = store.deviceInfo?.firmwareVersion ?? transport.gattInfo["Firmware"] {
                    DetailRow(label: "Firmware", value: firmware)
                }
                if let proto = transport.protocolName {
                    DetailRow(label: "Protocol", value: proto)
                }
                ForEach(transport.gattInfo.keys.sorted().filter { $0 != "Firmware" }, id: \.self) { key in
                    DetailRow(label: key, value: transport.gattInfo[key] ?? "")
                }
                if let live = engine.lastLivePoll {
                    HStack {
                        Text("Last poll").foregroundStyle(.secondary)
                        Spacer()
                        RelativeTimeLabel(date: live)
                    }
                    .font(.footnote)
                }
            }

            if transport.state.isConnected || transport.savedRingID != nil {
                Section {
                    if transport.state.isConnected {
                        Button("Sync now") { engine.refreshNow() }
                        Button("Disconnect") { transport.disconnect(forget: false) }
                    } else {
                        Button("Reconnect") { transport.connectSavedRing() }
                    }
                    Button("Forget this ring", role: .destructive) { transport.disconnect(forget: true) }
                }
            }

            Section {
                if transport.state == .scanning {
                    HStack {
                        ProgressView().frame(width: 20, height: 20)
                        Text("Scanning…")
                        Spacer()
                        Button("Stop") { transport.stopScan() }
                            .buttonStyle(.borderless)
                    }
                } else {
                    Button {
                        transport.startScan()
                    } label: {
                        Label("Find rings", systemImage: "magnifyingglass")
                    }
                    .disabled(!canScan)
                }
                ForEach(transport.discovered) { ring in
                    Button {
                        transport.connect(to: ring)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ring.name).lineLimit(1)
                                Text("\(ring.rssi) dBm" + (ring.looksLikeRing ? " · likely ring" : ""))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if ring.id == transport.savedRingID {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                }
            } header: {
                Text("Pair a ring")
            } footer: {
                Text("A ring accepts one connection at a time. If it doesn't show up, close Smarthealth on your iPhone or turn off the phone's Bluetooth for a moment.")
            }
        }
        .navigationTitle("Ring")
    }

    private var canScan: Bool {
        if case .bluetoothUnavailable = transport.state { return false }
        return !settings.demoMode
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: HealthDataStore
    @EnvironmentObject private var engine: RingSyncEngine
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmErase = false

    var body: some View {
        List {
            Section {
                Picker("Live refresh", selection: $settings.liveRefreshSeconds) {
                    ForEach(AppSettings.liveRefreshOptions, id: \.self) { Text("\($0) s").tag($0) }
                }
                Picker("History sync", selection: $settings.historyRefreshMinutes) {
                    ForEach(AppSettings.historyRefreshOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                Toggle("Stream live HR & steps", isOn: $settings.liveStreaming)
            } header: {
                Text("Auto-refresh")
            } footer: {
                Text("Live values are polled while the app is open; history is also refreshed in the background when watchOS allows it. Streaming uses more ring battery.")
            }

            Section("Units") {
                Toggle("Fahrenheit", isOn: $settings.useFahrenheit)
            }

            Section {
                Toggle("Demo mode", isOn: $settings.demoMode)
            } footer: {
                Text("Shows generated data, for the simulator or a first look. Replaces cached data; nothing on the ring is changed.")
            }

            Section {
                NavigationLink("Diagnostics") { DiagnosticsView() }
                Button("Erase cached data", role: .destructive) { confirmErase = true }
            } footer: {
                Text("The ring keeps its own history, so erased data is synced again on the next connection.")
            }
        }
        .navigationTitle("Settings")
        .onChange(of: settings.liveRefreshSeconds) { _, _ in engine.settingsChanged() }
        .onChange(of: settings.historyRefreshMinutes) { _, _ in engine.settingsChanged() }
        .onChange(of: settings.liveStreaming) { _, _ in engine.settingsChanged() }
        .onChange(of: settings.demoMode) { _, _ in engine.settingsChanged() }
        .confirmationDialog("Erase cached data?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) {
                store.eraseAll()
                engine.refreshNow()
            }
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var engine: RingSyncEngine

    var body: some View {
        List {
            if engine.log.isEmpty {
                Text("No events yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(engine.log.enumerated().reversed()), id: \.offset) { entry in
                Text(entry.element)
                    .font(.system(.caption2, design: .monospaced))
            }
        }
        .navigationTitle("Diagnostics")
    }
}
