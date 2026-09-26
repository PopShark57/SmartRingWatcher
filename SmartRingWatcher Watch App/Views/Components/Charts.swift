import Charts
import SwiftUI

typealias ChartPoint = DatedValue

/// Axis labels that fit the time span: hours for a day, weekdays for a week, dates beyond.
private func timeAxisFormat(for span: TimeInterval) -> Date.FormatStyle {
    if span <= 36 * 3600 { return .dateTime.hour() }
    if span <= 8 * 86_400 { return .dateTime.weekday(.abbreviated) }
    return .dateTime.month(.defaultDigits).day()
}

/// Line chart used by most metric pages.
///
/// Tap it to focus, then turn the Digital Crown (or drag across it) to read the value at a
/// chosen time. Optional context: an area fill, a dashed 24 h average and a shaded normal range.
struct TrendChart: View {
    let points: [ChartPoint]
    let color: Color
    /// For VoiceOver: "Heart rate, last 24 hours, 52 to 118 BPM, average 71".
    let accessibilityName: String
    var unit = ""
    var yDomain: ClosedRange<Double>?
    var normalRange: ClosedRange<Double>?
    var showsArea = false
    var showsAverage = true
    var valueFormat: @Sendable (Double) -> String = { $0.noDecimals }
    var height: CGFloat = 90

    @State private var selection: Date?
    @State private var crown = 0.0

    private var span: TimeInterval {
        guard let first = points.first?.date, let last = points.last?.date else { return 0 }
        return last.timeIntervalSince(first)
    }

    private var average: Double? {
        points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count)
    }

    private var selectedPoint: ChartPoint? {
        guard let selection else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        let domain = yDomain ?? autoDomain
        Chart {
            if let normalRange, let first = points.first?.date, let last = points.last?.date, first < last {
                RectangleMark(xStart: .value("Start", first), xEnd: .value("End", last),
                              yStart: .value("Low", max(normalRange.lowerBound, domain.lowerBound)),
                              yEnd: .value("High", min(normalRange.upperBound, domain.upperBound)))
                    .foregroundStyle(Color.green.opacity(0.12))
                    .accessibilityHidden(true)
            }
            ForEach(points) { point in
                if showsArea {
                    AreaMark(x: .value("Time", point.date),
                             yStart: .value("Base", domain.lowerBound),
                             yEnd: .value("Value", point.value))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                        .accessibilityHidden(true)
                }
                LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(point.date.formatted(date: .omitted, time: .shortened))
                    .accessibilityValue("\(valueFormat(point.value)) \(unit)")
                if points.count < 12 {
                    PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
                        .foregroundStyle(color)
                        .symbolSize(18)
                        .accessibilityHidden(true)
                }
            }
            if showsAverage, let average, points.count > 2 {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
            if let selectedPoint {
                RuleMark(x: .value("Selected", selectedPoint.date))
                    .foregroundStyle(.white.opacity(0.6))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 0) {
                            Text(valueFormat(selectedPoint.value)).font(.caption2.weight(.semibold))
                            Text(selectedPoint.date, format: span > 36 * 3600 ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute())
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .padding(2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: timeAxisFormat(for: span))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
        }
        .chartXSelection(value: $selection)
        .frame(height: height)
        .focusable()
        .digitalCrownRotation($crown, from: 0, through: Double(max(points.count - 1, 1)), by: 1,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, value in
            guard !points.isEmpty else { return }
            selection = points[min(points.count - 1, max(0, Int(value.rounded())))].date
        }
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max(), let average else {
            return String(localized: "\(accessibilityName), no data")
        }
        return String(localized: "\(accessibilityName), \(valueFormat(lo)) to \(valueFormat(hi)) \(unit), average \(valueFormat(average))")
    }

    private var autoDomain: ClosedRange<Double> {
        let values = points.map(\.value) + (normalRange.map { [$0.lowerBound, $0.upperBound] } ?? [])
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.15, 1)
        return (lo - pad)...(hi + pad)
    }
}

/// Systolic/diastolic readings drawn as vertical bars from diastolic to systolic, with dashed
/// guides at 120 and 80 mmHg. The scale follows the data, so high readings aren't clipped.
struct BloodPressureChart: View {
    let samples: [BloodPressureSample]

    @State private var selection: Date?

    private var domain: ClosedRange<Double> {
        let low = Double(samples.map(\.diastolic).min() ?? 70)
        let high = Double(samples.map(\.systolic).max() ?? 130)
        var lower = min(low, 80) - 10
        var upper = max(high, 120) + 10
        if upper - lower < 60 {
            let pad = (60 - (upper - lower)) / 2
            lower -= pad
            upper += pad
        }
        return max(30, lower)...min(260, upper)
    }

    private var selected: BloodPressureSample? {
        guard let selection else { return nil }
        return samples.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Systolic guide", 120))
                .foregroundStyle(.green.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .accessibilityHidden(true)
            RuleMark(y: .value("Diastolic guide", 80))
                .foregroundStyle(.green.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .accessibilityHidden(true)
            ForEach(samples, id: \.date) { sample in
                RuleMark(x: .value("Time", sample.date),
                         yStart: .value("Diastolic", sample.diastolic),
                         yEnd: .value("Systolic", sample.systolic))
                    .foregroundStyle(MetricStyle.bloodPressure.color.opacity(selected == nil || selected == sample ? 1 : 0.5))
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    .accessibilityLabel(sample.date.formatted(date: .omitted, time: .shortened))
                    .accessibilityValue("\(sample.systolic) over \(sample.diastolic) mmHg")
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("\(selected.systolic)/\(selected.diastolic)")
                            .font(.caption2.weight(.semibold))
                            .padding(2)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4))
        }
        .chartXSelection(value: $selection)
        .frame(height: 100)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        guard let high = samples.map(\.systolic).max(), let low = samples.map(\.diastolic).min() else {
            return String(localized: "Blood pressure, no data")
        }
        return String(localized: "Blood pressure, last 24 hours, \(samples.count) readings, systolic up to \(high), diastolic down to \(low) mmHg")
    }
}

/// Bars per hour or per day, with an optional goal line or target band.
struct BarTrendChart: View {
    let bars: [DatedValue]
    let color: Color
    let unit: Calendar.Component
    let accessibilityName: String
    var valueUnit = ""
    /// Dashed line, e.g. the step goal.
    var goal: Double?
    /// Shaded band, e.g. 7–9 hours of sleep.
    var targetBand: ClosedRange<Double>?
    var valueFormat: @Sendable (Double) -> String = { $0.noDecimals }
    var height: CGFloat = 80

    var body: some View {
        Chart {
            if let targetBand, let first = bars.first?.date, let last = bars.last?.date {
                RectangleMark(xStart: .value("Start", first, unit: unit), xEnd: .value("End", last, unit: unit),
                              yStart: .value("Low", targetBand.lowerBound), yEnd: .value("High", targetBand.upperBound))
                    .foregroundStyle(Color.green.opacity(0.12))
                    .accessibilityHidden(true)
            }
            ForEach(bars) { bar in
                BarMark(x: .value("Time", bar.date, unit: unit), y: .value("Value", bar.value))
                    .foregroundStyle(color.gradient)
                    .cornerRadius(2)
                    .accessibilityLabel(bar.date.formatted(unit == .day ? .dateTime.weekday(.wide) : .dateTime.hour()))
                    .accessibilityValue("\(valueFormat(bar.value)) \(valueUnit)")
            }
            if let goal {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                if unit == .day {
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                } else {
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
        }
        .frame(height: height)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        let total = bars.map(\.value).reduce(0, +)
        let best = bars.max { $0.value < $1.value }
        guard let best, total > 0 else { return String(localized: "\(accessibilityName), no data") }
        let when = best.date.formatted(unit == .day ? .dateTime.weekday(.wide) : .dateTime.hour())
        return String(localized: "\(accessibilityName), highest \(valueFormat(best.value)) \(valueUnit) on \(when)")
    }
}

/// Hypnogram: one horizontal bar per sleep stage, awake at the top and deep at the bottom.
/// Only stages that occur get a row.
struct SleepStagesChart: View {
    let stages: [SleepStage]

    private static let order: [SleepStageKind] = [.awake, .rem, .light, .deep, .nap]

    private var presentKinds: [SleepStageKind] {
        let present = Set(stages.map(\.kind))
        return Self.order.filter { present.contains($0) }
    }

    var body: some View {
        Chart(stages, id: \.start) { stage in
            BarMark(xStart: .value("Start", stage.start),
                    xEnd: .value("End", stage.end),
                    y: .value("Stage", stage.kind.displayName))
                .foregroundStyle(Self.color(for: stage.kind))
                .accessibilityLabel(stage.kind.displayName)
                .accessibilityValue("\(stage.start.formatted(date: .omitted, time: .shortened)), \(stage.duration.hoursMinutes)")
        }
        .chartYScale(domain: presentKinds.map(\.displayName))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .frame(height: CGFloat(22 * max(presentKinds.count, 2)))
        .accessibilityLabel("Sleep stages")
    }

    static func color(for kind: SleepStageKind) -> Color {
        switch kind {
        case .deep: return .indigo
        case .light: return .blue
        case .rem: return .cyan
        case .awake: return .orange
        case .nap: return .mint
        }
    }
}

extension Array where Element == HeartRateSample {
    var chartPoints: [ChartPoint] { map { ChartPoint(date: $0.date, value: Double($0.bpm)) } }
}
