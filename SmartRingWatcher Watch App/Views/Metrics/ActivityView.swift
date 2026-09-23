import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var store: HealthDataStore

    private let stepGoal = 10_000

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(MetricStyle.activity.color.opacity(0.25), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: min(1, Double(store.stepsToday) / Double(stepGoal)))
                        .stroke(MetricStyle.activity.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut, value: store.stepsToday)
                    VStack(spacing: 0) {
                        Text(store.stepsToday.formatted())
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                            .contentTransition(.numericText())
                        Text("of \(stepGoal.formatted()) steps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 120)

                StatRow(items: [
                    .init(label: "Distance", value: distanceText),
                    .init(label: "kcal", value: "\(store.kilocaloriesToday)"),
                ])

                let hourly = store.hourlyStepsToday
                if !hourly.isEmpty {
                    Text("Today by hour")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    BarTrendChart(bars: hourly.map { BarTrendChart.Bar(date: $0.hour, value: Double($0.steps)) },
                                  color: MetricStyle.activity.color, unit: .hour)
                }

                Text("Last 7 days")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                BarTrendChart(bars: store.dailySteps.map { BarTrendChart.Bar(date: $0.day, value: Double($0.steps)) },
                              color: MetricStyle.activity.color, unit: .day)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Activity")
    }

    private var distanceText: String {
        Measurement(value: Double(store.distanceTodayMeters), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
