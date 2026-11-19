import Foundation
// What each process cost over a window of black-box frames, and process trees (a build tool and everything it
// spawned). Used by `measure` (WindowMeasure.swift). Pure functions of the frames, so they are tested on synthetic traces.
//
// Why cumulative counters: builds and test runners spawn hundreds of short-lived children (compilers, linkers, test
// workers). The black box keeps one frame per second for the last hour (one per 10 s beyond) and only the busiest 25
// processes per frame, so averaging per-frame CPU % would miss most of them. Each process carries its total CPU time,
// billed energy and disk bytes since it started; one sighting of a child that started inside the window is enough to
// charge it everything it used up to that moment, and two sightings bound everything in between exactly.
// What can't be seen: work after a process's last sighting, and processes that never appear in a frame (lived less
// than a sample interval, or never made the busiest-25 list). Totals are therefore lower bounds.

/// One process's use of the window.
public struct ProcessCost: Sendable {
    public var identity: ProcessIdentity
    public var name: String
    public var ppid: Int32
    /// App grouping (AppUsage.groupKeys) at its first sighting: bundle path or "proc:<name>", and the display name.
    public var appKey: String
    public var appName: String
    public var firstSeen: Date
    public var lastSeen: Date
    /// True if the process started inside the window, so all of its counters count.
    public var startedInWindow: Bool
    /// CPU seconds used in the window; nil when the kernel refused its counters (another user's process).
    public var cpuSeconds: Double?
    public var peakMemory: UInt64
    /// Billed energy in joules; nil when the process never reported energy.
    public var energyJoules: Double?
    /// Bytes read from plus written to storage; nil when its counters were unreadable.
    public var diskBytes: Double?
}

public enum ProcessCosts {
    /// Per-process costs over [from, to], plus each app's peak memory (the largest sum of its members' footprints in
    /// any one frame, which is what "the app used N GB at its peak" means). Frames before `from` are used only as
    /// baselines for counters (pass one or two, so a process running across `from` isn't charged for earlier work).
    public static func compute(_ frames: [Snapshot], from: Date, to: Date) -> (costs: [ProcessIdentity: ProcessCost], appPeak: [String: UInt64]) {
        // Counter values at the baseline (last pre-window sighting, else 0 for processes born in the window, else the
        // first sighting in the window) and at the latest sighting in the window.
        var base: [ProcessIdentity: (cpu: Double?, energy: Double?, disk: Double?)] = [:]
        var costs: [ProcessIdentity: ProcessCost] = [:]
        var appPeak: [String: UInt64] = [:]
        let fromMicros = UInt64(max(from.timeIntervalSince1970, 0) * 1e6)
        for f in frames where f.time <= to {
            let inWindow = f.time >= from
            var appSum: [String: UInt64] = [:]
            let keys = inWindow ? AppUsage.groupKeys(f.processes) : []
            for (i, p) in f.processes.enumerated() {
                let cpu: Double? = (p.restricted && p.cpuTime == 0) ? nil : p.cpuTime
                let disk: Double? = (p.restricted && p.diskRead == 0 && p.diskWritten == 0) ? nil : Double(p.diskRead + p.diskWritten)
                let counters = (cpu: cpu, energy: p.energyTotal, disk: disk)
                guard inWindow else { base[p.identity] = counters; continue }
                let k = keys[i]
                appSum[k.key, default: 0] += p.memory
                if var c = costs[p.identity] {
                    let b = base[p.identity]!
                    c.lastSeen = f.time
                    c.peakMemory = max(c.peakMemory, p.memory)
                    c.cpuSeconds = delta(cpu, b.cpu) ?? c.cpuSeconds
                    c.energyJoules = delta(p.energyTotal, b.energy) ?? c.energyJoules
                    c.diskBytes = delta(disk, b.disk) ?? c.diskBytes
                    costs[p.identity] = c
                    continue
                }
                // First sighting in the window. A process born inside it is charged from zero; one that was already
                // running is charged from its last pre-window value, or from now if it wasn't seen before the window.
                let born = p.identity.startTime >= fromMicros
                let b = base[p.identity] ?? (born ? (cpu: cpu.map { _ in 0 }, energy: p.energyTotal.map { _ in 0 }, disk: disk.map { _ in 0 }) : counters)
                base[p.identity] = b
                costs[p.identity] = ProcessCost(
                    identity: p.identity, name: p.name, ppid: p.ppid, appKey: k.key, appName: k.name, firstSeen: f.time, lastSeen: f.time,
                    startedInWindow: born, cpuSeconds: delta(cpu, b.cpu), peakMemory: p.memory,
                    energyJoules: delta(p.energyTotal, b.energy), diskBytes: delta(disk, b.disk))
            }
            for (k, v) in appSum { appPeak[k] = max(appPeak[k] ?? 0, v) }
        }
        return (costs, appPeak)
    }

    /// Counter growth since the baseline; a counter that went down (shouldn't happen) counts as no growth, and a
    /// counter without a baseline (it became readable mid-window) isn't charged at all.
    static func delta(_ now: Double?, _ base: Double?) -> Double? {
        guard let now, let base else { return nil }
        return max(now - base, 0)
    }

    /// Every process in `costs` that is one of `roots` or descends from one. The parent of a process is the process
    /// with its parent PID that had started before it (PIDs are reused; the start time disambiguates). A parent that
    /// was never recorded breaks the chain, so a grandchild whose parent never appeared in a frame isn't attributed:
    /// another reason the tree's totals are a lower bound.
    public static func tree(_ costs: [ProcessIdentity: ProcessCost], roots: Set<ProcessIdentity>) -> Set<ProcessIdentity> {
        var byPID: [Int32: [ProcessIdentity]] = [:]
        for id in costs.keys { byPID[id.pid, default: []].append(id) }
        for k in byPID.keys { byPID[k]!.sort { $0.startTime < $1.startTime } }
        func parent(_ c: ProcessCost) -> ProcessIdentity? {
            guard c.ppid > 1, c.ppid != c.identity.pid else { return nil }   // launchd (1) and the kernel (0) adopt everything
            return byPID[c.ppid]?.last { $0.startTime <= c.identity.startTime }
        }
        var memo: [ProcessIdentity: Bool] = [:]
        func inTree(_ id: ProcessIdentity, depth: Int) -> Bool {
            if roots.contains(id) { return true }
            if let m = memo[id] { return m }
            guard depth < 64, let c = costs[id], let p = parent(c) else { memo[id] = false; return false }
            let r = inTree(p, depth: depth + 1)
            memo[id] = r
            return r
        }
        return Set(costs.keys.filter { inTree($0, depth: 0) })
    }

    /// The largest sum of `members`' footprints in any one frame in [from, to].
    public static func peakMemory(_ frames: [Snapshot], members: Set<ProcessIdentity>, from: Date, to: Date) -> UInt64 {
        var peak: UInt64 = 0
        for f in frames where f.time >= from && f.time <= to {
            var s: UInt64 = 0
            for p in f.processes where members.contains(p.identity) { s += p.memory }
            peak = max(peak, s)
        }
        return peak
    }

    /// Roots for a `process` filter: a PID, else processes whose name equals the text (case-insensitive), else whose
    /// name contains it. For an `app` filter: processes whose app name equals (else contains) the text.
    public static func roots(_ costs: [ProcessIdentity: ProcessCost], process: String?, app: String?) -> Set<ProcessIdentity> {
        if let process {
            let t = process.trimmingCharacters(in: .whitespaces)
            if let pid = Int32(t) { return Set(costs.keys.filter { $0.pid == pid }) }
            return match(costs, t) { $0.name }
        }
        if let app { return match(costs, app.trimmingCharacters(in: .whitespaces)) { $0.appName } }
        return []
    }

    private static func match(_ costs: [ProcessIdentity: ProcessCost], _ text: String, _ key: (ProcessCost) -> String) -> Set<ProcessIdentity> {
        let exact = costs.values.filter { key($0).caseInsensitiveCompare(text) == .orderedSame }
        if !exact.isEmpty { return Set(exact.map(\.identity)) }
        return Set(costs.values.filter { key($0).localizedCaseInsensitiveContains(text) }.map(\.identity))
    }
}
