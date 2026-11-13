import Foundation

/// Fixed-capacity history. `nil` entries are gaps (sampling stopped / unavailable) and are drawn as breaks.
public struct Series: Codable, Sendable {
    public private(set) var values: [Double?]
    public let capacity: Int

    public init(capacity: Int = 120) {
        self.capacity = capacity
        self.values = Array(repeating: nil, count: capacity)
    }

    public mutating func append(_ v: Double?) {
        values.removeFirst()
        values.append(v)
    }
    public mutating func append(_ m: Measured<Double>) { append(m.value) }

    public var latest: Double? { values.last ?? nil }
    public var maxValue: Double { values.compactMap { $0 }.max() ?? 0 }
}
