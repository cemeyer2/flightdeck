import Foundation

public struct ProcessNetwork: Codable, Sendable, Hashable {
    public var inBps: Double
    public var outBps: Double
    public var totalIn: UInt64     // since Meterline started observing
    public var totalOut: UInt64
    public var connections: Int
}

/// Per-process network traffic from `/usr/bin/nettop` (which holds Apple's private network-statistics
/// entitlement, so it sees every process without root). One snapshot per sample; rates come from
/// per-connection deltas, so a connection closing never produces a negative or fake drop.
/// Limits: bytes a connection moves after the last snapshot before it closes, and connections that open
/// and close entirely between two snapshots, are not counted.
public final class ProcessNetworkSampler {
    struct Key: Hashable { var pid: Int32; var flow: Substring }
    private var prev: [Key: (UInt64, UInt64)] = [:]
    private var totals: [Int32: (UInt64, UInt64)] = [:]
    private var lastTime: Date?
    public private(set) var lastError: String?
    public init() {}

    /// Parses `nettop -L 1 -x -n -J bytes_in,bytes_out` output into per-connection counters.
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
    public func sample() -> [Int32: ProcessNetwork]? {
        guard let out = Shell.run("/usr/bin/nettop", ["-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"], timeout: 3),
              out.hasPrefix(",bytes_in") else {
            lastError = "nettop unavailable"; prev = [:]; lastTime = nil
            return nil
        }
        lastError = nil
        let now = Date()
        let cur = Self.parse(out)
        defer { prev = cur; lastTime = now }
        guard let lastTime, !prev.isEmpty else { return nil }
        let dt = max(now.timeIntervalSince(lastTime), 0.001)
        var delta: [Int32: (UInt64, UInt64, Int)] = [:]
        for (k, v) in cur {
            var d = v
            if let p = prev[k] {
                // counters only grow for a live connection; a smaller value means the tuple was reused
                d = (v.0 >= p.0 ? v.0 - p.0 : v.0, v.1 >= p.1 ? v.1 - p.1 : v.1)
            }
            let e = delta[k.pid] ?? (0, 0, 0)
            delta[k.pid] = (e.0 + d.0, e.1 + d.1, e.2 + 1)
        }
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
    public func retain(pids: Set<Int32>) { totals = totals.filter { pids.contains($0.key) } }
}
