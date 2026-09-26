import Foundation

/// The blood-chemistry estimates some rings report, with unit conversion for regions that
/// use mg/dL. These are optical estimates from a ring, not blood tests: they are hidden unless
/// the user opts in, never classified or colour-coded, and never written to Apple Health.
enum ChemistryMarker: CaseIterable, Identifiable, Sendable {
    case glucose, uricAcid, ketone, totalCholesterol, hdl, ldl, triglycerides

    var id: Self { self }

    var title: String {
        switch self {
        case .glucose: return String(localized: "Glucose")
        case .uricAcid: return String(localized: "Uric acid")
        case .ketone: return String(localized: "Ketone")
        case .totalCholesterol: return String(localized: "Cholesterol")
        case .hdl: return String(localized: "HDL")
        case .ldl: return String(localized: "LDL")
        case .triglycerides: return String(localized: "Triglycerides")
        }
    }

    func value(in sample: MetabolicSample) -> Double? {
        switch self {
        case .glucose: return sample.glucose
        case .uricAcid: return sample.uricAcid.map(Double.init)
        case .ketone: return sample.ketone
        case .totalCholesterol: return sample.totalCholesterol
        case .hdl: return sample.hdl
        case .ldl: return sample.ldl
        case .triglycerides: return sample.triglycerides
        }
    }

    /// Multiply the stored value (mmol/L, or µmol/L for uric acid) by this to get mg/dL.
    /// Ketones are reported in mmol/L everywhere.
    var milligramsPerDeciliterFactor: Double? {
        switch self {
        case .glucose: return 18.016
        case .uricAcid: return 1 / 59.48
        case .ketone: return nil
        case .totalCholesterol, .hdl, .ldl: return 38.67
        case .triglycerides: return 88.57
        }
    }

    /// The value and unit to display.
    func format(_ stored: Double, milligramsPerDeciliter: Bool) -> (value: String, unit: String) {
        if milligramsPerDeciliter, let factor = milligramsPerDeciliterFactor {
            let converted = stored * factor
            let digits = self == .uricAcid ? 1 : 0
            return (converted.formatted(.number.precision(.fractionLength(digits))), "mg/dL")
        }
        if self == .uricAcid {
            return (stored.formatted(.number.precision(.fractionLength(0))), "µmol/L")
        }
        return (stored.formatted(.number.precision(.fractionLength(1))), "mmol/L")
    }

    /// The one-off measurement that produces this marker, if the ring offers one.
    var measurement: MeasurementKind? {
        switch self {
        case .glucose: return .bloodGlucose
        case .uricAcid: return .uricAcid
        case .ketone: return .bloodKetone
        default: return nil
        }
    }
}
