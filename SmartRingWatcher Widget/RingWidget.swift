import SwiftUI
import WidgetKit

/// Complications and the Smart Stack widget: latest heart rate with its age, today's steps
/// against the goal, and ring battery. Data comes from the summary the app writes to the
/// shared App Group container after each sync.
@main
struct RingWidgetBundle: WidgetBundle {
    var body: some Widget {
        RingSummaryWidget()
    }
}

struct RingSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedContainer.summaryWidgetKind, provider: SummaryProvider()) { entry in
            SummaryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("SmartRing")
        .description("Heart rate, steps and ring battery.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct SummaryEntry: TimelineEntry {
    let date: Date
    let summary: RingSummary?
}

struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: .now, summary: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        completion(SummaryEntry(date: .now, summary: context.isPreview ? .placeholder : SharedContainer.readSummary() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        let now = Date.now
        let summary = SharedContainer.readSummary()
        var entries = [SummaryEntry(date: now, summary: summary)]
        // One more entry at midnight so today's steps reset even without a sync.
        if let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0),
                                                    matchingPolicy: .nextTime) {
            entries.append(SummaryEntry(date: midnight, summary: summary))
        }
        // The app requests reloads after syncing; this is only a fallback.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct SummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SummaryEntry

    private var summary: RingSummary? { entry.summary }
    private var steps: Int { summary?.steps(on: entry.date) ?? 0 }
    private var progress: Double { summary?.stepProgress(on: entry.date) ?? 0 }
    private var heartRateText: String { summary?.heartRate.map { "\($0)" } ?? "--" }
    /// Heart rate older than 6 hours is shown as stale.
    private var heartRateIsStale: Bool {
        guard let date = summary?.heartRateDate else { return true }
        return entry.date.timeIntervalSince(date) > 6 * 3600
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        case .accessoryInline: inline
        default: rectangular
        }
    }

    /// Steps progress around the edge, heart rate in the middle.
    private var circular: some View {
        Gauge(value: progress) {
            Image(systemName: "heart.fill")
        } currentValueLabel: {
            VStack(spacing: -2) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .widgetAccentable()
                Text(heartRateText)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .opacity(heartRateIsStale ? 0.6 : 1)
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(.green)
        .accessibilityLabel(accessibilitySummary)
    }

    private var corner: some View {
        Text(heartRateText)
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .widgetCurvesContent()
            .widgetLabel {
                Gauge(value: progress) {
                    Text("Steps")
                } currentValueLabel: {
                    Text(steps.formatted(.number.notation(.compactName)))
                }
                .tint(.green)
            }
            .accessibilityLabel(accessibilitySummary)
    }

    private var inline: some View {
        ViewThatFits {
            Text("♥ \(heartRateText) · \(steps.formatted()) steps")
            Text("♥ \(heartRateText) · \(steps.formatted(.number.notation(.compactName)))")
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .widgetAccentable()
                Text(heartRateText)
                    .font(.system(.headline, design: .rounded))
                Text("BPM").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let date = summary?.heartRateDate {
                    Text(date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .opacity(heartRateIsStale ? 0.6 : 1)
            Gauge(value: progress) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(.green)
            HStack {
                Text("\(steps.formatted()) steps")
                Spacer(minLength: 0)
                if let battery = summary?.batteryPercent {
                    Label("\(battery)%", systemImage: summary?.isCharging == true ? "battery.100percent.bolt" : "battery.50percent")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(battery <= 20 ? .red : .secondary)
                }
            }
            .font(.caption2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let hr = summary?.heartRate { parts.append(String(localized: "Heart rate \(hr)")) }
        parts.append(String(localized: "\(steps) steps"))
        if let battery = summary?.batteryPercent { parts.append(String(localized: "ring battery \(battery)%")) }
        return parts.joined(separator: ", ")
    }
}

#Preview(as: .accessoryRectangular) {
    RingSummaryWidget()
} timeline: {
    SummaryEntry(date: .now, summary: .placeholder)
}

#Preview(as: .accessoryCircular) {
    RingSummaryWidget()
} timeline: {
    SummaryEntry(date: .now, summary: .placeholder)
}
