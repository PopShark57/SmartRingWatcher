import SwiftUI

struct HeartRateView: View {
    @Environment(HealthDataStore.self) private var store

    var body: some View {
        let day = store.heartRateDay
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestHeartRate {
                    // No "low/elevated" label: without knowing whether you were resting,
                    // exercising or asleep, a classification would often be wrong.
                    HeroValue(style: .heartRate, value: "\(latest.value)", unit: "BPM", date: latest.date)
                } else {
                    NoDataView(style: .heartRate)
                }

                if !day.isEmpty {
                    ChartHeader(title: "Last 24 hours", unit: "BPM")
                    TrendChart(points: day.chartPoints, color: MetricStyle.heartRate.color,
                               accessibilityName: String(localized: "Heart rate, last 24 hours"), unit: "BPM",
                               showsArea: true)
                    let values = day.map(\.bpm)
                    StatRow(items: [
                        .init(label: "Min", value: "\(values.min() ?? 0)"),
                        .init(label: "Avg", value: "\(values.reduce(0, +) / max(values.count, 1))"),
                        .init(label: "Max", value: "\(values.max() ?? 0)"),
                    ])
                }

                if let resting = store.restingHeartRate {
                    DetailRow(label: "Resting (est.)", value: "\(resting) BPM")
                }
                DetailRow(label: "Readings, 24 h", value: "\(day.count)")

                MeasureButton(kind: .heartRate,
                              latest: store.latestHeartRate.map { Reading(value: "\($0.value) BPM", date: $0.date) })

                Text("Resting is estimated from awake periods without walking; sleep is left out because it runs lower.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Heart Rate")
        .metricPage(.heartRate)
    }
}

struct HRVView: View {
    @Environment(HealthDataStore.self) private var store

    var body: some View {
        let day = store.hrvDay
        let kindName = store.hrvKind?.displayName ?? "HRV"
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestHRV {
                    HeroValue(style: .hrv, value: latest.value.noDecimals, unit: "ms", date: latest.date, caption: kindName)
                } else {
                    NoDataView(style: .hrv)
                }

                if !day.isEmpty {
                    ChartHeader(title: "\(kindName), last 24 hours", unit: "ms")
                    TrendChart(points: day.map { ChartPoint(date: $0.date, value: $0.milliseconds) },
                               color: MetricStyle.hrv.color,
                               accessibilityName: String(localized: "\(kindName), last 24 hours"), unit: "ms")
                    let values = day.map(\.milliseconds)
                    StatRow(items: [
                        .init(label: "Min", value: (values.min() ?? 0).noDecimals),
                        .init(label: "Avg", value: (values.reduce(0, +) / Double(max(values.count, 1))).noDecimals),
                        .init(label: "Max", value: (values.max() ?? 0).noDecimals),
                    ])
                }

                if let metrics = store.latestBodyMetrics {
                    VStack(spacing: 4) {
                        if let sdnn = metrics.sdnn { DetailRow(label: "SDNN", value: "\(sdnn) ms") }
                        if let rmssd = metrics.rmssd { DetailRow(label: "RMSSD", value: "\(rmssd) ms") }
                        if let pnn50 = metrics.pnn50 { DetailRow(label: "pNN50", value: "\(pnn50) %") }
                        if let ratio = metrics.lfHfRatio { DetailRow(label: "LF/HF", value: ratio.oneDecimal) }
                        if let vo2 = metrics.vo2max { DetailRow(label: "VO₂ max (est.)", value: "\(vo2)") }
                    }
                }

                Text("Higher HRV generally indicates better recovery. Compare against your own baseline. RMSSD and SDNN are different measures, so this page charts only one: \(kindName).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("HRV")
        .metricPage(.hrv)
    }
}
