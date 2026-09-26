import SwiftUI

/// Pairing and ring status: scan for rings, connect, see battery/firmware, disconnect.
struct DeviceView: View {
    @Environment(HealthDataStore.self) private var store
    @Environment(RingSyncEngine.self) private var engine
    @Environment(RingBluetoothManager.self) private var transport
    @Environment(AppSettings.self) private var settings
    @State private var showsAllDevices = false

    var body: some View {
        List {
            if settings.demoMode {
                Section {
                    Text("Demo mode is on: showing generated data. Turn it off in Settings to use a real ring.")
                        .font(.footnote)
                }
            }

            if transport.isSlowToConnect {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Ring not responding", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Is it charged and nearby? Is Smarthealth connected on your phone?")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel", role: .cancel) { transport.cancelConnectionAttempt() }
                }
            }

            Section("Status") {
                DetailRow(label: "State", value: transport.isWaitingForRing ? String(localized: "Waiting for ring") : transport.state.label)
                if let name = transport.connectedName ?? transport.savedRingName {
                    DetailRow(label: "Ring", value: name)
                }
                if let battery = store.batteryPercent {
                    HStack {
                        Text("Battery").foregroundStyle(.secondary)
                        Spacer()
                        Label("\(battery)%", systemImage: BatterySymbol.name(percent: battery, charging: store.isCharging))
                            .labelStyle(.titleAndIcon)
                            .monospacedDigit()
                    }
                    .font(.footnote)
                }
                if transport.state.isConnected, let worn = store.isWorn {
                    DetailRow(label: "Worn", value: worn ? String(localized: "Yes") : String(localized: "No"))
                }
                if let firmware = store.deviceInfo?.firmwareVersion ?? transport.gattInfo["Firmware"] {
                    DetailRow(label: "Firmware", value: firmware)
                }
                if let proto = transport.protocolName {
                    DetailRow(label: "Protocol", value: proto)
                }
                ForEach(transport.gattInfo.keys.sorted().filter { $0 != "Firmware" }, id: \.self) { key in
                    DetailRow(label: "\(key)", value: transport.gattInfo[key] ?? "")
                }
                if let live = engine.lastLivePoll {
                    timeRow("Last poll", live)
                }
                if !transport.state.isConnected, let last = transport.lastConnectedAt {
                    timeRow("Last connected", last)
                }
            }

            if !settings.demoMode && (transport.state.isConnected || transport.savedRingID != nil) {
                Section {
                    if transport.state.isConnected {
                        if transport.hasProtocolChannel {
                            Button("Sync now") { engine.refreshNow() }
                        }
                        Button("Disconnect") { transport.disconnect(forget: false) }
                    } else if transport.state == .paused || transport.state == .idle {
                        Button("Reconnect") { transport.reconnect() }
                    } else if transport.state.isConnecting {
                        Button("Stop reconnecting") { transport.disconnect(forget: false) }
                    }
                    Button("Forget this ring", role: .destructive) { transport.disconnect(forget: true) }
                } footer: {
                    if transport.state.isConnected && !transport.hasProtocolChannel {
                        Text("This ring only offers the standard heart-rate and battery services, so history sync and measurements aren't available.")
                    } else if transport.state == .paused {
                        Text("Paused so your phone can connect. The ring stays disconnected until you tap Reconnect.")
                    }
                }
            }

            if !settings.demoMode {
                pairingSection
            }
        }
        .navigationTitle("Ring")
    }

    private func timeRow(_ label: LocalizedStringKey, _ date: Date) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            RelativeTimeLabel(date: date)
        }
        .font(.footnote)
    }

    private var pairingSection: some View {
        let likely = transport.discovered.filter(\.looksLikeRing)
        let others = transport.discovered.filter { !$0.looksLikeRing }
        return Section {
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
            ForEach(likely) { ring in ringRow(ring) }
            if !others.isEmpty {
                Button {
                    withAnimation { showsAllDevices.toggle() }
                } label: {
                    Label(showsAllDevices ? "Hide other devices" : "Show all devices (\(others.count))",
                          systemImage: showsAllDevices ? "chevron.up" : "chevron.down")
                        .font(.footnote)
                }
                if showsAllDevices {
                    ForEach(others) { ring in ringRow(ring) }
                }
            }
        } header: {
            Text("Pair a ring")
        } footer: {
            Text("A ring accepts one connection at a time. If it doesn't show up, close Smarthealth on your iPhone or turn off the phone's Bluetooth for a moment.")
        }
    }

    private func ringRow(_ ring: DiscoveredRing) -> some View {
        Button {
            transport.connect(to: ring)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ring.name).lineLimit(1)
                    if ring.id == transport.savedRingID {
                        savedRingDetail
                    }
                }
                Spacer()
                if ring.id == transport.savedRingID {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
                Image(systemName: "cellularbars", variableValue: ring.signalLevel)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Signal \(Int(ring.signalLevel * 100))%")
            }
        }
    }

    @ViewBuilder
    private var savedRingDetail: some View {
        let battery = store.batteryPercent.map { String(localized: "\($0)%") }
        if let last = transport.lastConnectedAt {
            HStack(spacing: 3) {
                Text("Last connected")
                Text(last, format: .relative(presentation: .named))
                if let battery { Text("· \(battery)") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var canScan: Bool {
        if case .bluetoothUnavailable = transport.state { return false }
        return !settings.demoMode
    }
}

struct SettingsView: View {
    @Environment(RingSyncEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var confirmErase = false
    @State private var confirmChemistry = false

    var body: some View {
        @Bindable var settings = settings
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
                Text("Live values are polled while the app is open. Heart-rate and step history follow the History sync setting; vitals sync about hourly and sleep once in the morning, because the ring resends its whole history each time. Streaming uses more ring battery.")
            }

            Section("Home screen") {
                NavigationLink("Edit tiles") { EditTilesView() }
                Picker("Step goal", selection: $settings.stepGoal) {
                    ForEach(AppSettings.stepGoalOptions, id: \.self) { Text($0.grouped).tag($0) }
                }
            }

            Section("Units") {
                Picker("Temperature", selection: $settings.temperatureUnit) {
                    Text("Automatic").tag(TemperatureUnitPreference.automatic)
                    Text("°C").tag(TemperatureUnitPreference.celsius)
                    Text("°F").tag(TemperatureUnitPreference.fahrenheit)
                }
            }

            Section {
                Toggle("Save to Health", isOn: $settings.healthKitExport)
            } header: {
                Text("Apple Health")
            } footer: {
                Text("Writes heart rate, HRV (SDNN), blood oxygen, respiration, blood pressure, steps, distance, energy and sleep. Ring steps overlap with your watch's own; Health counts the source you rank first. Temperature and blood chemistry are never written.")
            }

            Section {
                Toggle("Low ring battery", isOn: $settings.notifyLowBattery)
                Toggle("Ring not seen for a day", isOn: $settings.notifyRingNotSeen)
                Toggle("Measurement finished", isOn: $settings.notifyMeasurement)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Measurement alerts only appear when the app isn't open.")
            }

            Section {
                Toggle("Show experimental blood-chemistry estimates", isOn: Binding(
                    get: { settings.showBloodChemistry },
                    set: { newValue in
                        if newValue { confirmChemistry = true } else { settings.showBloodChemistry = false }
                    }))
                if settings.showBloodChemistry {
                    Picker("Units", selection: $settings.chemistryUnit) {
                        Text("Automatic").tag(ChemistryUnitPreference.automatic)
                        Text("mmol/L").tag(ChemistryUnitPreference.mmolPerLiter)
                        Text("mg/dL").tag(ChemistryUnitPreference.mgPerDeciliter)
                    }
                }
            } header: {
                Text("Blood chemistry")
            } footer: {
                Text("Some rings estimate glucose, uric acid, ketones and lipids optically. No such device is authorized to measure these without a blood sample, and the FDA warns that relying on one can lead to dangerous dosing errors.")
            }

            Section {
                Toggle("Demo mode", isOn: $settings.demoMode)
            } footer: {
                Text("Shows generated sample data, for the simulator or a first look. Your ring's cached data is kept, and the ring is released while demo mode is on.")
            }

            Section {
                NavigationLink("Diagnostics") { DiagnosticsView() }
                Button("Erase cached data", role: .destructive) { confirmErase = true }
            } footer: {
                Text("The ring keeps its own history, so erased data is synced again on the next connection.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Erase cached data?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { engine.eraseCache() }
        }
        .alert("Blood chemistry estimates", isPresented: $confirmChemistry) {
            Button("Show estimates") { settings.showBloodChemistry = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These are not blood tests. Never use them to decide on insulin or any other treatment.")
        }
    }
}

/// Show, hide and reorder home-screen tiles within their section.
struct EditTilesView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        List {
            ForEach(HomeTile.Section.allCases, id: \.self) { section in
                let tiles = settings.orderedTiles.filter {
                    $0.section == section && ($0 != .bloodChemistry || settings.showBloodChemistry)
                }
                Section(section.title) {
                    ForEach(tiles) { tile in
                        Toggle(isOn: Binding(
                            get: { !settings.hiddenTiles.contains(tile) },
                            set: { shown in
                                if shown { settings.hiddenTiles.remove(tile) } else { settings.hiddenTiles.insert(tile) }
                            })) {
                            Label { Text(tile.style.title) } icon: {
                                Image(systemName: tile.style.symbol).foregroundStyle(tile.style.color)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { settings.move(tile, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                                .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button { settings.move(tile, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                                .tint(.blue)
                        }
                    }
                }
            }
            Section {
                Button("Reset to default") { settings.resetTiles() }
            } footer: {
                Text("Swipe a tile to move it up or down. Tiles only appear once the ring has reported that value.")
            }
        }
        .navigationTitle("Edit tiles")
    }
}

struct DiagnosticsView: View {
    @Environment(RingSyncEngine.self) private var engine
    @Environment(RingBluetoothManager.self) private var transport
    @Environment(HealthDataStore.self) private var store
    @Environment(DiagnosticsLog.self) private var log

    private static let timeStyle = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    var body: some View {
        @Bindable var log = log
        List {
            Section("Connection") {
                DetailRow(label: "State", value: transport.state.label)
                DetailRow(label: "Protocol", value: transport.protocolName ?? "–")
                DetailRow(label: "Firmware", value: store.deviceInfo?.firmwareVersion ?? transport.gattInfo["Firmware"] ?? "–")
                DetailRow(label: "Write MTU", value: transport.maximumWriteLength.map { "\($0) B" } ?? "–")
                DetailRow(label: "CRC errors", value: "\(engine.crcErrors)")
            }

            if !engine.commandStatus.isEmpty {
                Section("Requests") {
                    ForEach(engine.commandStatus.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { type in
                        if let status = engine.commandStatus[type] {
                            statusRow(type, status)
                        }
                    }
                }
            }

            Section {
                ShareLink(item: log.exportText, subject: Text("SmartRing diagnostics")) {
                    Label("Share log", systemImage: "square.and.arrow.up")
                }
                Toggle("Record raw frames", isOn: $log.recordsFrames)
                Button("Clear log") { log.clear() }
            } footer: {
                Text("Raw frames show every byte exchanged with the ring, in hex, for bug reports.")
            }

            Section("Log") {
                if log.entries.isEmpty {
                    Text("No events yet.").foregroundStyle(.secondary)
                }
                ForEach(log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(entry.date.formatted(Self.timeStyle)) · \(entry.category.rawValue)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(entry.isError ? Color.orange : Color.primary)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }

    private func statusRow(_ type: YCDataType, _ status: CommandStatus) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Image(systemName: symbol(for: status.state)).foregroundStyle(color(for: status.state))
                Text(RingSyncEngine.name(of: type)).font(.footnote)
            }
            Group {
                switch status.state {
                case .ok:
                    if let bytes = status.lastBytes, let records = status.lastRecords {
                        Text("\(records) records · \(bytes.formatted(.byteCount(style: .memory)))")
                    } else if let last = status.lastSuccess {
                        Text(last, format: .relative(presentation: .named))
                    }
                case .failing:
                    Text("Failed \(status.failures)× · retry \(status.retryAt.map { $0.formatted(.relative(presentation: .named)) } ?? "soon")")
                case .unsupported:
                    Text("Not supported by this ring")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func symbol(for state: CommandStatus.State) -> String {
        switch state {
        case .ok: return "checkmark.circle"
        case .failing: return "arrow.clockwise.circle"
        case .unsupported: return "slash.circle"
        }
    }

    private func color(for state: CommandStatus.State) -> Color {
        switch state {
        case .ok: return .green
        case .failing: return .orange
        case .unsupported: return .secondary
        }
    }
}
