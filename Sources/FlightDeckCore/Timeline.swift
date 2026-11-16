import Foundation
// Day-overview strip for the Flight Log: folds black-box frames into a fixed number of time buckets so a whole
// day (or any span) can be drawn as one row of bars, with empty buckets shown as gaps.

/// A day at a glance: frames folded into fixed time buckets. Buckets without samples are gaps
/// (the Mac was asleep, FlightDeck wasn't running, or sampling was paused), never zeros.
public struct TimelineBucket: Sendable, Identifiable {
    public var id: Int { index }
    /// Position of the bucket, 0 = earliest.
    public var index: Int
    public var start: Date
    /// Whole-machine CPU % (0..100): mean and peak over the bucket's frames. nil if no frame measured it.
    public var cpuAvg: Double?, cpuMax: Double?
    /// Mean memory pressure, 0..100.
    public var pressure: Double?
    /// Peak of the hottest sensor, °C (peak, because a brief spike is what matters for thermals).
    public var hottest: Double?
    /// Mean measured system power, watts.
    public var watts: Double?
    /// Frames that landed in this bucket. A bucket can have samples but nil metrics (frames without that reading).
    public var samples: Int
    public var isGap: Bool { samples == 0 }
}

/// Builds `TimelineBucket`s for the Flight Log view.
public enum Timeline {
    /// Splits [from, to] into `n` equal buckets and summarises the frames that fall in each. Frames outside the span
    /// are ignored. Each metric only averages frames that actually measured it, so an unavailable reading lowers
    /// nothing; a bucket with no frames at all comes back as a gap rather than zeros. `n` must be positive.
    public static func build(_ frames: [Snapshot], from: Date, to: Date, buckets n: Int) -> [TimelineBucket] {
        guard n > 0 else { return [] }
        // Floor of 1 s avoids a division by zero for an empty or inverted span.
        let span = max(to.timeIntervalSince(from), 1)
        var acc = [(cpu: [Double], pr: [Double], hot: [Double], w: [Double])](repeating: ([], [], [], []), count: n)
        var counts = [Int](repeating: 0, count: n)
        for f in frames {
            let i = Int(f.time.timeIntervalSince(from) / span * Double(n))
            guard i >= 0 && i < n else { continue }
            counts[i] += 1
            if let v = f.cpu.total.value { acc[i].cpu.append(v) }
            if let v = f.memory.pressure.value { acc[i].pr.append(v) }
            if let v = f.power.hottest.value { acc[i].hot.append(v) }
            if let v = f.power.systemWatts.value { acc[i].w.append(v) }
        }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        return (0..<n).map { i in
            TimelineBucket(index: i, start: from.addingTimeInterval(span * Double(i) / Double(n)),
                           cpuAvg: avg(acc[i].cpu), cpuMax: acc[i].cpu.max(), pressure: avg(acc[i].pr),
                           hottest: acc[i].hot.max(), watts: avg(acc[i].w), samples: counts[i])
        }
    }
}
