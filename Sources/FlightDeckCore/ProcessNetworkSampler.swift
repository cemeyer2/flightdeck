import Foundation

// Per-process network rates for the process table. Sampler (Snapshot.swift) calls sample() every tick on the sampling
// queue, gives every listed process a ProcessNetwork (0 when nettop saw no traffic for it), then calls retain(pids:).
/// One process's network activity over the last interval. Rates are bytes/s; totals are bytes; `connections` is the
/// number of flows nettop listed for it in this snapshot.
public struct ProcessNetwork: Codable, Sendable, Hashable {
    public var inBps: Double
    public var outBps: Double
    public var totalIn: UInt64     // since FlightDeck started observing
    public var totalOut: UInt64
    public var connections: Int
    public init(inBps: Double, outBps: Double, totalIn: UInt64, totalOut: UInt64, connections: Int) {
        self.inBps = inBps; self.outBps = outBps; self.totalIn = totalIn; self.totalOut = totalOut; self.connections = connections
    }
}

/// Per-process network traffic from `/usr/bin/nettop` (which holds Apple's private network-statistics
/// entitlement, so it sees every process without root). One snapshot per sample; rates come from
/// per-connection deltas, so a connection closing never produces a negative or fake drop.
/// Limits: bytes a connection moves after the last snapshot before it closes, and connections that open
/// and close entirely between two snapshots, are not counted.
public final class ProcessNetworkSampler {
    /// A flow is identified by its owning PID plus nettop's flow text ("tcp4 local<->remote"), which is unique per
    /// connection while it lives. Substring keeps the parse allocation-free; it retains the whole output string.
    struct Key: Hashable { var pid: Int32; var flow: Substring }
    /// Cumulative (in, out) bytes per flow from the previous snapshot.
    private var prev: [Key: (UInt64, UInt64)] = [:]
    /// Running (in, out) bytes per PID since FlightDeck began observing; pruned by retain(pids:).
    private var totals: [Int32: (UInt64, UInt64)] = [:]
    private var lastTime: Date?
    /// Set when nettop couldn't be run or produced unexpected output; nil after a good snapshot.
    public private(set) var lastError: String?
    /// One flow's movement in the last interval, for Destinations (DestinationTracker). Only flows that moved bytes or
    /// are new are listed; idle ones are left out so consumers do O(active flows) work.
    public struct FlowDelta: Sendable {
        public var pid: Int32
        /// nettop's flow text, "tcp4 local<->remote".
        public var flow: Substring
        public var bytesIn: UInt64, bytesOut: UInt64
        /// Not in the previous snapshot (opened this interval), or present in the first snapshot after a warm-up.
        public var opened: Bool
    }
    /// The flows of the latest `sample()` that returned rates; [] after a warm-up or failure. Same queue as `sample()`.
    public private(set) var lastFlows: [FlowDelta] = []
    /// The first delta run after a warm-up reports every flow as opened: the warm-up snapshot only set baselines, and
    /// the connections it saw were never reported to anyone.
    private var flowsPrimed = false
    public init() {}

    /// Parses `nettop -L 1 -x -n -J bytes_in,bytes_out` output into per-connection counters.
    /// The CSV alternates a process line ("name.pid,in,out,") with that process's flow lines ("proto a<->b,in,out,").
    /// The PID is taken after the last "." because process names may contain dots. Flow lines before any process line
    /// are ignored, and duplicate flow texts for one PID are summed. -x prints raw byte counts; -n skips DNS lookups.
    static func parse(_ out: String) -> [Key: (UInt64, UInt64)] {
        var flows: [Key: (UInt64, UInt64)] = [:]
        var pid: Int32?
        for line in out.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, !f[0].isEmpty else { continue }
            if f[0].contains("<->") {
                guard let pid else { continue }
                let k = Key(pid: pid, flow: f[0])
                let v = (UInt64(f[1]) ?? 0, UInt64(f[2]) ?? 0)
                if let e = flows[k] { flows[k] = (e.0 + v.0, e.1 + v.1) } else { flows[k] = v }
            } else if let dot = f[0].lastIndex(of: ".") {
                pid = Int32(f[0][f[0].index(after: dot)...])
            }
        }
        return flows
    }

    /// Returns nil when nettop is unavailable or still warming up (first snapshot has no deltas).
    /// nettop always prints the ",bytes_in" header first; anything else (missing binary, timeout, sandbox denial) is a
    /// failure. Dropping `prev` then makes the next good snapshot a fresh warm-up instead of diffing across a gap.
    public func sample() -> [Int32: ProcessNetwork]? {
        ingest(Shell.run("/usr/bin/nettop", ["-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"], timeout: 3), now: Date())
    }

    /// One nettop snapshot (`out`; nil if nettop couldn't run) taken at `now`. Split from `sample()` so tests can feed
    /// synthetic output.
    func ingest(_ out: String?, now: Date) -> [Int32: ProcessNetwork]? {
        guard let out, out.hasPrefix(",bytes_in") else {
            lastError = "nettop unavailable"; prev = [:]; lastTime = nil; lastFlows = []; flowsPrimed = false
            return nil
        }
        lastError = nil
        let cur = Self.parse(out)
        // The first good snapshot only primes `prev`: without a baseline there are no rates, so nil, never zeros.
        defer { prev = cur; lastTime = now }
        guard let lastTime, !prev.isEmpty else { lastFlows = []; flowsPrimed = false; return nil }
        let dt = max(now.timeIntervalSince(lastTime), 0.001)
        var delta: [Int32: (UInt64, UInt64, Int)] = [:]
        var flows: [FlowDelta] = []
        let allOpened = !flowsPrimed
        flowsPrimed = true
        for (k, v) in cur {
            var d = v
            // A flow absent from `prev` opened during this interval, so all of its bytes count toward this interval.
            let p = prev[k]
            if let p {
                // counters only grow for a live connection; a smaller value means the tuple was reused
                d = (v.0 >= p.0 ? v.0 - p.0 : v.0, v.1 >= p.1 ? v.1 - p.1 : v.1)
            }
            let e = delta[k.pid] ?? (0, 0, 0)
            delta[k.pid] = (e.0 + d.0, e.1 + d.1, e.2 + 1)
            if d.0 > 0 || d.1 > 0 || p == nil || allOpened {
                flows.append(FlowDelta(pid: k.pid, flow: k.flow, bytesIn: d.0, bytesOut: d.1, opened: p == nil || allOpened))
            }
        }
        lastFlows = flows
        var result: [Int32: ProcessNetwork] = [:]
        for (pid, d) in delta {
            let t = totals[pid] ?? (0, 0)
            let nt = (t.0 + d.0, t.1 + d.1)
            totals[pid] = nt
            result[pid] = ProcessNetwork(inBps: Double(d.0) / dt, outBps: Double(d.1) / dt,
                                         totalIn: nt.0, totalOut: nt.1, connections: d.2)
        }
        // keep totals for processes that are still alive but idle right now
        for (pid, t) in totals where result[pid] == nil {
            result[pid] = ProcessNetwork(inBps: 0, outBps: 0, totalIn: t.0, totalOut: t.1, connections: 0)
        }
        return result
    }

    /// Drop totals for exited processes.
    /// Totals are keyed by bare PID, so this runs every sample with the live PID set to stop a later process with a
    /// reused PID from inheriting old totals.
    public func retain(pids: Set<Int32>) { totals = totals.filter { pids.contains($0.key) } }

    /// The PID now belongs to a different process (reused): drop the old one's totals and per-connection baselines so
    /// the newcomer doesn't inherit them.
    public func forget(pid: Int32) { totals[pid] = nil; prev = prev.filter { $0.key.pid != pid } }
}
