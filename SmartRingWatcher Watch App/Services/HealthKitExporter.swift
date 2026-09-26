import Foundation
import HealthKit

/// Writes ring data to Apple Health (opt-in, Settings → Apple Health).
///
/// Every sample carries a sync identifier derived from its type and timestamp, so the ring
/// re-sending its whole history never creates duplicates, and an interval that grows (the
/// current hour's steps, a sleep session still being recorded) replaces the earlier copy via
/// a higher sync version.
///
/// Not exported: finger skin temperature (it is not body temperature), stress indices (no
/// HealthKit type), and blood chemistry (optical estimates; see the FDA's 2024 warning on
/// non-invasive glucose wearables).
@MainActor
final class HealthKitExporter {
    private let healthStore = HKHealthStore()
    private let log: DiagnosticsLog

    init(log: DiagnosticsLog) {
        self.log = log
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static let quantityTypes: [HKQuantityTypeIdentifier] = [
        .heartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate,
        .bloodPressureSystolic, .bloodPressureDiastolic,
        .stepCount, .distanceWalkingRunning, .activeEnergyBurned,
    ]

    private static var shareTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>(quantityTypes.map { HKQuantityType($0) })
        types.insert(HKCategoryType(.sleepAnalysis))
        return types
    }

    /// Asks for write access. Returns false when Health isn't available or the request failed;
    /// the user can still deny individual types, which are then skipped.
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await healthStore.requestAuthorization(toShare: Self.shareTypes, read: [])
            return true
        } catch {
            log.add("Health authorization failed: \(error.localizedDescription)", category: .store, isError: true)
            return false
        }
    }

    /// Exports everything currently cached (after the user turns the export on).
    func exportAll(from store: HealthDataStore, device: HKDevice?) async {
        var batch = HealthBatch()
        batch.heartRate = store.heartRate
        batch.bloodPressure = store.bloodPressure
        batch.bloodOxygen = store.bloodOxygen
        batch.respiration = store.respiration
        batch.bodyMetrics = store.bodyMetrics
        batch.activity = store.activity
        batch.sleep = store.sleep
        await export(batch, device: device)
    }

    func export(_ batch: HealthBatch, device: HKDevice?) async {
        guard isAvailable else { return }
        var byType: [HKObjectType: [HKObject]] = [:]
        func add(_ object: HKObject, as type: HKObjectType) { byType[type, default: []].append(object) }

        let perMinute = HKUnit.count().unitDivided(by: .minute())
        for sample in batch.heartRate {
            add(quantity(.heartRate, Double(sample.bpm), perMinute, at: sample.date, id: "hr", device: device),
                as: HKQuantityType(.heartRate))
        }
        // HealthKit's HRV type is SDNN specifically, so only the ring's SDNN goes there.
        for sample in batch.bodyMetrics {
            guard let sdnn = sample.sdnn, sdnn > 0 else { continue }
            add(quantity(.heartRateVariabilitySDNN, Double(sdnn), .secondUnit(with: .milli), at: sample.date,
                         id: "sdnn", device: device),
                as: HKQuantityType(.heartRateVariabilitySDNN))
        }
        for sample in batch.bloodOxygen {
            add(quantity(.oxygenSaturation, Double(sample.percent) / 100, .percent(), at: sample.date, id: "spo2", device: device),
                as: HKQuantityType(.oxygenSaturation))
        }
        for sample in batch.respiration {
            add(quantity(.respiratoryRate, Double(sample.breathsPerMinute), perMinute, at: sample.date, id: "resp", device: device),
                as: HKQuantityType(.respiratoryRate))
        }
        for sample in batch.bloodPressure {
            let mmHg = HKUnit.millimeterOfMercury()
            let systolic = quantity(.bloodPressureSystolic, Double(sample.systolic), mmHg, at: sample.date, id: nil, device: device)
            let diastolic = quantity(.bloodPressureDiastolic, Double(sample.diastolic), mmHg, at: sample.date, id: nil, device: device)
            let correlation = HKCorrelation(
                type: HKCorrelationType(.bloodPressure), start: sample.date, end: sample.date,
                objects: [systolic, diastolic], device: device,
                metadata: Self.metadata(id: "bp", date: sample.date, version: 1))
            add(correlation, as: HKQuantityType(.bloodPressureSystolic))
        }
        for interval in batch.activity {
            let end = max(interval.end, interval.date.addingTimeInterval(1))
            if interval.steps > 0 {
                add(quantity(.stepCount, Double(interval.steps), .count(), from: interval.date, to: end,
                             id: "steps", version: interval.steps, device: device),
                    as: HKQuantityType(.stepCount))
            }
            if interval.distanceMeters > 0 {
                add(quantity(.distanceWalkingRunning, Double(interval.distanceMeters), .meter(), from: interval.date, to: end,
                             id: "distance", version: interval.distanceMeters, device: device),
                    as: HKQuantityType(.distanceWalkingRunning))
            }
            if interval.kilocalories > 0 {
                add(quantity(.activeEnergyBurned, Double(interval.kilocalories), .kilocalorie(), from: interval.date, to: end,
                             id: "energy", version: interval.kilocalories, device: device),
                    as: HKQuantityType(.activeEnergyBurned))
            }
        }
        let sleepType = HKCategoryType(.sleepAnalysis)
        for session in batch.sleep {
            let minutes = Int(session.end.timeIntervalSince(session.date) / 60)
            add(HKCategorySample(type: sleepType, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                 start: session.date, end: max(session.end, session.date.addingTimeInterval(60)),
                                 device: device, metadata: Self.metadata(id: "inbed", date: session.date, version: max(1, minutes))),
                as: sleepType)
            for stage in session.stages where stage.duration > 0 {
                let value: HKCategoryValueSleepAnalysis
                switch stage.kind {
                case .deep: value = .asleepDeep
                case .light: value = .asleepCore
                case .rem: value = .asleepREM
                case .awake: value = .awake
                case .nap: value = .asleepUnspecified
                }
                add(HKCategorySample(type: sleepType, value: value.rawValue, start: stage.start, end: stage.end,
                                     device: device, metadata: Self.metadata(id: "sleep\(stage.kind.rawValue)", date: stage.start, version: 1)),
                    as: sleepType)
            }
        }

        var saved = 0
        for (type, objects) in byType {
            // Skip types the user declined; saving them would fail the whole batch.
            guard healthStore.authorizationStatus(for: type) == .sharingAuthorized else { continue }
            do {
                try await healthStore.save(objects)
                saved += objects.count
            } catch {
                log.add("Saving to Health failed (\(type.identifier)): \(error.localizedDescription)", category: .store, isError: true)
            }
        }
        if saved > 0 { log.add("Saved \(saved) samples to Health", category: .store) }
    }

    /// The ring as the source device of every sample.
    static func device(name: String?, deviceID: UUID?, info: DeviceInfo?, gattInfo: [String: String]) -> HKDevice {
        HKDevice(name: name ?? String(localized: "Smart ring"), manufacturer: gattInfo["Manufacturer"],
                 model: gattInfo["Model"], hardwareVersion: nil,
                 firmwareVersion: info?.firmwareVersion ?? gattInfo["Firmware"],
                 softwareVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                 localIdentifier: deviceID?.uuidString, udiDeviceIdentifier: nil)
    }

    private func quantity(_ identifier: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit, at date: Date,
                          id: String?, device: HKDevice?) -> HKQuantitySample {
        quantity(identifier, value, unit, from: date, to: date, id: id, version: 1, device: device)
    }

    private func quantity(_ identifier: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit, from start: Date,
                          to end: Date, id: String?, version: Int, device: HKDevice?) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(identifier), quantity: HKQuantity(unit: unit, doubleValue: value),
                         start: start, end: end, device: device,
                         metadata: id.map { Self.metadata(id: $0, date: start, version: version) })
    }

    private static func metadata(id: String, date: Date, version: Int) -> [String: Any] {
        [
            HKMetadataKeySyncIdentifier: "ring.\(id).\(Int(date.timeIntervalSince1970))",
            HKMetadataKeySyncVersion: NSNumber(value: version),
        ]
    }
}
