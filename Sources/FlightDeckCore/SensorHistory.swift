import Foundation
// Per-sensor statistics since launch (minimum, average, maximum) and a short history for sparklines and the detail
// graph. The Engine's frame history only holds the last 2 minutes, and the black box isn't read for this, so the
// Thermals page keeps its own small store, fed once per actual sensor read (every 4 s, 10 s in the background).
//
// Cost: O(sensors) per read. Memory is bounded: `capacity` Float values per sensor (450 × 4 B ≈ 1.8 KB each, ~200 KB
// for an M1 Max's ~100 sensors) plus one shared time column. Sensors are keyed by CatalogSensor.id, and each family's
// hottest reading ("family:cpu") is tracked too, for the summary strip, the menu bar and alerts.

/// Running statistics for one sensor. `now` is the latest reading; nil once the sensor stopped reporting.
public struct SensorStats: Sendable, Equatable {
    public var now: Double?
    public var min: Double
    public var max: Double
    public var average: Double
    /// Readings folded in.
    public var count: Int
}

/// Accumulates min/max/mean without keeping every value. The mean is a running sum, which in Double stays exact
/// enough for millions of readings at the magnitudes involved (tens of °C).
struct RunningStats: Sendable, Equatable {
    var min = Double.infinity, max = -Double.infinity, sum = 0.0, count = 0
    mutating func add(_ v: Double) { min = Swift.min(min, v); max = Swift.max(max, v); sum += v; count += 1 }
    var mean: Double? { count > 0 ? sum / Double(count) : nil }
}

/// Thread-safe (internally locked): fed on the sampling queue, read by views and the MCP server on the main actor.
public final class SensorHistory: @unchecked Sendable {
    /// Points kept per sensor: 30 minutes at the 4 s sensor cadence.
    public let capacity: Int
    /// Two reads further apart than this (the Mac slept, sampling paused) get a gap point, so graphs break the line.
    static let gapAfter: TimeInterval = 30

    private struct Track {
        var stats = RunningStats()
        var latest: Double?
        var id: String
        var name: String
        /// Ring of the last `capacity` readings, aligned with `times`; NaN = no reading at that time.
        var ring: [Float]
    }
    private let lock = NSLock()
    /// Tracks in an array (with an id → position index) so each read updates the rings in place, without the
    /// copy-on-write copies that mutating a dictionary while iterating it would cause.
    private var tracks: [Track] = []
    private var index: [String: Int] = [:]
    /// Ring of read times, shared by every track. `head` is the next write position; `filled` the number of valid slots.
    private var times: [Date?]
    private var head = 0, filled = 0
    private var lastRead: Date?

    public init(capacity: Int = 450) {
        self.capacity = max(capacity, 2)
        times = Array(repeating: nil, count: self.capacity)
    }

    /// Folds in one snapshot's sensors if they come from a new read (`readAt` differs from the previous one); repeated
    /// values between reads are not counted again, so averages aren't weighted by the UI's sample rate. Returns
    /// whether anything was added.
    @discardableResult
    public func ingest(_ catalog: SensorCatalog, readAt: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = lastRead, readAt <= last { return false }
        if let last = lastRead, readAt.timeIntervalSince(last) > Self.gapAfter { advance(time: nil, values: [:]) }
        lastRead = readAt
        var values: [String: (String, Double)] = [:]
        for s in catalog.sensors { values[s.id] = (s.name, s.celsius) }
        for f in catalog.families { values["family:" + f.family.rawValue] = (f.family.short, f.max) }
        advance(time: readAt, values: values)
        return true
    }

    /// Writes one column: every known track gets its value or NaN; new sensors get a track (NaN-filled before now).
    /// Called with the lock held.
    private func advance(time: Date?, values: [String: (String, Double)]) {
        for (id, (name, _)) in values where index[id] == nil {
            index[id] = tracks.count
            tracks.append(Track(id: id, name: name, ring: Array(repeating: .nan, count: capacity)))
        }
        for i in tracks.indices {
            let v = values[tracks[i].id]?.1
            tracks[i].ring[head] = v.map(Float.init) ?? .nan
            tracks[i].latest = v
            if let v { tracks[i].stats.add(v) }
        }
        times[head] = time
        head = (head + 1) % capacity
        filled = min(filled + 1, capacity)
    }

    /// Statistics for one sensor id, or nil if it has never reported.
    public func stats(_ id: String) -> SensorStats? {
        lock.lock(); defer { lock.unlock() }
        return Self.stats(of: index[id].map { tracks[$0] })
    }

    /// Statistics for every sensor, keyed by id (one lock for a whole table render).
    public func allStats() -> [String: SensorStats] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: SensorStats] = [:]
        for t in tracks { out[t.id] = Self.stats(of: t) }
        return out
    }

    private static func stats(of t: Track?) -> SensorStats? {
        guard let t, let mean = t.stats.mean else { return nil }
        return SensorStats(now: t.latest, min: t.stats.min, max: t.stats.max, average: mean, count: t.stats.count)
    }

    /// The last `limit` points of one sensor, oldest first, nil for gaps and missing readings; empty if unknown.
    public func series(_ id: String, limit: Int? = nil) -> [Double?] {
        lock.lock(); defer { lock.unlock() }
        guard let i = index[id] else { return [] }
        let t = tracks[i]
        return order(limit).map { i in t.ring[i].isNaN ? nil : Double(t.ring[i]) }
    }

    /// The times of the points `series` returns (nil for gap points).
    public func times(limit: Int? = nil) -> [Date?] {
        lock.lock(); defer { lock.unlock() }
        return order(limit).map { times[$0] }
    }

    /// Ring indices oldest → newest, the last `limit` of them. Called with the lock held.
    private func order(_ limit: Int?) -> [Int] {
        let n = min(limit ?? filled, filled)
        return (0..<n).map { (head - n + $0 + capacity) % capacity }
    }

    /// Readings folded in so far (columns written, including gap columns).
    public var columns: Int { lock.lock(); defer { lock.unlock() }; return filled }

    /// Rebuilds statistics from recorded frames (replay: the stats then describe the replayed window, not this session).
    public static func from(frames: [Snapshot], chip: ChipFamily) -> SensorHistory {
        let h = SensorHistory(capacity: max(frames.count, 2))
        for f in frames {
            h.ingest(SensorCatalog.build(f.power, chip: chip), readAt: f.power.sensorsReadAt ?? f.time)
        }
        return h
    }
}
