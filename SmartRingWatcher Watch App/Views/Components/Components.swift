import SwiftUI

/// Visual identity of each metric (icon + tint), shared by the summary list and detail pages.
enum MetricStyle {
    case heartRate, hrv, sleep, activity, bloodPressure, bloodOxygen, temperature, stress, respiration, metabolic, device

    var title: String {
        switch self {
        case .heartRate: return "Heart Rate"
        case .hrv: return "HRV"
        case .sleep: return "Sleep"
        case .activity: return "Activity"
        case .bloodPressure: return "Blood Pressure"
        case .bloodOxygen: return "Blood Oxygen"
        case .temperature: return "Temperature"
        case .stress: return "Stress"
        case .respiration: return "Respiration"
        case .metabolic: return "Blood Chemistry"
        case .device: return "Ring"
        }
    }

    var symbol: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .sleep: return "bed.double.fill"
        case .activity: return "figure.walk"
        case .bloodPressure: return "gauge.with.dots.needle.33percent"
        case .bloodOxygen: return "lungs.fill"
        case .temperature: return "thermometer.medium"
        case .stress: return "brain.head.profile"
        case .respiration: return "wind"
        case .metabolic: return "drop.fill"
        case .device: return "circle.circle"
        }
    }

    var color: Color {
        switch self {
        case .heartRate: return .red
        case .hrv: return .pink
        case .sleep: return .indigo
        case .activity: return .green
        case .bloodPressure: return .orange
        case .bloodOxygen: return .cyan
        case .temperature: return .yellow
        case .stress: return .purple
        case .respiration: return .teal
        case .metabolic: return .mint
        case .device: return .gray
        }
    }
}

/// One row of the summary list: icon, title, big value and when it was measured.
struct MetricTile: View {
    let style: MetricStyle
    let value: String
    var unit: String = ""
    var date: Date?
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(style.title, systemImage: style.symbol)
                .font(.caption2)
                .foregroundStyle(style.color)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let date {
                RelativeTimeLabel(date: date)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "2 min ago", refreshed automatically by SwiftUI's relative date style.
struct RelativeTimeLabel: View {
    let date: Date

    var body: some View {
        // Re-evaluated every few seconds so "just now" ages without a data change.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let age = context.date.timeIntervalSince(date)
            Group {
                if age < 10 {
                    Text("just now")
                } else if age > 20 * 3600 {
                    Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
                } else {
                    Text("\(date, style: .relative) ago")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

/// Large headline value for detail pages.
struct HeroValue: View {
    let style: MetricStyle
    let value: String
    var unit: String = ""
    var date: Date?
    var caption: String?

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.color)
                .font(.title3)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(unit)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let caption {
                Text(caption)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(style.color)
            }
            if let date {
                RelativeTimeLabel(date: date)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Min / average / max row.
struct StatRow: View {
    struct Item: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let items: [Item]

    var body: some View {
        HStack {
            ForEach(items) { item in
                VStack(spacing: 1) {
                    Text(item.value)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Labeled value used in detail lists.
struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.footnote)
    }
}

/// Starts a one-off measurement on the ring and shows its progress.
struct MeasureButton: View {
    @EnvironmentObject private var engine: RingSyncEngine
    @EnvironmentObject private var transport: RingBluetoothManager
    @EnvironmentObject private var settings: AppSettings
    let kind: MeasurementKind

    private var isMeasuring: Bool { engine.activeMeasurement == kind }
    private var canMeasure: Bool { settings.demoMode || transport.hasProtocolChannel && transport.state.isConnected }

    var body: some View {
        VStack(spacing: 4) {
            Button {
                if isMeasuring {
                    engine.stopMeasurement(kind)
                } else {
                    engine.startMeasurement(kind)
                }
            } label: {
                if isMeasuring {
                    HStack {
                        ProgressView()
                            .frame(width: 18, height: 18)
                        Text("Stop")
                    }
                } else {
                    Label("Measure now", systemImage: "play.circle")
                }
            }
            .disabled(!canMeasure)

            if isMeasuring {
                Text("Keep your hand still…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let last = engine.lastMeasurementOutcome, last.kind == kind, last.outcome != .success {
                Text("Measurement \(last.outcome.rawValue). Check the ring fits snugly.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else if !canMeasure {
                Text("Connect a ring to measure")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Placeholder when a metric has no data yet.
struct NoDataView: View {
    let style: MetricStyle
    var message = "No data yet. It appears after the ring's next measurement and sync."

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: style.symbol)
                .font(.title2)
                .foregroundStyle(style.color.opacity(0.6))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

extension TimeInterval {
    /// 27000 → "7h 30m"
    var hoursMinutes: String {
        let totalMinutes = Int((self / 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

extension Double {
    var oneDecimal: String { String(format: "%.1f", self) }
    var noDecimals: String { String(format: "%.0f", self) }
}
