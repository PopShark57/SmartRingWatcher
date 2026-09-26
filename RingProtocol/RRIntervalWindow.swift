import Foundation

/// A rolling window of RR intervals from the standard Heart Rate Measurement (0x2A37), for an
/// RMSSD that means something.
///
/// One notification usually carries one or two intervals, which is at most one successive
/// difference. Validation studies treat about 10 s as the shortest usable RMSSD recording and
/// 60 s as the more reliable "ultra-short" window, so this keeps 60 s of beats, drops
/// artifacts, and only reports RMSSD once enough clean beats have arrived.
struct RRIntervalWindow: Sendable {
    /// How much history to keep, in seconds.
    var duration: TimeInterval = 60
    /// Clean intervals needed before RMSSD is reported.
    var minimumBeats = 30
    /// Physiological bounds for one interval, in seconds (200–30 BPM).
    var plausibleInterval: ClosedRange<Double> = 0.3...2.0
    /// An interval that differs from the previous clean one by more than this fraction is an
    /// artifact (a missed or extra beat).
    var maximumJump = 0.2

    private struct Beat: Sendable {
        let time: Date
        let interval: Double
        /// True when the interval right before this one was also clean, so their difference counts.
        let followsCleanBeat: Bool
    }

    private var beats: [Beat] = []
    private var lastRawWasClean = false

    var beatCount: Int { beats.count }

    mutating func add(_ intervals: [Double], at time: Date) {
        for interval in intervals {
            let previous = lastRawWasClean ? beats.last?.interval : nil
            var clean = plausibleInterval.contains(interval)
            if clean, let reference = beats.last?.interval, abs(interval - reference) > reference * maximumJump {
                clean = false
            }
            if clean {
                beats.append(Beat(time: time, interval: interval, followsCleanBeat: previous != nil))
            }
            lastRawWasClean = clean
        }
        let cutoff = time.addingTimeInterval(-duration)
        if let firstKept = beats.firstIndex(where: { $0.time >= cutoff }) {
            beats.removeFirst(firstKept)
        } else {
            beats.removeAll()
        }
    }

    mutating func reset() {
        beats.removeAll()
        lastRawWasClean = false
    }

    /// RMSSD in milliseconds over the window, or nil until `minimumBeats` clean beats are in.
    var rmssd: Double? {
        guard beats.count >= minimumBeats else { return nil }
        var sum = 0.0
        var count = 0
        for k in 1..<beats.count where beats[k].followsCleanBeat {
            let d = (beats[k].interval - beats[k - 1].interval) * 1000
            sum += d * d
            count += 1
        }
        guard count >= minimumBeats / 2 else { return nil }
        return (sum / Double(count)).squareRoot()
    }
}
