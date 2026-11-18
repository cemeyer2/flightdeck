import Foundation
// The current charge session's curve (charge % and charge power over time), kept in memory only, plus the highest
// system draw seen since launch (for the weak-charger check). Fed every sample from the Engine's sampling queue and
// read by the view on the main thread, hence the lock. A session starts when external power is connected and stays
// readable after unplugging until the next plug-in. Points are thinned to keep memory bounded on long sessions.

public struct ChargePoint: Codable, Sendable, Hashable {
    public var time: Date
    public var percent: Double
    /// Battery power, W (+ charging).
    public var batteryW: Double?
    public init(time: Date, percent: Double, batteryW: Double?) { self.time = time; self.percent = percent; self.batteryW = batteryW }
}

public struct ChargeSessionCurve: Sendable, Hashable {
    public var start: Date
    /// Set when power was disconnected.
    public var end: Date?
    public var points: [ChargePoint]
    public init(start: Date, end: Date? = nil, points: [ChargePoint]) { self.start = start; self.end = end; self.points = points }

    /// `count` evenly spaced buckets from start to `now` (or end), each holding the last point that fell in it; empty
    /// buckets are nil, so a sleep shows as a gap rather than an interpolated line (HistoryGraph's convention).
    public func buckets(_ count: Int, now: Date, _ value: (ChargePoint) -> Double?) -> [Double?] {
        let span = max((end ?? now).timeIntervalSince(start), 1)
        var out = [Double?](repeating: nil, count: count)
        for p in points {
            let i = min(max(Int(p.time.timeIntervalSince(start) / span * Double(count)), 0), count - 1)
            out[i] = value(p)
        }
        return out
    }
}

public final class ChargeCurve: @unchecked Sendable {
    private let lock = NSLock()
    private var session: ChargeSessionCurve?
    private var peak: Double?
    private var lastPoint: Date?
    /// One point per this many seconds at most (the estimate's least-squares fit doesn't need more).
    public let spacing: TimeInterval
    public let maxPoints: Int

    public init(spacing: TimeInterval = 10, maxPoints: Int = 2000) { self.spacing = spacing; self.maxPoints = maxPoints }

    public func ingest(_ s: Snapshot) {
        let p = s.power
        lock.lock(); defer { lock.unlock() }
        if let w = p.systemWatts.value { peak = max(peak ?? 0, w) }
        guard let b = p.battery else { session = nil; return }   // no battery (desktop): no curve
        if !b.externalConnected {
            if session != nil, session?.end == nil { session?.end = s.time }
            return
        }
        if session == nil || session?.end != nil { session = ChargeSessionCurve(start: s.time, points: []); lastPoint = nil }
        if let l = lastPoint, s.time.timeIntervalSince(l) < spacing { return }
        lastPoint = s.time
        session?.points.append(ChargePoint(time: s.time, percent: b.percent, batteryW: p.batteryWatts.value))
        // Drop every other point once full, so a long session keeps its shape at half the resolution.
        if let pts = session?.points, pts.count > maxPoints { session?.points = pts.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
    }

    public var state: (session: ChargeSessionCurve?, peakSystemW: Double?) {
        lock.lock(); defer { lock.unlock() }
        return (session, peak)
    }
}
