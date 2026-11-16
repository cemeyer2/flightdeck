import Foundation
// Fixed-length metric history for charts (the app's live views currently keep their own frame history in the Engine).
// It starts full of gaps, so a chart drawn from it shows empty history on the left rather than a line falling from zero.

/// Fixed-capacity history. `nil` entries are gaps (sampling stopped / unavailable) and are drawn as breaks.
public struct Series: Codable, Sendable {
    /// Oldest first; always exactly `capacity` entries.
    public private(set) var values: [Double?]
    /// Number of samples kept (120 by default, i.e. two minutes at a 1 s interval).
    public let capacity: Int

    public init(capacity: Int = 120) {
        self.capacity = capacity
        self.values = Array(repeating: nil, count: capacity)
    }

    /// Pushes one sample and drops the oldest, keeping the length fixed. Pass nil to record a gap
    /// (charts draw a break rather than interpolating across it).
    public mutating func append(_ v: Double?) {
        values.removeFirst()
        values.append(v)
    }
    /// Appends a measured value, or a gap when it was unavailable.
    public mutating func append(_ m: Measured<Double>) { append(m.value) }

    /// Most recent sample; nil if it was a gap.
    public var latest: Double? { values.last ?? nil }
    /// Largest non-gap value; 0 when the whole series is gaps, so treat it as a scale hint, not as data.
    public var maxValue: Double { values.compactMap { $0 }.max() ?? 0 }
}

/// Averages timestamped values into `buckets` equal slices of time. Slices with no samples are `nil`, so periods
/// without data (sleep, app not running) show as gaps in a graph instead of being squeezed out.
public func timeBuckets(_ points: [(Date, Double)], buckets n: Int, from: Date? = nil, to: Date? = nil) -> [Double?] {
    guard n > 0, let first = from ?? points.first?.0, let last = to ?? points.last?.0 else { return [] }
    let span = max(last.timeIntervalSince(first), 1)
    var sum = [Double](repeating: 0, count: n), count = [Int](repeating: 0, count: n)
    for (t, v) in points {
        let i = min(max(Int(t.timeIntervalSince(first) / span * Double(n)), 0), n - 1)
        sum[i] += v; count[i] += 1
    }
    return (0..<n).map { count[$0] > 0 ? sum[$0] / Double(count[$0]) : nil }
}
