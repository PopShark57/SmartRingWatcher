import SwiftUI

struct HeartRateView: View {
    @EnvironmentObject private var store: HealthDataStore

    private var day: [HeartRateSample] { store.last24h(store.heartRate) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestHeartRate {
                    HeroValue(style: .heartRate, value: "\(latest.value)", unit: "BPM",
                              date: latest.date, caption: zone(for: latest.value))
                } else {
                    NoDataView(style: .heartRate)
                }

                if !day.isEmpty {
                    TrendChart(points: day.chartPoints, color: MetricStyle.heartRate.color)
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

                MeasureButton(kind: .heartRate)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Heart Rate")
    }

    private func zone(for bpm: Int) -> String {
        switch bpm {
        case ..<60: return "Low"
        case ..<100: return "Normal"
        case ..<130: return "Elevated"
        default: return "High"
        }
    }
}

struct HRVView: View {
    @EnvironmentObject private var store: HealthDataStore

    private var day: [HRVSample] { store.last24h(store.hrv) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestHRV {
                    HeroValue(style: .hrv, value: latest.value.noDecimals, unit: "ms", date: latest.date)
                } else {
                    NoDataView(style: .hrv)
                }

                if !day.isEmpty {
                    TrendChart(points: day.map { ChartPoint(date: $0.date, value: $0.milliseconds) },
                               color: MetricStyle.hrv.color)
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

                Text("Higher HRV generally indicates better recovery. Compare against your own baseline.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("HRV")
    }
}
