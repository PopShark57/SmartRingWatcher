import SwiftUI

struct SleepView: View {
    @EnvironmentObject private var store: HealthDataStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let night = store.lastNightSleep {
                    HeroValue(style: .sleep, value: night.asleepSeconds.hoursMinutes,
                              caption: "Score \(night.estimatedScore) (est.)")
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

                    if weekly.count > 1 {
                        Text("Last 7 nights")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        BarTrendChart(bars: weekly, color: MetricStyle.sleep.color, unit: .day)
                    }
                } else {
                    NoDataView(style: .sleep, message: "No sleep recorded yet. Wear the ring overnight; sleep syncs in the morning.")
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Sleep")
    }

    /// Hours asleep per night, keyed by the day the night ended.
    private var weekly: [BarTrendChart.Bar] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        var byDay: [Date: Double] = [:]
        for session in store.sleep where session.end >= start {
            byDay[calendar.startOfDay(for: session.end), default: 0] += session.asleepSeconds / 3600
        }
        return byDay.map { BarTrendChart.Bar(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
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
            Text("\(Int((seconds / total * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .font(.footnote)
    }
}
