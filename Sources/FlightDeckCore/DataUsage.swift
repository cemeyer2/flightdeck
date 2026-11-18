import Foundation

// Per-app internet data usage per day, from the cumulative per-process byte counters ProcessNetworkSampler keeps
// from nettop. DailyLog runs `NetUsageCounter.pass` in its existing 10 s per-app pass (O(processes), no extra
// sampling) and adds the deltas to the open day's `DataUsageTally`; the day's `DayRecord.dataUsage` is the result.
//
// Only bytes moved while FlightDeck runs are counted: the counters start at zero when FlightDeck starts watching,
// and nothing is known about traffic before that (or while it isn't running). Loopback traffic between processes
// on this Mac shows up in nettop too, so "data usage" is all traffic nettop attributes to the app.

/// One app's bytes on one day.
public struct AppNetDay: Codable, Sendable, Hashable, Identifiable {
    /// `AppUsage` grouping key: bundle path, or "proc:<name>".
    public var id: String
    public var name: String
    public var bytesIn: UInt64 = 0
    public var bytesOut: UInt64 = 0
    public init(id: String, name: String, bytesIn: UInt64 = 0, bytesOut: UInt64 = 0) {
        self.id = id; self.name = name; self.bytesIn = bytesIn; self.bytesOut = bytesOut
    }
    public var total: UInt64 { bytesIn + bytesOut }
}

/// One day's data usage. Present on a `DayRecord` only for days nettop data was available at least once.
public struct DataUsageDay: Codable, Sendable, Hashable {
    /// Busiest apps, by total bytes (trimmed when the day closes).
    public var apps: [AppNetDay]
    /// Every app's bytes, counted before trimming, so the day total stays exact.
    public var totalIn: UInt64
    public var totalOut: UInt64
    /// Seconds of the day that were counted (passes with nettop data), and when counting first started.
    public var countedSeconds: Double
    public var firstCounted: Date?
    public init(apps: [AppNetDay], totalIn: UInt64, totalOut: UInt64, countedSeconds: Double, firstCounted: Date?) {
        self.apps = apps; self.totalIn = totalIn; self.totalOut = totalOut; self.countedSeconds = countedSeconds; self.firstCounted = firstCounted
    }
    public var total: UInt64 { totalIn + totalOut }
}

/// Turns cumulative per-process totals into per-app byte deltas between passes. Keyed by `ProcessIdentity`
/// (PID + start time), so a restarted app or a reused PID is a new process whose counter starts again.
struct NetUsageCounter: Sendable {
    struct Delta: Sendable, Equatable { var name: String; var bytesIn: UInt64; var bytesOut: UInt64 }
    /// (in, out) totals per process at the previous pass.
    private(set) var prev: [ProcessIdentity: (UInt64, UInt64)] = [:]

    /// Per-app deltas since the previous pass, or nil when the snapshot carries no network data at all (nettop
    /// unavailable or warming up). Then nothing is counted and the baselines are kept: the sampler's totals keep
    /// growing meanwhile, so the next good pass picks up what happened in between.
    /// A process seen for the first time counts from zero, because the sampler's totals themselves start at zero when
    /// FlightDeck begins watching (unlike CPU time, which is cumulative since the process started).
    /// A total lower than last time means the counter restarted (the sampler dropped and re-created it), so the
    /// whole new value is new traffic, as for a new process.
    mutating func pass(_ procs: [ProcessSample], keys: [(key: String, name: String, icon: String)]) -> [String: Delta]? {
        guard procs.contains(where: { $0.network != nil }) else { return nil }
        var out: [String: Delta] = [:]
        var next: [ProcessIdentity: (UInt64, UInt64)] = [:]
        next.reserveCapacity(procs.count)
        for (p, k) in zip(procs, keys) {
            guard let n = p.network else { continue }
            let (pi, po) = prev[p.identity] ?? (0, 0)
            let dIn = n.totalIn >= pi ? n.totalIn - pi : n.totalIn
            let dOut = n.totalOut >= po ? n.totalOut - po : n.totalOut
            next[p.identity] = (n.totalIn, n.totalOut)
            guard dIn > 0 || dOut > 0 else { continue }
            var d = out[k.key] ?? Delta(name: k.name, bytesIn: 0, bytesOut: 0)
            d.bytesIn += dIn; d.bytesOut += dOut
            out[k.key] = d
        }
        // Exited processes drop out here, so `prev` stays O(live processes).
        prev = next
        return out
    }
}

/// The open day's running data-usage sums. `day(keep:)` produces the `DataUsageDay` to store.
struct DataUsageTally: Sendable {
    var apps: [String: AppNetDay] = [:]
    var totalIn: UInt64 = 0, totalOut: UInt64 = 0
    var countedSeconds = 0.0
    var firstCounted: Date?

    init() {}
    /// Continues a saved day (FlightDeck relaunched the same day).
    init(_ d: DataUsageDay?) {
        guard let d else { return }
        apps = Dictionary(d.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        totalIn = d.totalIn; totalOut = d.totalOut; countedSeconds = d.countedSeconds; firstCounted = d.firstCounted
    }

    /// Adds one pass's deltas. `seconds` is the pass interval when it was a normal step (0 across a gap).
    mutating func add(_ deltas: [String: NetUsageCounter.Delta], seconds: Double, at t: Date) {
        if firstCounted == nil { firstCounted = t }
        countedSeconds += seconds
        for (id, d) in deltas {
            var a = apps[id] ?? AppNetDay(id: id, name: d.name)
            a.bytesIn += d.bytesIn; a.bytesOut += d.bytesOut
            apps[id] = a
            totalIn += d.bytesIn; totalOut += d.bytesOut
        }
    }

    /// nil when nothing was ever counted this day (not measured, rather than zero). Apps sorted by total, top `keep`.
    func day(keep: Int) -> DataUsageDay? {
        guard firstCounted != nil else { return nil }
        let sorted = apps.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
        return DataUsageDay(apps: Array(sorted.prefix(keep)), totalIn: totalIn, totalOut: totalOut,
                            countedSeconds: countedSeconds, firstCounted: firstCounted)
    }
}
