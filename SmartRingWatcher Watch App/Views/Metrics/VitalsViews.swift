import SwiftUI

struct BloodPressureView: View {
    @EnvironmentObject private var store: HealthDataStore

    private var recent: [BloodPressureSample] { store.last24h(store.bloodPressure) }

    var body: some View {
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
                    BloodPressureChart(samples: recent)
                    StatRow(items: [
                        .init(label: "Avg SYS", value: "\(recent.map(\.systolic).reduce(0, +) / recent.count)"),
                        .init(label: "Avg DIA", value: "\(recent.map(\.diastolic).reduce(0, +) / recent.count)"),
                    ])
                }

                MeasureButton(kind: .bloodPressure)

                Text("Cuffless ring readings are estimates and not a medical device measurement.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Blood Pressure")
    }

    /// American Heart Association categories.
    static func category(systolic: Int, diastolic: Int) -> String {
        if systolic > 180 || diastolic > 120 { return "Hypertensive crisis" }
        if systolic >= 140 || diastolic >= 90 { return "High (stage 2)" }
        if systolic >= 130 || diastolic >= 80 { return "High (stage 1)" }
        if systolic >= 120 { return "Elevated" }
        return "Normal"
    }
}

struct BloodOxygenView: View {
    @EnvironmentObject private var store: HealthDataStore

    private var recent: [BloodOxygenSample] { store.last24h(store.bloodOxygen) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestBloodOxygen {
                    HeroValue(style: .bloodOxygen, value: "\(latest.value)", unit: "%", date: latest.date,
                              caption: latest.value >= 95 ? "Normal" : (latest.value >= 90 ? "Low" : "Very low"))
                } else {
                    NoDataView(style: .bloodOxygen)
                }

                if !recent.isEmpty {
                    TrendChart(points: recent.map { ChartPoint(date: $0.date, value: Double($0.percent)) },
                               color: MetricStyle.bloodOxygen.color, yDomain: 85...100)
                    let values = recent.map(\.percent)
                    StatRow(items: [
                        .init(label: "Min", value: "\(values.min() ?? 0)%"),
                        .init(label: "Avg", value: "\(values.reduce(0, +) / values.count)%"),
                    ])
                }

                MeasureButton(kind: .bloodOxygen)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Blood Oxygen")
    }
}

struct TemperatureView: View {
    @EnvironmentObject private var store: HealthDataStore
    @EnvironmentObject private var settings: AppSettings

    private var recent: [TemperatureSample] { store.last24h(store.temperature) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestTemperature {
                    HeroValue(style: .temperature, value: settings.formatTemperature(latest.value), date: latest.date)
                } else {
                    NoDataView(style: .temperature)
                }

                if !recent.isEmpty {
                    TrendChart(points: recent.map { ChartPoint(date: $0.date, value: display($0.celsius)) },
                               color: MetricStyle.temperature.color)
                    let values = recent.map(\.celsius)
                    StatRow(items: [
                        .init(label: "Min", value: settings.formatTemperature(values.min() ?? 0)),
                        .init(label: "Max", value: settings.formatTemperature(values.max() ?? 0)),
                    ])
                }

                MeasureButton(kind: .temperature)

                Text("Finger skin temperature runs lower than core body temperature; watch the trend.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Temperature")
    }

    private func display(_ celsius: Double) -> Double {
        settings.useFahrenheit ? celsius * 9 / 5 + 32 : celsius
    }
}

struct RespirationView: View {
    @EnvironmentObject private var store: HealthDataStore

    private var recent: [RespirationSample] { store.last24h(store.respiration) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestRespiration {
                    HeroValue(style: .respiration, value: "\(latest.value)", unit: "br/min", date: latest.date)
                } else {
                    NoDataView(style: .respiration)
                }

                if !recent.isEmpty {
                    TrendChart(points: recent.map { ChartPoint(date: $0.date, value: Double($0.breathsPerMinute)) },
                               color: MetricStyle.respiration.color)
                }

                MeasureButton(kind: .respiratoryRate)

                Text("Typical adult resting range: 12–20 breaths per minute.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Respiration")
    }
}

struct StressView: View {
    @EnvironmentObject private var store: HealthDataStore

    private var recent: [BodyMetricsSample] { store.last24h(store.bodyMetrics) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestStress {
                    HeroValue(style: .stress, value: latest.value.noDecimals, unit: "/ 100",
                              date: latest.date, caption: Self.level(for: latest.value))
                } else {
                    NoDataView(style: .stress)
                }

                let stressPoints = recent.compactMap { s in s.stress.map { ChartPoint(date: s.date, value: $0) } }
                if !stressPoints.isEmpty {
                    TrendChart(points: stressPoints, color: MetricStyle.stress.color, yDomain: 0...100)
                }

                if let metrics = store.latestBodyMetrics {
                    VStack(spacing: 4) {
                        if let fatigue = metrics.fatigue { DetailRow(label: "Fatigue", value: fatigue.noDecimals) }
                        if let energy = metrics.bodyEnergy { DetailRow(label: "Body energy", value: energy.noDecimals) }
                        if let sympathetic = metrics.sympathetic {
                            DetailRow(label: "Sympathetic", value: sympathetic.noDecimals)
                        }
                    }
                }

                Text("Stress is derived from heart-rate variability: 0–29 relaxed, 30–59 normal, 60–79 medium, 80+ high.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Stress")
    }

    static func level(for value: Double) -> String {
        switch value {
        case ..<30: return "Relaxed"
        case ..<60: return "Normal"
        case ..<80: return "Medium"
        default: return "High"
        }
    }
}

struct MetabolicView: View {
    @EnvironmentObject private var store: HealthDataStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let latest = store.latestMetabolic {
                    if let glucose = latest.glucose {
                        HeroValue(style: .metabolic, value: glucose.oneDecimal, unit: "mmol/L",
                                  date: latest.date, caption: "Blood glucose")
                    }
                    VStack(spacing: 4) {
                        if let uric = latest.uricAcid { DetailRow(label: "Uric acid", value: "\(uric) µmol/L") }
                        if let ketone = latest.ketone { DetailRow(label: "Ketone", value: "\(ketone.oneDecimal) mmol/L") }
                        if let tc = latest.totalCholesterol { DetailRow(label: "Cholesterol", value: "\(tc.oneDecimal) mmol/L") }
                        if let hdl = latest.hdl { DetailRow(label: "HDL", value: "\(hdl.oneDecimal) mmol/L") }
                        if let ldl = latest.ldl { DetailRow(label: "LDL", value: "\(ldl.oneDecimal) mmol/L") }
                        if let tg = latest.triglycerides { DetailRow(label: "Triglycerides", value: "\(tg.oneDecimal) mmol/L") }
                    }
                    let glucosePoints = store.metabolic.compactMap { m in m.glucose.map { ChartPoint(date: m.date, value: $0) } }
                    if glucosePoints.count > 1 {
                        TrendChart(points: glucosePoints, color: MetricStyle.metabolic.color)
                    }
                } else {
                    NoDataView(style: .metabolic)
                }

                MeasureButton(kind: .bloodGlucose)

                Text("Optical blood-chemistry values are rough estimates, not a substitute for a blood test.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Blood Chemistry")
    }
}
