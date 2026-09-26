import SwiftUI

struct BloodPressureView: View {
    @Environment(HealthDataStore.self) private var store

    var body: some View {
        let recent = store.bloodPressureDay
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestBloodPressure {
                    HeroValue(style: .bloodPressure,
                              value: "\(latest.value.systolic)/\(latest.value.diastolic)",
                              unit: "mmHg", date: latest.date,
                              caption: Self.category(systolic: latest.value.systolic, diastolic: latest.value.diastolic))
                    if let hr = latest.value.heartRate {
                        DetailRow(label: "Pulse", value: "\(hr) BPM")
                    }
                } else {
                    NoDataView(style: .bloodPressure)
                }

                if !recent.isEmpty {
                    ChartHeader(title: "Last 24 hours", unit: "mmHg")
                    BloodPressureChart(samples: recent)
                    StatRow(items: [
                        .init(label: "Avg SYS", value: "\(recent.map(\.systolic).reduce(0, +) / recent.count)"),
                        .init(label: "Avg DIA", value: "\(recent.map(\.diastolic).reduce(0, +) / recent.count)"),
                    ])
                }

                MeasureButton(kind: .bloodPressure, latest: store.latestBloodPressure.map {
                    Reading(value: "\($0.value.systolic)/\($0.value.diastolic)", date: $0.date)
                })

                Text("Cuffless ring readings are estimates and not a medical device measurement. Dashed lines mark 120 and 80 mmHg.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Blood Pressure")
        .metricPage(.bloodPressure)
    }

    /// ACC/AHA categories (2017, unchanged in 2025), worded for a cuffless estimate.
    static func category(systolic: Int, diastolic: Int) -> String {
        if systolic > 180 || diastolic > 120 { return String(localized: "Very high: re-measure with a cuff") }
        if systolic >= 140 || diastolic >= 90 { return String(localized: "High (stage 2)") }
        if systolic >= 130 || diastolic >= 80 { return String(localized: "High (stage 1)") }
        if systolic >= 120 { return String(localized: "Elevated") }
        return String(localized: "Normal")
    }
}

struct BloodOxygenView: View {
    @Environment(HealthDataStore.self) private var store

    var body: some View {
        let recent = store.bloodOxygenDay
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestBloodOxygen {
                    HeroValue(style: .bloodOxygen, value: "\(latest.value)", unit: "%", date: latest.date,
                              caption: latest.value >= 95 ? String(localized: "Normal")
                                : (latest.value >= 90 ? String(localized: "Low") : String(localized: "Very low")))
                } else {
                    NoDataView(style: .bloodOxygen)
                }

                if !recent.isEmpty {
                    ChartHeader(title: "Last 24 hours", unit: "%")
                    TrendChart(points: recent.map { ChartPoint(date: $0.date, value: Double($0.percent)) },
                               color: MetricStyle.bloodOxygen.color,
                               accessibilityName: String(localized: "Blood oxygen, last 24 hours"), unit: "%",
                               yDomain: 85...100, normalRange: 95...100)
                    let values = recent.map(\.percent)
                    StatRow(items: [
                        .init(label: "Min", value: "\(values.min() ?? 0)%"),
                        .init(label: "Avg", value: "\(values.reduce(0, +) / values.count)%"),
                    ])
                }

                MeasureButton(kind: .bloodOxygen,
                              latest: store.latestBloodOxygen.map { Reading(value: "\($0.value)%", date: $0.date) })
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Blood Oxygen")
        .metricPage(.bloodOxygen)
    }
}

struct TemperatureView: View {
    @Environment(HealthDataStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let recent = store.temperatureDay
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestTemperature {
                    HeroValue(style: .temperature, value: settings.formatTemperature(latest.value), date: latest.date)
                } else {
                    NoDataView(style: .temperature)
                }

                if !recent.isEmpty {
                    ChartHeader(title: "Last 24 hours", unit: settings.temperatureUnitSymbol)
                    TrendChart(points: recent.map { ChartPoint(date: $0.date, value: settings.temperatureValue($0.celsius)) },
                               color: MetricStyle.temperature.color,
                               accessibilityName: String(localized: "Skin temperature, last 24 hours"),
                               unit: settings.temperatureUnitSymbol, valueFormat: { $0.oneDecimal })
                    let values = recent.map(\.celsius)
                    StatRow(items: [
                        .init(label: "Min", value: settings.formatTemperature(values.min() ?? 0)),
                        .init(label: "Max", value: settings.formatTemperature(values.max() ?? 0)),
                    ])
                }

                MeasureButton(kind: .temperature, latest: store.latestTemperature.map {
                    Reading(value: settings.formatTemperature($0.value), date: $0.date)
                })

                Text("Finger skin temperature runs lower than core body temperature; watch the trend.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Temperature")
        .metricPage(.temperature)
    }
}

struct RespirationView: View {
    @Environment(HealthDataStore.self) private var store

    var body: some View {
        let recent = store.respirationDay
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestRespiration {
                    HeroValue(style: .respiration, value: "\(latest.value)", unit: String(localized: "br/min"), date: latest.date)
                } else {
                    NoDataView(style: .respiration)
                }

                if !recent.isEmpty {
                    ChartHeader(title: "Last 24 hours", unit: String(localized: "br/min"))
                    TrendChart(points: recent.map { ChartPoint(date: $0.date, value: Double($0.breathsPerMinute)) },
                               color: MetricStyle.respiration.color,
                               accessibilityName: String(localized: "Respiration, last 24 hours"),
                               unit: String(localized: "breaths per minute"), normalRange: 12...20)
                }

                MeasureButton(kind: .respiratoryRate, latest: store.latestRespiration.map {
                    Reading(value: String(localized: "\($0.value) br/min"), date: $0.date)
                })

                Text("Typical adult resting range: 12–20 breaths per minute (shaded).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Respiration")
        .metricPage(.respiration)
    }
}

struct StressView: View {
    @Environment(HealthDataStore.self) private var store

    var body: some View {
        let recent = store.bodyMetricsDay
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestStress {
                    HeroValue(style: .stress, value: latest.value.oneDecimal, unit: "/ 10",
                              date: latest.date, caption: Self.level(for: latest.value))
                } else {
                    NoDataView(style: .stress)
                }

                let stressPoints = recent.compactMap { s in s.stress.map { ChartPoint(date: s.date, value: $0) } }
                if !stressPoints.isEmpty {
                    ChartHeader(title: "Last 24 hours", unit: "0–10")
                    TrendChart(points: stressPoints, color: MetricStyle.stress.color,
                               accessibilityName: String(localized: "Stress, last 24 hours"), unit: "",
                               yDomain: 0...10, valueFormat: { $0.oneDecimal })
                }

                if let metrics = store.latestBodyMetrics {
                    VStack(spacing: 4) {
                        if let hrvIndex = metrics.hrvIndex { DetailRow(label: "HRV index", value: "\(hrvIndex.oneDecimal) / 10") }
                        if let hrv = metrics.hrvMilliseconds, let kind = metrics.hrvKind {
                            DetailRow(label: "\(kind.displayName)", value: "\(hrv.noDecimals) ms")
                        }
                        if let fatigue = metrics.fatigue { DetailRow(label: "Fatigue", value: "\(fatigue.oneDecimal) / 10") }
                        if let bodyIndex = metrics.bodyIndex { DetailRow(label: "Body index", value: "\(bodyIndex.oneDecimal) / 10") }
                        if let balance = metrics.sympatheticBalance {
                            DetailRow(label: "Sympathetic balance", value: balance.signedOneDecimal)
                        }
                    }
                }

                Text("The ring scores stress 0–10 from heart-rate variability: the lower your HRV, the higher the score (and the HRV index). Under 3 relaxed, 3–5.9 normal, 6–7.9 medium, 8+ high.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Stress")
        .metricPage(.stress)
    }

    static func level(for value: Double) -> String {
        switch value {
        case ..<3: return String(localized: "Relaxed")
        case ..<6: return String(localized: "Normal")
        case ..<8: return String(localized: "Medium")
        default: return String(localized: "High")
        }
    }
}

/// Blood-chemistry estimates, shown only when the user opted in (Settings). Values are never
/// classified or colour-coded: no ring is authorized to measure these without a blood sample.
struct MetabolicView: View {
    @Environment(HealthDataStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var measurement: MeasurementKind = .bloodGlucose

    var body: some View {
        let mgdl = settings.usesMilligramsPerDeciliter
        ScrollView {
            VStack(spacing: 12) {
                Label("Experimental estimates. Not for diagnosis or treatment decisions.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let latest = store.latestMetabolic {
                    if let glucose = latest.glucose {
                        let shown = ChemistryMarker.glucose.format(glucose, milligramsPerDeciliter: mgdl)
                        HeroValue(style: .metabolic, value: shown.value, unit: shown.unit, date: latest.date,
                                  caption: String(localized: "Glucose (estimate)"), captionColor: .secondary)
                    }
                    VStack(spacing: 4) {
                        ForEach(ChemistryMarker.allCases.filter { $0 != .glucose }) { marker in
                            if let value = marker.value(in: latest) {
                                let shown = marker.format(value, milligramsPerDeciliter: mgdl)
                                DetailRow(label: "\(marker.title)", value: "\(shown.value) \(shown.unit)")
                            }
                        }
                    }
                    let glucosePoints = store.metabolic.compactMap { m in
                        m.glucose.map { ChartPoint(date: m.date, value: mgdl ? $0 * 18.016 : $0) }
                    }
                    if glucosePoints.count > 1 {
                        ChartHeader(title: "Glucose, last 14 days", unit: mgdl ? "mg/dL" : "mmol/L")
                        TrendChart(points: glucosePoints, color: .secondary,
                                   accessibilityName: String(localized: "Glucose estimates"),
                                   unit: mgdl ? "mg/dL" : "mmol/L", showsAverage: false,
                                   valueFormat: { mgdl ? $0.noDecimals : $0.oneDecimal })
                    }
                } else {
                    NoDataView(style: .metabolic)
                }

                Picker("Measure", selection: $measurement) {
                    Text("Glucose").tag(MeasurementKind.bloodGlucose)
                    Text("Uric acid").tag(MeasurementKind.uricAcid)
                    Text("Ketone").tag(MeasurementKind.bloodKetone)
                }
                .frame(height: 50)
                MeasureButton(kind: measurement, latest: latestReading(for: measurement, mgdl: mgdl))

                Text("Optical blood-chemistry values are rough estimates, not a substitute for a blood test. The FDA advises against relying on any smartwatch or ring that claims to measure blood glucose without piercing the skin.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Blood Chemistry")
        .metricPage(.metabolic)
    }

    private func latestReading(for kind: MeasurementKind, mgdl: Bool) -> Reading<String>? {
        guard let marker = ChemistryMarker.allCases.first(where: { $0.measurement == kind }),
              let sample = store.metabolic.last(where: { marker.value(in: $0) != nil }),
              let value = marker.value(in: sample) else { return nil }
        let shown = marker.format(value, milligramsPerDeciliter: mgdl)
        return Reading(value: "\(shown.value) \(shown.unit)", date: sample.date)
    }
}
