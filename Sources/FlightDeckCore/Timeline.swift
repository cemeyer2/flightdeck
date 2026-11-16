import Foundation

/// A day at a glance: frames folded into fixed time buckets. Buckets without samples are gaps
/// (the Mac was asleep, FlightDeck wasn't running, or sampling was paused), never zeros.
public struct TimelineBucket: Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var start: Date
    public var cpuAvg: Double?, cpuMax: Double?
    public var pressure: Double?
    public var hottest: Double?
    public var watts: Double?
    public var samples: Int
    public var isGap: Bool { samples == 0 }
}

public enum Timeline {
    public static func build(_ frames: [Snapshot], from: Date, to: Date, buckets n: Int) -> [TimelineBucket] {
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
