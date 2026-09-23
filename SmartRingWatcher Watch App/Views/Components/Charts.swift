import Charts
import SwiftUI

/// A (date, value) point for the generic trend chart.
struct ChartPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Compact line chart used by most metric pages.
struct TrendChart: View {
    let points: [ChartPoint]
    let color: Color
    var yDomain: ClosedRange<Double>?
    var showsPoints = false
    var height: CGFloat = 90

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
            if showsPoints || points.count < 12 {
                PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
                    .foregroundStyle(color)
                    .symbolSize(18)
            }
        }
        .chartYScale(domain: yDomain ?? autoDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
        }
        .frame(height: height)
    }

    private var autoDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.15, 1)
        return (lo - pad)...(hi + pad)
    }
}

/// Systolic/diastolic readings drawn as vertical bars from diastolic to systolic.
struct BloodPressureChart: View {
    let samples: [BloodPressureSample]

    var body: some View {
        Chart(samples, id: \.date) { sample in
            RuleMark(x: .value("Time", sample.date),
                     yStart: .value("Diastolic", sample.diastolic),
                     yEnd: .value("Systolic", sample.systolic))
                .foregroundStyle(MetricStyle.bloodPressure.color)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .chartYScale(domain: 50...170)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [60, 90, 120, 150])
        }
        .frame(height: 100)
    }
}

/// Bars per hour or per day.
struct BarTrendChart: View {
    struct Bar: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    let bars: [Bar]
    let color: Color
    let unit: Calendar.Component
    var height: CGFloat = 80

    var body: some View {
        Chart(bars) { bar in
            BarMark(x: .value("Time", bar.date, unit: unit), y: .value("Value", bar.value))
                .foregroundStyle(color.gradient)
                .cornerRadius(2)
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
    }
}

/// Hypnogram: one horizontal bar per sleep stage, awake at the top and deep at the bottom.
struct SleepStagesChart: View {
    let stages: [SleepStage]

    private static let order: [SleepStageKind] = [.awake, .rem, .light, .deep, .nap]

    var body: some View {
        Chart(stages, id: \.start) { stage in
            BarMark(xStart: .value("Start", stage.start),
                    xEnd: .value("End", stage.end),
                    y: .value("Stage", stage.kind.displayName))
                .foregroundStyle(Self.color(for: stage.kind))
        }
        .chartYScale(domain: Self.order.map(\.displayName))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .frame(height: 90)
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
