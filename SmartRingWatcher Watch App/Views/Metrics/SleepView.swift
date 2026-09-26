import SwiftUI

struct SleepView: View {
    @Environment(HealthDataStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let night = store.lastNightSleep {
                    HeroValue(style: .sleep, value: night.asleepSeconds.hoursMinutes,
                              caption: String(localized: "Score \(night.estimatedScore) (est.)"))
                    Text("\(night.date.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !night.stages.isEmpty {
                        SleepStagesChart(stages: night.stages)
                    }

                    VStack(spacing: 4) {
                        stageRow(.deep, night.deepSeconds, of: night)
                        stageRow(.light, night.lightSeconds, of: night)
                        stageRow(.rem, night.remSeconds, of: night)
                        stageRow(.awake, night.awakeSeconds, of: night)
                        DetailRow(label: "Times awake", value: "\(night.awakeCount)")
                        DetailRow(label: "In bed", value: night.inBedSeconds.hoursMinutes)
                    }

                    if store.weeklySleep.filter({ $0.value > 0 }).count > 1 {
                        ChartHeader(title: "Last 7 nights", unit: String(localized: "hours"))
                        BarTrendChart(bars: store.weeklySleep, color: MetricStyle.sleep.color, unit: .day,
                                      accessibilityName: String(localized: "Sleep, last 7 nights"),
                                      valueUnit: String(localized: "hours"), targetBand: 7...9,
                                      valueFormat: { $0.oneDecimal })
                    }
                } else {
                    NoDataView(style: .sleep, message: "No sleep recorded yet. Wear the ring overnight; sleep syncs in the morning.")
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Sleep")
        .metricPage(.sleep)
    }

    private func stageRow(_ kind: SleepStageKind, _ seconds: TimeInterval, of night: SleepSession) -> some View {
        let total = max(night.asleepSeconds + night.awakeSeconds, 1)
        return HStack {
            Circle()
                .fill(SleepStagesChart.color(for: kind))
                .frame(width: 8, height: 8)
            Text(kind.displayName)
                .foregroundStyle(.secondary)
            Spacer()
            Text(seconds.hoursMinutes)
                .monospacedDigit()
            Text((seconds / total).formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}
