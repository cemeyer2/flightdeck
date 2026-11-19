import Foundation
// `measure`: what the whole Mac did between two moments, from black-box frames. System totals come from cumulative
// counters where the frames have them (disk bytes per device, network bytes, per-process CPU time and energy), so
// they're exact however sparse the frames; levels (CPU %, memory, temperature) are statistics over the frames that
// measured them. Gaps (asleep, app not running) are reported, never filled with zeros. Pure: tested on synthetic traces.

/// System-wide numbers for one window.
public struct WindowMeasurement: Sendable {
    public var from: Date, to: Date
    /// Frames inside the window, and the trace's nominal seconds between frames.
    public var frames: Int
    public var interval: Double
    /// Seconds the frames cover (each frame stands for the time since the previous one, capped at a gap).
    public var recordedSeconds: Double
    /// Stretches with no frames longer than three intervals (start, seconds), including at either end.
    public var gaps: [(start: Date, seconds: Double)]
    /// CPU % of the whole machine (0–100).
    public var cpu: TraceStats.Stat?
    public var cpuUserAvg: Double?, cpuSystemAvg: Double?
    /// CPU seconds of the whole machine (all cores), integrated from CPU % × cores over the recorded time.
    public var systemCPUSeconds: Double?
    public var cores: Int?
    public var memoryUsed: TraceStats.Stat?
    public var memoryTotal: Double?
    public var pressure: TraceStats.Stat?
    public var swapStart: Double?, swapEnd: Double?, swapPeak: Double?
    /// Bytes over the window from the cumulative counters; nil when no two frames carried them.
    public var diskRead: Double?, diskWrite: Double?, netIn: Double?, netOut: Double?
    /// Energy from system power × time over the recorded time; nil when power wasn't measured.
    public var energyWh: Double?
    public var watts: TraceStats.Stat?
    public var batteryStart: Double?, batteryEnd: Double?
    public var hottest: TraceStats.Stat?
    public var gpu: TraceStats.Stat?
    /// Worst ProcessInfo thermal state seen (0 nominal … 3 critical), and seconds at "serious" or worse, where macOS
    /// slows the CPU and GPU to shed heat.
    public var worstThermalState: Int?
    public var throttledSeconds: Double
    public var processes: [ProcessIdentity: ProcessCost]
    public var appPeakMemory: [String: UInt64]

    public var seconds: Double { to.timeIntervalSince(from) }

    /// Measures [from, to] from `frames`, which may include a few frames before `from` (counter baselines only).
    public static func compute(_ all: [Snapshot], interval: Double, from: Date, to: Date) -> WindowMeasurement {
        let frames = all.filter { $0.time >= from && $0.time <= to }
        let gapAfter = max(interval, 0.5) * 3
        // Each frame stands for the time since the previous recorded frame (the baseline frame counts as previous),
        // except after a gap, where it stands for one interval: the time in between wasn't observed.
        let baseFrame = all.last { $0.time < from }
        var prev = baseFrame?.time
        var dts: [Double] = [], gaps: [(Date, Double)] = []
        for f in frames {
            let since = prev.map { f.time.timeIntervalSince(max($0, from)) } ?? f.time.timeIntervalSince(from)
            if since > gapAfter { gaps.append((prev.map { max($0, from) } ?? from, since)) }
            dts.append(since > gapAfter || since <= 0 ? min(interval, max(since, 0)) : since)
            prev = f.time
        }
        if let last = frames.last?.time, to.timeIntervalSince(last) > gapAfter { gaps.append((last, to.timeIntervalSince(last))) }
        if frames.isEmpty { gaps = [(from, to.timeIntervalSince(from))] }

        // Time-weighted integrals over recorded time only.
        func integral(_ v: (Snapshot) -> Double?) -> Double? {
            var sum = 0.0, any = false
            for (f, dt) in zip(frames, dts) { if let x = v(f) { sum += x * dt; any = true } }
            return any ? sum : nil
        }
        // Growth of a cumulative counter across consecutive frames (baseline frame included); decreases (reboot,
        // a device that went away and came back) contribute nothing rather than a negative.
        let withBase = (baseFrame.map { [$0] } ?? []) + frames
        func counter(_ v: (Snapshot) -> [String: Double]) -> Double? {
            var sum = 0.0, pairs = 0
            var last: [String: Double]?
            for f in withBase {
                let cur = v(f)
                if let last { for (k, x) in cur { if let y = last[k] { sum += max(x - y, 0); pairs += 1 } } }
                last = cur
            }
            return pairs > 0 ? sum : nil
        }
        let thermal = frames.map(\.power.thermalState)
        let battery = frames.compactMap { $0.power.battery?.percent }
        let swaps = frames.compactMap { $0.memory.swapUsed.value }
        let measuredMemory = frames.filter { $0.memory.total > 0 && $0.memory.used > 0 }
        let (costs, appPeak) = ProcessCosts.compute(all, from: from, to: to)
        return WindowMeasurement(
            from: from, to: to, frames: frames.count, interval: interval, recordedSeconds: dts.reduce(0, +), gaps: gaps,
            cpu: TraceStats.stat(frames.compactMap { $0.cpu.total.value }),
            cpuUserAvg: TraceStats.stat(frames.compactMap { $0.cpu.user.value })?.avg,
            cpuSystemAvg: TraceStats.stat(frames.compactMap { $0.cpu.system.value })?.avg,
            systemCPUSeconds: integral { f in f.cpu.total.value.flatMap { f.cpu.cores.isEmpty ? nil : $0 / 100 * Double(f.cpu.cores.count) } },
            cores: frames.last.flatMap { $0.cpu.cores.isEmpty ? nil : $0.cpu.cores.count },
            memoryUsed: TraceStats.stat(measuredMemory.map { Double($0.memory.used) }),
            memoryTotal: measuredMemory.last.map { Double($0.memory.total) },
            pressure: TraceStats.stat(frames.compactMap { $0.memory.pressure.value }),
            swapStart: swaps.first, swapEnd: swaps.last, swapPeak: swaps.max(),
            diskRead: counter { f in f.disk.devices.isEmpty ? [:] : Dictionary(f.disk.devices.map { ($0.name, Double($0.totalRead)) }, uniquingKeysWith: max) },
            diskWrite: counter { f in f.disk.devices.isEmpty ? [:] : Dictionary(f.disk.devices.map { ($0.name, Double($0.totalWritten)) }, uniquingKeysWith: max) },
            netIn: counter { f in f.network.inBps.value == nil ? [:] : ["all": Double(f.network.totalIn)] },
            netOut: counter { f in f.network.outBps.value == nil ? [:] : ["all": Double(f.network.totalOut)] },
            energyWh: integral { $0.power.systemWatts.value }.map { $0 / 3600 },
            watts: TraceStats.stat(frames.compactMap { $0.power.systemWatts.value }),
            batteryStart: battery.first, batteryEnd: battery.last,
            hottest: TraceStats.stat(frames.compactMap { $0.power.hottest.value }),
            gpu: TraceStats.stat(frames.compactMap { $0.gpu.value }),
            worstThermalState: thermal.max(),
            throttledSeconds: zip(frames, dts).reduce(0) { $0 + ($1.0.power.thermalState >= 2 ? $1.1 : 0) },
            processes: costs, appPeakMemory: appPeak)
    }
}

/// Process and app rankings for a measurement, and the cost of one process tree.
extension WindowMeasurement {
    /// A ranked process or app, by one of CPU seconds, peak memory, energy or disk bytes.
    public struct Ranked: Sendable { public var name: String; public var pid: Int32?; public var count: Int; public var value: Double }

    /// Top `n` processes by `metric`, largest first (processes without a reading are left out, not ranked as 0).
    public func topProcesses(_ metric: KeyPath<ProcessCost, Double?>, _ n: Int) -> [Ranked] {
        processes.values.compactMap { c in c[keyPath: metric].map { Ranked(name: c.name, pid: c.identity.pid, count: 1, value: $0) } }
            .filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(n).map { $0 }
    }
    public func topProcessesByMemory(_ n: Int) -> [Ranked] {
        processes.values.map { Ranked(name: $0.name, pid: $0.identity.pid, count: 1, value: Double($0.peakMemory)) }
            .filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(n).map { $0 }
    }
    /// Top `n` apps (helpers rolled up) by summed `metric`; `count` is how many processes contributed.
    public func topApps(_ metric: KeyPath<ProcessCost, Double?>, _ n: Int) -> [Ranked] {
        var by: [String: Ranked] = [:]
        for c in processes.values { guard let v = c[keyPath: metric] else { continue }
            by[c.appKey, default: Ranked(name: c.appName, pid: nil, count: 0, value: 0)].value += v
            by[c.appKey]!.count += 1
        }
        return by.values.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(n).map { $0 }
    }
    public func topAppsByMemory(_ n: Int) -> [Ranked] {
        var names: [String: String] = [:], counts: [String: Int] = [:]
        for c in processes.values { names[c.appKey] = c.appName; counts[c.appKey, default: 0] += 1 }
        return appPeakMemory.map { Ranked(name: names[$0.key] ?? $0.key, pid: nil, count: counts[$0.key] ?? 0, value: Double($0.value)) }
            .filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(n).map { $0 }
    }

    /// What one process tree (roots and every recorded descendant) cost in the window.
    public struct TreeCost: Sendable {
        public var processes: Int
        /// Processes that started inside the window (children spawned by the work).
        public var spawned: Int
        public var cpuSeconds: Double?
        public var peakMemory: UInt64
        public var energyJoules: Double?
        public var diskBytes: Double?
        public var first: Date?, last: Date?
        /// Members grouped by name, heaviest CPU first: (name, processes, CPU seconds).
        public var byName: [(name: String, count: Int, cpuSeconds: Double)]
    }

    public func tree(process: String?, app: String?, frames: [Snapshot]) -> TreeCost? {
        let roots = ProcessCosts.roots(processes, process: process, app: app)
        guard !roots.isEmpty else { return nil }
        let members = ProcessCosts.tree(processes, roots: roots)
        let cs = members.compactMap { processes[$0] }
        func sum(_ k: KeyPath<ProcessCost, Double?>) -> Double? {
            let v = cs.compactMap { $0[keyPath: k] }
            return v.isEmpty ? nil : v.reduce(0, +)
        }
        var names: [String: (Int, Double)] = [:]
        for c in cs { names[c.name, default: (0, 0)].0 += 1; names[c.name]!.1 += c.cpuSeconds ?? 0 }
        return TreeCost(processes: cs.count, spawned: cs.filter(\.startedInWindow).count, cpuSeconds: sum(\.cpuSeconds),
                        peakMemory: ProcessCosts.peakMemory(frames, members: members, from: from, to: to),
                        energyJoules: sum(\.energyJoules), diskBytes: sum(\.diskBytes),
                        first: cs.map(\.firstSeen).min(), last: cs.map(\.lastSeen).max(),
                        byName: names.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 })
    }
}
