import Foundation
// The rules of thumb that turn raw telemetry into plain-English findings ("Chrome is using 250% CPU"). The Engine runs
// `Analyzer.ingest` on its sampling queue for every snapshot; findings feed the Findings list, alerts, the Dock badge
// and, via IncidentLog, the incident history. TraceStats and the Flight Recorder replay it over recorded frames.

/// Something worth telling the user. `id` is stable while the condition lasts, so `since` measures
/// how long it has been going on, and alerts can fire once per occurrence.
public struct Finding: Identifiable, Sendable, Hashable, Codable {
    /// Ordered so findings can be sorted worst-first and incidents can keep their worst level.
    public enum Severity: Int, Comparable, Sendable, Codable {
        case info = 1, caution = 2, warning = 3
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    /// Stable key such as "cpu:<app id>", "hang:<pid>-<start time>" or "disk-low"; one finding per id per sample.
    public var id: String
    public var severity: Severity
    /// SF Symbol name.
    public var icon: String
    public var title: String
    public var detail: String?
    /// Snapshot time when the condition was first seen in its current, unbroken run.
    public var since: Date
    /// Where to look: a sidebar destination, optionally "Performance:<tab>".
    public var destination: String?
    /// Processes responsible (busiest first), for "Inspect" / "Quit" actions.
    public var pids: [Int32]? = nil
    /// What a viewer would see change (identity, severity, wording).
    public var signature: String { "\(id)|\(severity.rawValue)|\(title)|\(detail ?? "")" }
}

/// Tunable limits for the per-app and I/O findings. Only `appCPU` is currently user-adjustable (the Engine pushes it in).
public struct Thresholds: Sendable, Codable, Equatable {
    public var appCPU = 80.0              // % of one core, smoothed over ~20 s
    /// Disk and network totals in bytes/s (smoothed over ~15 s); wake-ups per second for the busiest app.
    public var diskBps = 100e6
    public var netBps = 5e6
    public var wakeups = 500.0
    /// Leak finding: fitted growth of at least `leakGrowthBytes` over a steady trend spanning at least `leakWindow` s.
    public var leakGrowthBytes = 1e9
    public var leakWindow: TimeInterval = 15 * 60
    public init() {}
}

/// Median and 90th percentile (lower nearest rank) of a metric. nil with fewer than 30 values: too little to call "normal".
public struct Percentiles: Sendable, Hashable {
    public var p50: Double, p90: Double, count: Int
    public init?(_ values: [Double]) {
        guard values.count >= 30 else { return nil }
        let s = values.sorted()
        p50 = s[s.count / 2]; p90 = s[Int(Double(s.count - 1) * 0.9)]; count = s.count
    }
}

/// What is normal for this Mac, from the black box's 24-hour tier. Needs at least 30 minutes of data.
public struct Baseline: Sendable {
    public var cpu: Percentiles?
    public var watts: Percentiles?
    public var hottest: Percentiles?
    public var span: TimeInterval
    public init?(frames: [Snapshot]) {
        guard let a = frames.first?.time, let b = frames.last?.time, b.timeIntervalSince(a) >= 1800 else { return nil }
        span = b.timeIntervalSince(a)
        cpu = Percentiles(frames.compactMap { $0.cpu.total.value })
        watts = Percentiles(frames.compactMap { $0.power.systemWatts.value })
        hottest = Percentiles(frames.compactMap { $0.power.hottest.value })
        // Each metric is independent (system power or temperatures may be unavailable on some Macs); only give up
        // if none of them has enough data.
        if cpu == nil && watts == nil && hottest == nil { return nil }
    }
}

/// Exponential moving average that handles irregular sample spacing. The weight of a new sample is 1 - e^(-dt/tau),
/// so after `tau` seconds a step change is ~63% absorbed regardless of the sampling interval (1 s live, 10 s in the
/// coarse tier, slower in the background). `value` is nil until the first sample: no reading means no average, not 0.
struct EMA {
    var value: Double?
    mutating func update(_ x: Double, dt: Double, tau: Double) {
        // The first sample is taken as-is, so a fresh EMA (after launch or a gap) starts at the real value, not ramping from 0.
        guard let v = value else { value = x; return }
        value = v + (1 - exp(-dt / tau)) * (x - v)
    }
}

/// Least-squares fit; returns slope (per x unit) and r². Used for memory-leak and disk-filling trends, where r²
/// separates steady growth from noisy ups and downs. nil with fewer than 3 points or all x equal.
func linearFit(_ pts: [(x: Double, y: Double)]) -> (slope: Double, r2: Double)? {
    guard pts.count >= 3 else { return nil }
    let n = Double(pts.count)
    let mx = pts.map(\.x).reduce(0, +) / n, my = pts.map(\.y).reduce(0, +) / n
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for p in pts { sxy += (p.x - mx) * (p.y - my); sxx += (p.x - mx) * (p.x - mx); syy += (p.y - my) * (p.y - my) }
    guard sxx > 0 else { return nil }
    let slope = sxy / sxx
    // A perfectly flat y is a perfect (zero-slope) fit.
    return (slope, syy > 0 ? (sxy * sxy) / (sxx * syy) : 1)
}

/// Turns the sample stream into findings. Uses each snapshot's own time (not the clock), so it works
/// the same live, in tests, and over a replayed trace. Not thread-safe.
///
/// Most findings are built from smoothed state (EMAs and short histories) kept between calls, so a one-sample spike
/// doesn't raise anything. `ingest` rebuilds the whole finding list each time; anything not re-added has ended.
public final class Analyzer {
    public var thresholds = Thresholds()
    /// "Normal for this Mac", built from the black box's last 24 h at launch (`seed`). nil until enough history exists.
    public private(set) var baseline: Baseline?
    public private(set) var findings: [Finding] = []

    /// Time of the previous snapshot, to compute dt and detect gaps.
    private var last: Date?
    /// Per-app smoothed CPU and GPU, keyed by app id (`AppUsage.id`).
    private var appCPU: [String: EMA] = [:]
    /// Per-app memory points (bytes) every 30 s for up to an hour, for leak detection.
    private var appMem: [String: [(Date, Double)]] = [:]
    private var lastMemSample: Date?
    /// Swap used (bytes) every 30 s over the last 20 min, and startup-volume free bytes once a minute over 24 h.
    private var swap: [(Date, Double)] = []
    private var volumeFree: [(Date, Double)] = []
    /// Whole-machine smoothing: cpuEMA (20 s) for saturation, cpuSlow (60 s) for "unusual", disk/net 15 s, watts 60 s.
    private var cpuEMA = EMA(), cpuSlow = EMA(), diskEMA = EMA(), netEMA = EMA(), wattsEMA = EMA()
    /// Finding id -> when it started; only ids active in the previous sample survive.
    private var since: [String: Date] = [:]
    private var appGPU: [String: EMA] = [:]
    /// Smoothed % of time the GPU was frequency-capped for heat.
    private var gpuThermal = EMA()
    /// Smoothed bytes/s written to swap, from the cumulative swap-out page counter (`lastSwapOuts` is the previous reading).
    private var swapOutRate = EMA()
    private var pClockRatio = EMA()   // P-cluster clock / max, while busy
    private var lastSwapOuts: (Date, UInt64)?
    /// GPU recovery (driver reset) counter at the previous sample, and the times of recent recoveries (last 10 min).
    private var lastRecoveries: Int?
    private var recoveryEvents: [Date] = []

    public init() {}

    /// Seed from history (the black box's coarse tier): builds the baseline and the disk-space trend.
    /// Called once at launch on the sampling queue, after the black box has been read; live samples may already have
    /// been ingested by then. Frames are thinned to one per minute to match the live disk-space cadence.
    public func seed(history frames: [Snapshot]) {
        baseline = Baseline(frames: frames)
        var lastT: Date?
        for f in frames {
            if let lastT, f.time.timeIntervalSince(lastT) < 60 { continue }
            if let v = Self.startupVolume(f) { volumeFree.append((f.time, Double(v.available))) }
            lastT = f.time
        }
        // Live points may already be in the list; keep it in time order so the trend uses the full history.
        volumeFree.sort { $0.0 < $1.0 }
    }

    /// The volume mounted at "/", or the first internal volume if "/" isn't listed.
    public static func startupVolume(_ s: Snapshot) -> VolumeInfo? {
        s.disk.volumes.first { $0.path == "/" } ?? s.disk.volumes.first { $0.isInternal }
    }

    /// Updates internal state with one snapshot and returns the current findings, worst first, then oldest first.
    /// Call in time order; the result is also kept in `findings`.
    @discardableResult
    public func ingest(_ s: Snapshot) -> [Finding] {
        let t = s.time
        let dt = last.map { t.timeIntervalSince($0) } ?? 1
        if dt > 120 { resetShortTerm() }   // a gap breaks every "sustained" condition: we don't know what happened
        last = t
        // dt as seen by the EMAs, clamped so duplicate timestamps can't divide by zero and one slow step (just under
        // the 120 s gap limit) can't fully overwrite the average.
        let step = min(max(dt, 0.1), 60)
        let apps = AppUsage.aggregate(s.processes)
        let byKey = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Smooth per app, then drop apps that are no longer running so their state can't leak into a later launch.
        // A missing GPU reading is smoothed as 0 here: per-app GPU is only used for the "above 80%" check.
        for a in apps { appCPU[a.id, default: EMA()].update(a.cpu, dt: step, tau: 20) }
        appCPU = appCPU.filter { byKey[$0.key] != nil }
        for a in apps { appGPU[a.id, default: EMA()].update(a.gpu ?? 0, dt: step, tau: 20) }
        appGPU = appGPU.filter { byKey[$0.key] != nil }
        if let tl = s.gpuDetail?.thermalLimited { gpuThermal.update(tl, dt: step, tau: 30) }
        // P-core clock ratio is only meaningful while the cluster is busy (an idle core is clocked down on purpose), so
        // the average is tracked only while some P-cluster is >70% active, and reset as soon as none is.
        let busyP = (s.gpuDetail?.cpuClusters ?? []).filter { $0.name.hasPrefix("P") && $0.active > 70 && $0.mhz != nil && $0.maxMHz > 0 }
        if let c = busyP.max(by: { $0.active < $1.active }) { pClockRatio.update(c.mhz! / c.maxMHz, dt: step, tau: 20) } else { pClockRatio = EMA() }
        // swapOuts is a cumulative page count since boot; the rate is its delta over time. `so >= lv` skips the sample
        // after a counter reset (reboot between a recorded trace's frames) instead of computing a huge negative rate.
        if let so = s.memory.swapOuts, let ps = s.memory.pageSize {
            if let (lt, lv) = lastSwapOuts, t > lt, so >= lv { swapOutRate.update(Double(so - lv) * Double(ps) / t.timeIntervalSince(lt), dt: step, tau: 20) }
            lastSwapOuts = (t, so)
        }
        if let c = s.cpu.total.value { cpuEMA.update(c, dt: step, tau: 20); cpuSlow.update(c, dt: step, tau: 60) }
        if let r = s.disk.readBps.value, let w = s.disk.writeBps.value { diskEMA.update(r + w, dt: step, tau: 15) }
        if let i = s.network.inBps.value, let o = s.network.outBps.value { netEMA.update(i + o, dt: step, tau: 15) }
        if let w = s.power.systemWatts.value { wattsEMA.update(w, dt: step, tau: 60) }

        // Slow histories are sampled every 30 s to keep them small. Only the 40 largest apps are tracked for leaks;
        // an app's history is discarded once it hasn't been updated for 2 min (quit, or fell out of the top 40), so a
        // gap in its trend never gets fitted across.
        if lastMemSample.map({ t.timeIntervalSince($0) >= 30 }) ?? true {
            lastMemSample = t
            for a in apps.sorted(by: { $0.memory > $1.memory }).prefix(40) { appMem[a.id, default: []].append((t, Double(a.memory))) }
            appMem = appMem.compactMapValues { pts in
                let kept = pts.filter { t.timeIntervalSince($0.0) <= 3600 }
                return kept.last.map { t.timeIntervalSince($0.0) < 120 } == true ? kept : nil
            }
            if let sw = s.memory.swapUsed.value { swap.append((t, sw)); swap.removeAll { t.timeIntervalSince($0.0) > 1200 } }
        }
        if let v = Self.startupVolume(s), volumeFree.last.map({ t.timeIntervalSince($0.0) >= 60 }) ?? true {
            volumeFree.append((t, Double(v.available)))
            volumeFree.removeAll { t.timeIntervalSince($0.0) > 86_400 }
        }

        var active: [Finding] = []
        // `add` collects one finding; `pids` are sorted busiest-CPU first so "Inspect"/"Quit" pick the main culprit.
        // `since` is set to now here and replaced with the remembered start at the end of `ingest`.
        let cpuOf = Dictionary(s.processes.map { ($0.pid, $0.cpu) }, uniquingKeysWith: max)
        func add(_ id: String, _ sev: Finding.Severity, _ icon: String, _ title: String, _ detail: String? = nil, _ dest: String? = nil, pids: [Int32]? = nil) {
            active.append(Finding(id: id, severity: sev, icon: icon, title: title, detail: detail, since: t, destination: dest,
                                  pids: pids?.sorted { (cpuOf[$0] ?? 0) > (cpuOf[$1] ?? 0) }))
        }
        func describe(_ a: AppUsage) -> String { a.processes > 1 ? "\(a.name) (\(a.processes) processes)" : a.name }
        let topCPU = apps.max { $0.cpu < $1.cpu }
        let topMem = apps.max { $0.memory < $1.memory }

        // CPU hogs, by app: smoothed CPU above the threshold (% of one core), at most the top three. When no single
        // app is to blame but the whole machine is >90% busy, report saturation instead.
        let hogs = appCPU.compactMap { k, e in e.value.flatMap { $0 > thresholds.appCPU ? (k, $0) : nil } }
            .sorted { $0.1 > $1.1 }.prefix(3)
        for (k, v) in hogs {
            guard let a = byKey[k] else { continue }
            add("cpu:\(k)", .caution, "cpu", String(format: "%@ is using %.0f%% CPU", describe(a), v),
                KnownProcess.explain(a.name) ?? "Quit it or let it finish if you don't need it right now.", "Processes", pids: a.pids)
        }
        if hogs.isEmpty, let c = cpuEMA.value, c > 90 {
            add("cpu-saturated", .caution, "cpu", String(format: "CPU is %.0f%% busy", c),
                topCPU.map { "Biggest user: \(describe($0)) at \(Int($0.cpu))%." }, "Performance:CPU")
        }

        // GPU
        if let g = s.gpuDetail {
            // recoveryCount is cumulative; each increase is logged as an event and events are kept for 10 minutes.
            // The first reading only sets the baseline, so restarts from before launch aren't reported.
            if let r = g.recoveryCount {
                if let prev = lastRecoveries, r > prev { for _ in 0..<(r - prev) { recoveryEvents.append(t) } }
                lastRecoveries = r
            }
            recoveryEvents.removeAll { t.timeIntervalSince($0) > 600 }
            if !recoveryEvents.isEmpty {
                add("gpu-recovery", .warning, "exclamationmark.triangle", "The GPU hung and was restarted \(recoveryEvents.count) time\(recoveryEvents.count == 1 ? "" : "s") in the last 10 minutes",
                    "An app (or the driver) stalled the GPU, and macOS reset it. If this repeats, check the busiest GPU app below and quit it.", "Performance:GPU")
            }
            if let tl = gpuThermal.value, tl > 10 {
                add("gpu-thermal", .caution, "thermometer.high", String(format: "The GPU is being slowed down for heat (%.0f%% of the time)", tl),
                    "Its clock is capped to control temperature, so graphics and compute run slower.", "Performance:GPU")
            }
            // Apple-silicon GPUs share RAM; Metal's working-set limit is about 75% of it, so warn at 90% of that.
            if let used = g.memoryInUse, s.memory.total > 0, Double(used) > Double(s.memory.total) * 0.75 * 0.9 {
                add("gpu-memory", .caution, "memorychip", "GPU memory is nearly at its working-set limit (\(Fmt.bytes(used)))",
                    "Apps that need more GPU memory will slow down or fail. Close GPU-heavy apps or tabs.", "Performance:GPU")
            }
        }
        for (k, e) in appGPU { if let v = e.value, v > 80, let a = byKey[k] {
            add("gpu:\(k)", .caution, "cube.transparent", String(format: "%@ is using %.0f%% of the GPU", describe(a), v),
                KnownProcess.explain(a.name) ?? "Graphics or compute work from this app is keeping the GPU busy.", "Performance:GPU", pids: a.pids)
        } }

        // Apps keeping the Mac awake (system daemons that do this routinely are left out: uid < 500 outside an .app)
        // One finding per app, using the first assertion of the last matching process as the reason.
        var awake: [String: (AppUsage?, PowerAssertion)] = [:]
        for p in s.processes where p.uid >= 500 || AppUsage.bundle(of: p.path) != nil {
            guard let a = p.powerAssertions?.first else { continue }
            let k = AppUsage.groupKeys([p])[0].key
            awake[k] = (byKey[k], a)
        }
        for (k, v) in awake {
            let name = v.0.map(describe) ?? k.replacingOccurrences(of: "proc:", with: "")
            add("awake:\(k)", .info, v.1.preventsDisplaySleep ? "display" : "moon.zzz", "\(name) \(v.1.label)",
                v.1.name.isEmpty ? nil : "Reason given: “\(v.1.name)”.", "Processes", pids: v.0?.pids)
        }

        // Hung apps
        // Keyed by PID + start time so a relaunched app that hangs again is a new finding.
        for p in s.processes where p.notResponding == true {
            let name = AppUsage.key(for: p).name
            add("hang:\(p.identity.pid)-\(p.identity.startTime)", .warning, "hourglass", "\(name) is not responding",
                "Its main thread is stuck. Open it in the inspector and sample its stacks to see where, or Force Quit it.", "Processes", pids: [p.pid])
        }

        // Memory: pressureLevel is the kernel's 1 normal / 2 warn / 4 critical.
        if s.memory.pressureLevel >= 2 {
            add("mem-pressure", s.memory.pressureLevel >= 4 ? .warning : .caution, "memorychip",
                "Memory pressure is \(s.memory.pressureLevel >= 4 ? "critical" : "elevated")",
                (topMem.map { "Biggest user: \(describe($0)) with \(Fmt.bytes($0.memory)). " } ?? "") + "macOS is compressing memory and swapping to disk.",
                "Performance:Memory")
        }
        if let r = swapOutRate.value, r > 20e6 {
            add("swapping", .caution, "arrow.down.doc", "The Mac is swapping heavily (\(Fmt.rate(r)) to disk)",
                (topMem.map { "Biggest memory user: \(describe($0)) with \(Fmt.bytes($0.memory)). " } ?? "") + "Everything slows down while memory is paged to disk; closing large apps or tabs helps most.",
                "Performance:Memory", pids: topMem?.pids)
        }
        if let sw = s.memory.swapUsed.value {
            // Compare with the oldest point at least 9 minutes old; since `swap` keeps 20 minutes, that can be up to
            // 20 minutes back even though the title says 10.
            // The newest point that is at least ~10 minutes old (not the oldest, which can be up to 20 minutes back).
            if let old = swap.last(where: { t.timeIntervalSince($0.0) >= 540 }), sw - old.1 > 1e9 {
                add("swap-growing", .caution, "arrow.left.arrow.right", "Swap grew by \(Fmt.bytes(sw - old.1)) in 10 minutes",
                    "The Mac is running out of memory and moving it to disk.", "Performance:Memory")
            } else if sw > 2e9 {
                add("swap-used", .info, "arrow.left.arrow.right", "Swap in use: \(Fmt.bytes(sw))", nil, "Performance:Memory")
            }
        }
        // Leak: over the last 30 min of an app's memory points, need at least `leakWindow` of history, a fitted
        // growth of `leakGrowthBytes`, r² >= 0.8 (steady, not spiky) and 1.5x the starting size, so big apps
        // that merely fluctuate aren't flagged.
        for (k, pts) in appMem {
            let recent = pts.filter { t.timeIntervalSince($0.0) <= 1800 }
            guard let first = recent.first, let lastP = recent.last,
                  lastP.0.timeIntervalSince(first.0) >= thresholds.leakWindow,
                  let fit = linearFit(recent.map { ($0.0.timeIntervalSince(first.0), $0.1) }) else { continue }
            let span = lastP.0.timeIntervalSince(first.0)
            let growth = fit.slope * span
            if growth >= thresholds.leakGrowthBytes, fit.r2 >= 0.8, lastP.1 >= first.1 * 1.5 {
                let name = byKey[k].map(describe) ?? k
                add("leak:\(k)", .caution, "chart.line.uptrend.xyaxis",
                    "\(name) keeps using more memory: +\(Fmt.bytes(growth)) in \(Int(span / 60)) min",
                    "It now uses \(Fmt.bytes(lastP.1)). Steady growth like this often means a memory leak; restarting the app frees the memory.",
                    "Processes", pids: byKey[k]?.pids)
            }
        }

        // Thermals: ProcessInfo thermal state 2 (serious) or 3 (critical). kernel_task high CPU at that point is
        // macOS's own thermal throttling, so it's explained rather than blamed.
        if s.power.thermalState >= 2 {
            var d = s.power.hottest.value.map { String(format: "Hottest sensor %.0f °C. ", $0) } ?? ""
            if let kt = byKey["proc:kernel_task"], kt.cpu > 50 { d += KnownProcess.explain("kernel_task")! }
            else if let top = topCPU { d += "Biggest CPU user: \(describe(top))." }
            add("thermal", .warning, "thermometer.high",
                "Thermal pressure is \(["Nominal", "Fair", "Serious", "Critical"][min(s.power.thermalState, 3)]): the Mac is slowing itself down to cool off",
                d, "Performance:Thermals")
        }

        // Measured CPU throttling: busy P-cores held well below their top clock while hot. The heat condition keeps
        // ordinary power management (lower clocks on battery or light load) from being reported as throttling.
        if let r = pClockRatio.value, r < 0.7, s.power.thermalState >= 1 || (s.power.hottest.value ?? 0) >= 90,
           let c = (s.gpuDetail?.cpuClusters ?? []).filter({ $0.name.hasPrefix("P") }).max(by: { $0.active < $1.active }), let mhz = c.mhz {
            add("cpu-throttled", .caution, "speedometer", String(format: "CPU is throttled: busy performance cores at %.1f of %.1f GHz", mhz / 1000, c.maxMHz / 1000),
                (s.power.hottest.value.map { String(format: "Hottest sensor %.0f °C. ", $0) } ?? "") + "macOS lowers clocks to control heat, so work takes longer. Better airflow or a cooler room helps.",
                "Performance:Thermals")
        }

        // I/O: smoothed totals; the app named is the biggest user in this sample.
        if let d = diskEMA.value, d > thresholds.diskBps {
            let top = apps.max { $0.diskBps < $1.diskBps }
            add("disk-busy", .info, "internaldrive", "Heavy disk activity (\(Fmt.rate(d)))" + (top.map { ", mostly \(describe($0))" } ?? ""),
                top.flatMap { KnownProcess.explain($0.name) }, "Performance:Disk")
        }
        if let n = netEMA.value, n > thresholds.netBps {
            let top = apps.max { $0.netBps < $1.netBps }
            add("net-busy", .info, "network", "Heavy network traffic (\(Fmt.rate(n)))" + (top.flatMap { $0.netBps > 0 ? ", mostly \(describe($0))" : nil } ?? ""),
                top.flatMap { KnownProcess.explain($0.name) }, "Performance:Network")
        }
        if let w = apps.max(by: { $0.wakeups < $1.wakeups }), w.wakeups > thresholds.wakeups {
            add("wakeups:\(w.id)", .info, "alarm", String(format: "%@ wakes the CPU %.0f times a second", describe(w), w.wakeups),
                "Frequent wake-ups keep the CPU from resting and cost battery, even at low CPU %.", "Processes", pids: w.pids)
        }

        // Network quality: Wi-Fi signal (local) and, when the opt-in probe runs, where the trouble is
        if let w = s.wifi, w.rssi < -75 {
            add("wifi-weak", .info, "wifi.exclamationmark", "Wi-Fi signal is weak (\(w.rssi) dBm)",
                "Signal-to-noise \(w.snr) dB, link \(Int(w.txRate)) Mbps. Moving closer to the router or switching to 5/6 GHz usually helps.",
                "Performance:Network")
        }
        // Probe results older than 45 s are stale (e.g. the probe was turned off). A bad router explains a bad internet result,
        // so only the local finding is shown in that case.
        let fresh = (s.latency ?? []).filter { t.timeIntervalSince($0.time) < 45 }
        let router = fresh.first { $0.role == "Router" }, internet = fresh.first { $0.role == "Internet" }
        func bad(_ r: LatencyResult?, ms: Double) -> Bool { r.map { $0.loss >= 5 || ($0.avgMs ?? 0) > ms } ?? false }
        func show(_ r: LatencyResult) -> String { String(format: "%.0f%% loss", r.loss) + (r.avgMs.map { String(format: ", %.0f ms", $0) } ?? "") }
        if let router, bad(router, ms: 50) {
            add("net-local", .caution, "wifi.exclamationmark", "Your Wi-Fi or local network is unhealthy (router: \(show(router)))",
                "The problem is between this Mac and the router" + (s.wifi.map { ", Wi-Fi signal \($0.quality.lowercased()) (\($0.rssi) dBm)" } ?? "") + ".",
                "Performance:Network")
        } else if let internet, bad(internet, ms: 150) {
            add("net-internet", .caution, "globe", "Internet connection is unhealthy (\(show(internet)))",
                router.map { "Your local network is fine (router: \(show($0))), so the problem is likely your internet provider." } ?? nil,
                "Performance:Network")
        }

        // Compared with what's normal for this Mac: needs both an absolute floor and a clear margin over its own p90,
        // so a usually idle Mac doesn't raise "unusual" at 20% CPU.
        if let b = baseline {
            if let p = b.cpu, let c = cpuSlow.value, c > 40, c > max(p.p90 * 1.5, p.p90 + 25) {
                add("unusual-cpu", .info, "waveform.path.ecg", String(format: "CPU is unusually busy for this Mac (%.0f%%)", c),
                    String(format: "Usually %.0f%%, and above %.0f%% only 10%% of the time.", p.p50, p.p90), "Performance:CPU")
            }
            if s.power.powerSource == "Battery", let p = b.watts, let w = wattsEMA.value, w > 8, w > p.p90 * 1.5 {
                let top = apps.filter { $0.energyWatts != nil }.max { ($0.energyWatts ?? 0) < ($1.energyWatts ?? 0) }
                add("unusual-power", .info, "battery.25", String(format: "Battery is draining faster than usual (%.1f W)", w),
                    String(format: "Usually %.1f W.", p.p50) + (top.map { " Biggest energy user: \(describe($0))." } ?? ""), "Performance:Energy")
            }
        }

        // Storage: low space now (under 10 GB or 5%), else a projection of when the startup disk fills.
        if let v = Self.startupVolume(s) {
            let free = Double(v.available)
            if free < 10e9 || free < Double(v.capacity) * 0.05 {
                add("disk-low", .caution, "externaldrive.badge.exclamationmark", "Startup disk is almost full (\(Fmt.storage(v.available)) free)",
                    "macOS needs free space for swap and updates. Disk Space shows what's using it.", "Disk Space")
            } else if let days = daysUntilFull(), days < 14 {
                add("disk-full", days < 3 ? .caution : .info, "calendar.badge.exclamationmark",
                    "At the current rate the startup disk will be full in about \(max(Int(days.rounded()), 1)) day\(days < 1.5 ? "" : "s")",
                    "\(Fmt.storage(v.available)) free, shrinking steadily.", "Disk Space")
            }
        }
        for d in s.drives ?? [] where !d.healthy {
            add("drive:\(d.id)", d.criticalWarning != 0 || d.mediaErrors > 0 ? .warning : .caution, "internaldrive.fill",
                "\(d.model) health: \(d.warnings.joined(separator: ", "))",
                "Back up now. SSD problems tend to get worse, not better.", "Performance:Disk")
        }
        if let h = s.power.battery?.health, h < 80 {
            add("battery-health", .info, "battery.75", String(format: "Battery health is %.0f%%", h),
                "Below 80% Apple recommends service.", "Performance:Energy")
        }

        // Keep the original start time of conditions that are still going. Rebuilding `since` from this sample alone
        // means a finding that disappears for even one sample starts over with a new `since` (and a new incident).
        for i in active.indices { active[i].since = since[active[i].id] ?? t }
        since = Dictionary(active.map { ($0.id, $0.since) }, uniquingKeysWith: { a, _ in a })
        findings = active.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.since < $1.since }
        return findings
    }

    /// Linear trend of startup-volume free space; needs 2 h of history and a clearly shrinking trend.
    /// Returns days until free space reaches 0 at the fitted rate, from the latest reading, or nil.
    public func daysUntilFull() -> Double? {
        guard let first = volumeFree.first, let lastV = volumeFree.last, lastV.0.timeIntervalSince(first.0) >= 7200,
              let fit = linearFit(volumeFree.map { ($0.0.timeIntervalSince(first.0), $0.1) }),
              fit.slope < 0, fit.r2 >= 0.6 else { return nil }
        return lastV.1 / -fit.slope / 86_400
    }

    /// Called after a gap of more than 120 s: clears smoothing and `since`, so sustained findings must re-establish
    /// themselves. Long-term histories (memory trend, swap, disk space, GPU recoveries) are kept; they are time-stamped
    /// and pruned by age, and the memory trend drops stale apps on its own.
    private func resetShortTerm() {
        swap = []   // a gap (e.g. sleep) would make "swap grew in 10 minutes" compare across it
        appCPU = [:]; appGPU = [:]; gpuThermal = EMA(); swapOutRate = EMA(); lastSwapOuts = nil; pClockRatio = EMA(); cpuEMA = EMA(); cpuSlow = EMA(); diskEMA = EMA(); netEMA = EMA(); wattsEMA = EMA(); since = [:]
    }
}

/// Confined to one queue by its owner.
extension Analyzer: @unchecked Sendable {}
