import SwiftUI

struct ActivityView: View {
    @Environment(HealthDataStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    /// The ring grows with the user's text size.
    @ScaledMetric(relativeTo: .title2) private var ringSize: CGFloat = 120

    var body: some View {
        let steps = store.today.steps
        let goal = settings.stepGoal
        let reached = steps >= goal
        let color = MetricStyle.activity.color
        ScrollView {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(color.opacity(0.25), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: min(1, Double(steps) / Double(max(goal, 1))))
                        .stroke(reached ? AnyShapeStyle(LinearGradient(colors: [color, .mint], startPoint: .top, endPoint: .bottom))
                                        : AnyShapeStyle(color),
                                style: StrokeStyle(lineWidth: reached ? 10 : 8, lineCap: .round))
                        .opacity(isLuminanceReduced ? 0.5 : 1)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut, value: steps)
                    VStack(spacing: 0) {
                        if reached {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(color)
                                .symbolEffect(.bounce, value: reached)
                        }
                        Text(steps.grouped)
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: steps)
                        Text(reached ? String(localized: "Goal reached") : String(localized: "\((goal - steps).grouped) to go"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: ringSize, height: ringSize)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(steps.grouped) of \(goal.grouped) steps")

                StatRow(items: [
                    .init(label: "Distance", value: distanceText),
                    .init(label: "kcal", value: store.today.kilocalories.grouped),
                ])

                if !store.hourlyStepsToday.isEmpty {
                    ChartHeader(title: "Today by hour", unit: String(localized: "steps"))
                    BarTrendChart(bars: store.hourlyStepsToday, color: color, unit: .hour,
                                  accessibilityName: String(localized: "Steps today by hour"),
                                  valueUnit: String(localized: "steps"))
                }

                ChartHeader(title: "Last 7 days", unit: String(localized: "steps"))
                BarTrendChart(bars: store.dailySteps, color: color, unit: .day,
                              accessibilityName: String(localized: "Steps, last 7 days"),
                              valueUnit: String(localized: "steps"), goal: Double(goal))

                Text("Steps counted by the ring. Your watch counts its own steps too; Health keeps whichever source you rank first.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Activity")
        .metricPage(.activity)
        // A tap on the wrist when the goal is reached while you're looking.
        .sensoryFeedback(.success, trigger: reached) { old, new in !old && new }
    }

    private var distanceText: String {
        Measurement(value: Double(store.today.distanceMeters), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
