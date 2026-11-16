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
