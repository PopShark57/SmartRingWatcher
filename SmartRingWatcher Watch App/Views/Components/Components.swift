import SwiftUI

/// Visual identity of each metric (icon + tint), shared by the summary list and detail pages.
enum MetricStyle {
    case heartRate, hrv, sleep, activity, bloodPressure, bloodOxygen, temperature, stress, respiration, metabolic, device

    var title: LocalizedStringResource {
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
        // Blood chemistry is never colour-coded; a neutral tint keeps it visually quiet.
        case .metabolic: return .gray
        case .device: return .gray
        }
    }
}

/// How old a reading may get before the UI shows it as stale.
enum Staleness {
    /// Values older than this are dimmed.
    static let dimAfter: TimeInterval = 6 * 3600
    /// Values older than this get a clock badge.
    static let badgeAfter: TimeInterval = 24 * 3600
}

/// One row of the summary list: icon, title, big value and when it was measured.
struct MetricTile: View {
    let style: MetricStyle
    let value: String
    var unit: String = ""
    var date: Date?
    var detail: String?
    /// Pulse the icon (heart rate while live streaming).
    var isLive = false

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        // Per-minute: enough for "5 min ago" and for dimming stale values without new data.
        TimelineView(.everyMinute) { context in
            let age = date.map { context.date.timeIntervalSince($0) } ?? 0
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Label {
                        Text(style.title)
                    } icon: {
                        Image(systemName: style.symbol)
                            .symbolEffect(.bounce, value: date)
                            .symbolEffect(.pulse, isActive: isLive && !isLuminanceReduced)
                    }
                    .font(.caption2)
                    .foregroundStyle(style.color)
                    Spacer(minLength: 0)
                    if age > Staleness.badgeAfter {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Over a day old")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .contentTransition(.numericText())
                        .foregroundStyle(age > Staleness.dimAfter ? .secondary : .primary)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                // `.numericText()` only animates inside an animation transaction.
                .animation(.snappy, value: value)
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows history")
    }
}

extension View {
    /// A very subtle tint of the metric's colour behind a list row.
    func metricRowBackground(_ style: MetricStyle) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(style.color.opacity(0.14))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.08)))
        )
    }

    /// The metric's tinted full-screen background on a detail page, like the system apps.
    func metricPage(_ style: MetricStyle) -> some View {
        containerBackground(style.color.gradient, for: .navigation)
    }
}

/// "Just now", "5 minutes ago", or the weekday and time for older values. Updates once a
/// minute, which is also all an app gets in Always On.
struct RelativeTimeLabel: View {
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            let age = context.date.timeIntervalSince(date)
            Group {
                if age < 60 {
                    Text("Just now")
                } else if age < 20 * 3600 {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

/// Large headline value for detail pages. Scales with the user's text size.
struct HeroValue: View {
    let style: MetricStyle
    let value: String
    var unit: String = ""
    var date: Date?
    var caption: String?
    /// Blood chemistry passes `.secondary`: those values are never colour-coded.
    var captionColor: Color?

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.color)
                .font(.title3)
                .symbolEffect(.bounce, value: date)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(unit)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .animation(.snappy, value: value)
            if let caption {
                Text(caption)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(captionColor ?? style.color)
                    .multilineTextAlignment(.center)
            }
            if let date {
                RelativeTimeLabel(date: date)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Min / average / max row.
struct StatRow: View {
    struct Item {
        let label: LocalizedStringKey
        let value: String
    }

    let items: [Item]

    var body: some View {
        HStack {
            ForEach(items.indices, id: \.self) { index in
                VStack(spacing: 1) {
                    Text(items[index].value)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text(items[index].label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Labeled value used in detail lists.
struct DetailRow: View {
    let label: LocalizedStringKey
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
        .accessibilityElement(children: .combine)
    }
}

/// Section caption above a chart, with the unit on the right (the axes carry no units).
struct ChartHeader: View {
    let title: LocalizedStringKey
    var unit: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let unit { Text(unit) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// Starts a one-off measurement on the ring and shows its progress: a countdown while it
/// runs, a haptic when it ends (people usually look away while measuring), and the new value
/// with a checkmark once it arrives.
struct MeasureButton: View {
    @Environment(RingSyncEngine.self) private var engine
    @Environment(RingBluetoothManager.self) private var transport
    @Environment(AppSettings.self) private var settings
    @Environment(HealthDataStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    let kind: MeasurementKind
    /// The newest reading of what this button measures, formatted.
    var latest: Reading<String>?

    private var isMeasuring: Bool { engine.activeMeasurement == kind }
    private var isConnected: Bool { settings.demoMode || transport.state.isConnected }
    private var canMeasure: Bool { settings.demoMode || (transport.hasProtocolChannel && transport.state.isConnected) }
    private var notWorn: Bool { !settings.demoMode && store.isWorn == false }

    var body: some View {
        VStack(spacing: 6) {
            if isConnected && !canMeasure {
                // Standard-GATT rings have no measurement command.
                Text("This ring doesn't support on-demand measurements.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if isMeasuring, let start = engine.measurementStartedAt {
                countdown(from: start)
                Button("Stop", role: .cancel) { engine.stopMeasurement(kind) }
                Text("Keep still, ring snug")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    engine.startMeasurement(kind)
                } label: {
                    Label("Measure now", systemImage: "play.circle")
                }
                .disabled(!canMeasure || notWorn)
                status
            }
        }
        .sensoryFeedback(trigger: engine.lastMeasurementOutcome) { old, new in
            guard let new, new != old, new.kind == kind else { return nil }
            return new.outcome == .success ? .success : .error
        }
    }

    @ViewBuilder
    private var status: some View {
        if let result = engine.lastMeasurementOutcome, result.kind == kind {
            if result.outcome == .success {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    if let latest, latest.date >= result.startedAt.addingTimeInterval(-30) {
                        Text(latest.value).font(.footnote.weight(.semibold))
                    } else {
                        Text("Done. Fetching the result…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("Measurement \(result.outcome.rawValue). Keep still and check the ring fits snugly.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        } else if notWorn {
            Text("Put the ring on to measure")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if !canMeasure {
            Text("Connect a ring to measure")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func countdown(from start: Date) -> some View {
        let total = engine.measurementDuration
        return TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = min(total, max(0, context.date.timeIntervalSince(start)))
            let remaining = Int((total - elapsed).rounded(.up))
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: elapsed / total)
                    .stroke(Color.accentColor.opacity(isLuminanceReduced ? 0.5 : 1),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: elapsed)
                Text("\(remaining)")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 44, height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Measuring, up to \(remaining) seconds left")
        }
    }
}

/// Placeholder when a metric has no data yet.
struct NoDataView: View {
    let style: MetricStyle
    var message: LocalizedStringKey = "No data yet. It appears after the ring's next measurement and sync."

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
    /// 27000 → "7h 30m", localized.
    var hoursMinutes: String {
        let minutes = (self / 60).rounded()
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

extension Double {
    /// Locale-aware (a comma where the region uses one).
    var oneDecimal: String { formatted(.number.precision(.fractionLength(1))) }
    var noDecimals: String { formatted(.number.precision(.fractionLength(0))) }
    /// "+1.3" / "−2.5"
    var signedOneDecimal: String { formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) }
}

extension Int {
    var grouped: String { formatted(.number) }
}
