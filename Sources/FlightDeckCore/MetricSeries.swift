import Foundation
// `query_metrics`: raw time series from the black box, downsampled onto a regular grid. Each grid slot summarises the
// frames that fall in it, by average (levels and rates) or maximum (temperature, process memory), and the output says
// which. A slot with no frame, or whose frames didn't measure the metric, is nil (JSON null): asleep or not recorded is
// not the same as zero. Pure: tested on synthetic frames.

public enum MetricSeries {
    public enum Agg: String, Sendable { case avg, max }

    /// One series: its name as asked for, unit, how slots are combined, and how to read it from a frame.
    public struct Metric: Sendable {
        public var name: String
        public var unit: String
        public var agg: Agg
        let read: @Sendable (Snapshot) -> Double?
    }

    static let mb = 1_048_576.0
    /// The system metrics, in the order the tool lists them.
    public static let systemNames = ["cpu", "cpu_user", "cpu_system", "memory_used", "memory_pressure", "swap", "disk_read", "disk_write",
                                     "net_in", "net_out", "watts", "hottest_c", "gpu", "battery_pct"]
    public static let processFields = ["cpu", "rss", "energy"]

    /// The metric for a name, or nil if unknown. Process metrics are `process:<pid or name>.<cpu|rss|energy>`; a name
    /// matches processes with that name exactly (case-insensitive) and sums them, so `process:clang.cpu` is all clangs.
    public static func metric(_ name: String) -> Metric? {
        switch name {
        case "cpu": return Metric(name: name, unit: "% of the whole Mac", agg: .avg) { $0.cpu.total.value }
        case "cpu_user": return Metric(name: name, unit: "% of the whole Mac", agg: .avg) { $0.cpu.user.value }
        case "cpu_system": return Metric(name: name, unit: "% of the whole Mac", agg: .avg) { $0.cpu.system.value }
        case "memory_used": return Metric(name: name, unit: "MB", agg: .avg) { $0.memory.used > 0 ? Double($0.memory.used) / mb : nil }
        case "memory_pressure": return Metric(name: name, unit: "%", agg: .avg) { $0.memory.pressure.value }
        case "swap": return Metric(name: name, unit: "MB", agg: .max) { $0.memory.swapUsed.value.map { $0 / mb } }
        case "disk_read": return Metric(name: name, unit: "KB/s", agg: .avg) { $0.disk.readBps.value.map { $0 / 1024 } }
        case "disk_write": return Metric(name: name, unit: "KB/s", agg: .avg) { $0.disk.writeBps.value.map { $0 / 1024 } }
        case "net_in": return Metric(name: name, unit: "KB/s", agg: .avg) { $0.network.inBps.value.map { $0 / 1024 } }
        case "net_out": return Metric(name: name, unit: "KB/s", agg: .avg) { $0.network.outBps.value.map { $0 / 1024 } }
        case "watts": return Metric(name: name, unit: "W (whole system)", agg: .avg) { $0.power.systemWatts.value }
        case "hottest_c": return Metric(name: name, unit: "°C", agg: .max) { $0.power.hottest.value }
        case "gpu": return Metric(name: name, unit: "%", agg: .avg) { $0.gpu.value }
        case "battery_pct": return Metric(name: name, unit: "%", agg: .avg) { $0.power.battery?.percent }
        default: break
        }
        guard name.hasPrefix("process:"), let dot = name.lastIndex(of: ".") else { return nil }
        let sel = String(name[name.index(name.startIndex, offsetBy: 8)..<dot]).trimmingCharacters(in: .whitespaces)
        let field = String(name[name.index(after: dot)...])
        guard !sel.isEmpty, processFields.contains(field) else { return nil }
        let pid = Int32(sel)
        // The processes a frame has for the selector; empty means "not recorded in this frame" (not running, or not
        // among the busiest processes the black box kept), which reads as nil, not 0.
        let pick: @Sendable (Snapshot) -> [ProcessSample] = { f in
            f.processes.filter { p in pid.map { p.pid == $0 } ?? (p.name.caseInsensitiveCompare(sel) == .orderedSame) }
        }
        switch field {
        case "cpu":
            return Metric(name: name, unit: "% of one core", agg: .avg) { f in
                let ps = pick(f).filter { !($0.restricted && $0.cpuTime == 0) }
                return ps.isEmpty ? nil : ps.reduce(0) { $0 + $1.cpu }
            }
        case "rss":
            return Metric(name: name, unit: "MB (footprint)", agg: .max) { f in
                let ps = pick(f)
                return ps.isEmpty ? nil : Double(ps.reduce(UInt64(0)) { $0 + $1.memory }) / mb
            }
        default:
            return Metric(name: name, unit: "W", agg: .avg) { f in
                let e = pick(f).compactMap(\.energyWatts)
                return e.isEmpty ? nil : e.reduce(0, +)
            }
        }
    }

    /// Steps a model is likely to ask for, smallest first; the automatic step is the smallest that fits.
    public static let niceSteps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    /// The smallest nice step at least `minStep` (the tier's sampling interval) that gives at most `maxPoints` slots.
    public static func autoStep(span: Double, minStep: Double, maxPoints: Int) -> Double {
        niceSteps.first { $0 >= minStep - 0.01 && (span / $0).rounded(.up) <= Double(maxPoints) } ?? max(span / Double(maxPoints), minStep).rounded(.up)
    }

    /// Slots of width `step` starting at `from`, `count` of them, for each metric. Frames outside the grid are ignored.
    public static func series(_ frames: [Snapshot], metrics: [Metric], from: Date, step: Double, count: Int) -> [[Double?]] {
        var sums = [[Double]](repeating: [Double](repeating: 0, count: count), count: metrics.count)
        var ns = [[Int]](repeating: [Int](repeating: 0, count: count), count: metrics.count)
        var maxes = [[Double]](repeating: [Double](repeating: -.infinity, count: count), count: metrics.count)
        for f in frames {
            let off = f.time.timeIntervalSince(from)
            guard off >= 0 else { continue }
            let i = Int(off / step)
            guard i < count else { continue }
            for (k, m) in metrics.enumerated() {
                guard let v = m.read(f), v.isFinite else { continue }
                sums[k][i] += v; ns[k][i] += 1; maxes[k][i] = max(maxes[k][i], v)
            }
        }
        return metrics.indices.map { k in
            (0..<count).map { i in ns[k][i] == 0 ? nil : (metrics[k].agg == .max ? maxes[k][i] : sums[k][i] / Double(ns[k][i])) }
        }
    }
}
