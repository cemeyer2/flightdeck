import Foundation
// Turning a recorded `Trace` into something to read or share: summary statistics (flight report, Compare view, CLI)
// and CSV export. Both work only from the frames, so they give the same answers for live black-box spans and old files.

/// Summary statistics for a span of frames (flight report, CLI).
public struct TraceStats: Sendable {
    /// Mean, maximum and 95th percentile of one metric over the frames that measured it.
    public struct Stat: Sendable { public var avg: Double; public var peak: Double; public var p95: Double }
    public var start: Date, end: Date, frames: Int
    /// Units: cpu/gpu %, memoryUsedFraction 0..1, pressure 0..100, swap bytes, disk/net bytes/s, watts W, hottest °C.
    /// nil when no frame in the span measured that metric.
    public var cpu, memoryUsedFraction, pressure, swap, diskBps, netBps, watts, hottest, gpu: Stat?
    /// 0 nominal ... 3 critical (ProcessInfo.ThermalState raw values).
    public var worstThermalState: Int
    public var topCPU: [(name: String, avg: Double)]          // average % of one core over the span
    public var topMemory: [(name: String, peak: Double)]      // bytes
    public var findings: [Incident]                           // derived by replaying the analyzer

    /// p95 uses the lower nearest rank (index floor((n-1)·0.95)), no interpolation.
    static func stat(_ v: [Double]) -> Stat? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return Stat(avg: v.reduce(0, +) / Double(v.count), peak: s.last!, p95: s[Int(Double(s.count - 1) * 0.95)])
    }

    /// One pass over the frames. Per-app numbers only see the processes the trace kept (see `Trace.trimmed`), so
    /// they slightly undercount apps outside each frame's top list.
    public static func compute(_ t: Trace) -> TraceStats {
        let f = t.frames
        var cpuByApp: [String: (String, Double)] = [:], memByApp: [String: (String, Double)] = [:]
        // Findings are re-derived by replaying a fresh Analyzer into an in-memory IncidentLog (url nil, never saved),
        // using frame times, so the report applies the same rules (and the same 20 s minimum) as the live app.
        let analyzer = Analyzer(); let log = IncidentLog(url: nil)
        for s in f {
            for a in AppUsage.aggregate(s.processes) {
                cpuByApp[a.id, default: (a.name, 0)].1 += a.cpu
                memByApp[a.id] = (a.name, max(memByApp[a.id]?.1 ?? 0, Double(a.memory)))
            }
            log.update(analyzer.ingest(s), at: s.time)
        }
        if let last = f.last { log.closeAll(at: last.time) }
        // Per-app CPU is summed per frame, then divided by every frame, so an app present for half the span at 100%
        // averages 50%: "average over the span", not "average while running".
        let n = Double(max(f.count, 1))
        return TraceStats(
            start: f.first?.time ?? Date(), end: f.last?.time ?? Date(), frames: f.count,
            cpu: stat(f.compactMap { $0.cpu.total.value }),
            memoryUsedFraction: stat(f.map { Double($0.memory.used) / Double(max($0.memory.total, 1)) }),
            pressure: stat(f.compactMap { $0.memory.pressure.value }),
            swap: stat(f.compactMap { $0.memory.swapUsed.value }),
            // Totals need both directions; a frame missing either is left out rather than counted as half.
            diskBps: stat(f.compactMap { s in s.disk.readBps.value.flatMap { r in s.disk.writeBps.value.map { r + $0 } } }),
            netBps: stat(f.compactMap { s in s.network.inBps.value.flatMap { i in s.network.outBps.value.map { i + $0 } } }),
            watts: stat(f.compactMap { $0.power.systemWatts.value }),
            hottest: stat(f.compactMap { $0.power.hottest.value }),
            gpu: stat(f.compactMap { $0.gpu.value }),
            worstThermalState: f.map(\.power.thermalState).max() ?? 0,
            topCPU: cpuByApp.values.map { ($0.0, $0.1 / n) }.sorted { $0.1 > $1.1 }.prefix(10).map { ($0.0, $0.1) },
            topMemory: memByApp.values.sorted { $0.1 > $1.1 }.prefix(10).map { ($0.0, $0.1) },
            findings: log.incidents)
    }
}

/// CSV export (the flight report's export and the CLI's `--csv`). Blank cells mean "not measured"; nothing is filled in with 0.
public enum TraceExport {
    /// RFC 4180 quoting: wraps in quotes and doubles embedded quotes only when the field needs it.
    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
    static func num(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "" }   // empty = not measured

    /// One row per frame. Unmeasured values are empty cells, never 0.
    public static func systemCSV(_ t: Trace) -> String {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = "time,cpu_pct,cpu_user_pct,cpu_system_pct,mem_used_bytes,mem_total_bytes,mem_pressure_pct,swap_used_bytes,"
            + "disk_read_Bps,disk_write_Bps,net_in_Bps,net_out_Bps,system_watts,hottest_c,thermal_state,gpu_pct,battery_pct,"
            + "wifi_rssi_dbm,top_process,top_process_cpu_pct\n"
        for s in t.frames {
            let top = s.processes.max { $0.cpu < $1.cpu }
            let cols: [String] = [
                iso.string(from: s.time), num(s.cpu.total.value), num(s.cpu.user.value), num(s.cpu.system.value),
                "\(s.memory.used)", "\(s.memory.total)", num(s.memory.pressure.value), num(s.memory.swapUsed.value),
                num(s.disk.readBps.value), num(s.disk.writeBps.value), num(s.network.inBps.value), num(s.network.outBps.value),
                num(s.power.systemWatts.value), num(s.power.hottest.value), "\(s.power.thermalState)", num(s.gpu.value),
                num(s.power.battery?.percent), s.wifi.map { "\($0.rssi)" } ?? "",
                csvField(top?.name ?? ""), num(top?.cpu)]
            out += cols.joined(separator: ",") + "\n"
        }
        return out
    }

    /// One row per recorded process per frame (the busiest processes the trace kept).
    public static func processCSV(_ t: Trace) -> String {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = "time,pid,name,app,user,cpu_pct,memory_bytes,threads,disk_read_Bps,disk_write_Bps,net_in_Bps,net_out_Bps,energy_watts,wakeups_per_s\n"
        for s in t.frames {
            let ts = iso.string(from: s.time)
            for (p, k) in zip(s.processes, AppUsage.groupKeys(s.processes)) {
                out += [ts, "\(p.pid)", csvField(p.name), csvField(k.name), csvField(p.user), num(p.cpu), "\(p.memory)", "\(p.threads)",
                        num(p.diskReadBps), num(p.diskWriteBps), num(p.network?.inBps), num(p.network?.outBps),
                        num(p.energyWatts), num(p.wakeups)].joined(separator: ",") + "\n"
            }
        }
        return out
    }
}
