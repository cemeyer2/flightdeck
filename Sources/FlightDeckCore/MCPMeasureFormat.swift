import Foundation
// Wording of `measure` results (MCPMeasureOutput.swift): the one-paragraph summary, the system block, the rankings,
// the process-tree block and the comparison. Values that weren't measured are "unavailable (…)", never 0.

extension MCPTools {
    static func stat(_ x: TraceStats.Stat?, _ f: (Double) -> JSON = F.r1, p95: Bool = true) -> JSON {
        guard let x else { return F.unavailable("not measured in this window") }
        return p95 ? ["avg": f(x.avg), "p95": f(x.p95), "peak": f(x.peak)] : ["avg": f(x.avg), "peak": f(x.peak)]
    }
    static func opt(_ v: Double?, _ f: (Double) -> JSON = F.r1, _ why: String = "not measured in this window") -> JSON { v.map(f) ?? F.unavailable(why) }
    static func cpuSeconds(_ s: Double) -> JSON { F.r1(s) }

    static func systemJSON(_ m: WindowMeasurement) -> JSON {
        let swapGrowth = m.swapEnd.flatMap { e in m.swapStart.map { e - $0 } }
        return .object(dropping: [
            ("cpu_percent", stat(m.cpu)),
            ("cpu_user_avg_percent", opt(m.cpuUserAvg)), ("cpu_system_avg_percent", opt(m.cpuSystemAvg)),
            ("cpu_seconds_all_cores", opt(m.systemCPUSeconds)), ("cores", m.cores.map(JSON.int)),
            ("memory_used", m.memoryUsed.map { s in ["avg": F.bytes(s.avg), "peak": F.bytes(s.peak), "installed": m.memoryTotal.map(F.bytes)] }
                ?? F.unavailable("not measured in this window")),
            ("memory_pressure_percent", stat(m.pressure, p95: false)),
            ("swap", swapGrowth.map { g in ["start": F.bytes(m.swapStart!), "end": F.bytes(m.swapEnd!), "growth": .str((g < 0 ? "-" : "+") + Fmt.bytes(abs(g))),
                                            "peak": F.bytes(m.swapPeak!)] } ?? F.unavailable("not measured in this window")),
            ("disk", ["read": opt(m.diskRead, F.bytes), "written": opt(m.diskWrite, F.bytes)]),
            ("network", ["received": opt(m.netIn, F.bytes), "sent": opt(m.netOut, F.bytes)]),
            ("energy_wh", opt(m.energyWh, F.r2, "system power isn't measured on this Mac")),
            ("system_watts", stat(m.watts, p95: false)),
            ("battery_percent", m.batteryStart.map { s in ["start": F.r1(s), "end": F.r1(m.batteryEnd!)] }),
            ("gpu_percent", stat(m.gpu, p95: false)),
            ("hottest_c", stat(m.hottest, p95: false)),
            ("thermal", m.worstThermalState.map { w in
                ["worst_state": F.thermal(w), "throttled": F.duration(m.throttledSeconds),
                 "about": w >= 2 ? "At \"serious\" or worse macOS slows the CPU and GPU to shed heat, so work takes longer." : nil] }),
        ])
    }

    /// Top 8 per measure. Rows are [name, pid (processes) or process count (apps), value].
    static func rankings(_ m: WindowMeasurement, apps: Bool) -> JSON {
        func rows(_ r: [WindowMeasurement.Ranked], _ f: (Double) -> JSON) -> JSON {
            r.isEmpty ? "none recorded" : .array(r.map { [.str($0.name), apps ? .int($0.count) : .int(Int($0.pid ?? 0)), f($0.value)] })
        }
        let n = 8
        return [
            "columns": apps ? ["app", "processes", "value"] : ["process", "pid", "value"],
            "by_cpu_seconds": rows(apps ? m.topApps(\.cpuSeconds, n) : m.topProcesses(\.cpuSeconds, n), cpuSeconds),
            "by_peak_memory": rows(apps ? m.topAppsByMemory(n) : m.topProcessesByMemory(n), F.bytes),
            "by_energy_wh": rows(apps ? m.topApps(\.energyJoules, n) : m.topProcesses(\.energyJoules, n)) { F.r2($0 / 3600) },
            "by_disk_bytes": rows(apps ? m.topApps(\.diskBytes, n) : m.topProcesses(\.diskBytes, n), F.bytes),
        ]
    }

    static func treeJSON(_ t: WindowMeasurement.TreeCost, _ m: WindowMeasurement, subject: String) -> JSON {
        let share = t.cpuSeconds.flatMap { c in m.systemCPUSeconds.flatMap { $0 > 0 ? min(c / $0 * 100, 100) : nil } }
        return .object(dropping: [
            ("subject", .str(subject)),
            ("processes_seen", .int(t.processes)), ("spawned_in_window", .int(t.spawned)),
            ("cpu_seconds", opt(t.cpuSeconds, cpuSeconds, "CPU counters not readable")),
            ("avg_cores_busy", t.cpuSeconds.map { F.r2($0 / max(m.recordedSeconds, 1)) }),
            ("share_of_mac_cpu_percent", share.map(F.r1)),
            ("peak_memory", F.bytes(Double(t.peakMemory))),
            ("energy_wh", opt(t.energyJoules.map { $0 / 3600 }, F.r2, "these processes don't report energy")),
            ("disk_bytes", opt(t.diskBytes, F.bytes, "disk counters not readable")),
            ("active", t.first.map { f in .str("\(F.time(f).string!) to \(F.time(t.last!).string!)") }),
            ("by_name", .array(t.byName.prefix(12).map { [.str($0.name), .int($0.count), cpuSeconds($0.cpuSeconds)] })),
            ("by_name_columns", ["name", "processes", "cpu_seconds"]),
        ])
    }

    static func comparisonJSON(_ d: [MetricDelta], context: [MetricDelta]?, subject: String, baseline: JSON, baselineCoverage: JSON, treeMissing: Bool) -> JSON {
        func fmt(_ key: String, _ v: Double) -> JSON {
            switch key {
            case "peak_memory", "swap_growth", "disk_bytes", "network_bytes": return F.bytes(v)
            case "energy_wh": return F.r2(v)
            default: return F.r1(v)
            }
        }
        func rows(_ d: [MetricDelta]) -> JSON {
            .array(d.map { x in [.str(x.key), fmt(x.key, x.current), fmt(x.key, x.baseline), x.percent.map(F.r1) ?? .null, .str(x.words)] })
        }
        // Whole-Mac figures that bear on fairness: load from other apps, heat, and the rest.
        let ctx = context?.filter { ["avg_cpu_percent", "hottest_c", "swap_growth", "network_bytes", "energy_wh"].contains($0.key) }
        return .object(dropping: [
            ("verdict", .str(treeMissing ? "Can't compare \(subject): no matching process was recorded in the baseline window." : MeasureCompare.verdict(d, subject: subject))),
            ("baseline_window", baseline), ("baseline_data", baselineCoverage),
            ("columns", ["figure", "this_window", "baseline", "change_percent", "verdict"]), ("rows", rows(d)),
            ("whole_mac", ctx.map { c in ["about": "Context: the whole Mac in each window. A big difference here (another app busy, more heat) can explain a change in the tree.",
                                          "rows": rows(c)] }),
            ("noise_band", .str("Changes under \(Int(MeasureCompare.relativeNoise))% or below a small absolute floor (1 s, 1 CPU-s, 50 MB, 10 MB of disk, 0.05 Wh, 2 °C) count as about the same.")),
        ])
    }

    static func measureSummary(_ m: WindowMeasurement, tree: WindowMeasurement.TreeCost?, subject: String) -> String {
        let d = F.duration(m.seconds).string!
        if let t = tree {
            var s = "Over \(d), \(subject) (\(t.processes) recorded process\(t.processes == 1 ? "" : "es"), \(t.spawned) started in the window)"
            if let c = t.cpuSeconds { s += " used \(String(format: "%.1f", c)) CPU-seconds (\(String(format: "%.1f", c / max(m.recordedSeconds, 1))) cores on average)" }
            s += ", peaked at \(Fmt.bytes(Double(t.peakMemory))) of memory"
            if let e = t.energyJoules { s += ", drew \(String(format: "%.2f", e / 3600)) Wh" }
            if let b = t.diskBytes { s += " and did \(Fmt.bytes(b)) of disk I/O" }
            return s + "."
        }
        var parts: [String] = []
        if let c = m.cpu { parts.append("averaged \(Int(c.avg.rounded()))% CPU (peak \(Int(c.peak.rounded()))%)") }
        if let u = m.memoryUsed { parts.append("used up to \(Fmt.bytes(u.peak)) of memory") }
        if let w = m.diskWrite { parts.append("wrote \(Fmt.bytes(w)) to disk") }
        if let e = m.energyWh { parts.append("drew \(String(format: "%.2f", e)) Wh") }
        var s = "Over \(d) the Mac " + (parts.isEmpty ? "recorded no measurable figures"
            : parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!) + "."
        if let top = m.topApps(\.cpuSeconds, 1).first { s += " Busiest app: \(top.name) (\(String(format: "%.0f", top.value)) CPU-s)." }
        if (m.worstThermalState ?? 0) >= 2 { s += " macOS was throttling for heat for \(F.duration(m.throttledSeconds).string!)." }
        return s
    }

    static func accuracyNote(fine: Bool, interval: Double, filtered: Bool) -> String {
        let every = fine ? "one frame per \(interval <= 1 ? "second" : "\(Int(interval)) s")" : "one frame per \(Int(interval)) s (the last hour has every sample)"
        return "From the black box: \(every), keeping the busiest 25 processes per frame. CPU time, energy and disk bytes come from each process's cumulative counters, so a process that was seen is counted in full up to its last sighting, even if it was seen once. Processes that lived less than about one sample interval, or were never among the busiest, are not seen, so process"
            + (filtered ? " and process-tree" : "") + " totals are lower bounds. Per-process network isn't included."
    }
}
