import Foundation

/// Something worth telling the user. `id` is stable while the condition lasts, so `since` measures
/// how long it has been going on, and alerts can fire once per occurrence.
public struct Finding: Identifiable, Sendable, Hashable, Codable {
    public enum Severity: Int, Comparable, Sendable, Codable {
        case info = 1, caution = 2, warning = 3
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String
    public var severity: Severity
    public var icon: String
    public var title: String
    public var detail: String?
    public var since: Date
    /// Where to look: a sidebar destination, optionally "Performance:<tab>".
    public var destination: String?
}

public struct Thresholds: Sendable, Codable, Equatable {
    public var appCPU = 80.0              // % of one core, smoothed over ~20 s
    public var diskBps = 100e6
    public var netBps = 5e6
    public var wakeups = 500.0
    public var leakGrowthBytes = 1e9
    public var leakWindow: TimeInterval = 15 * 60
    public init() {}
}

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
        if cpu == nil && watts == nil && hottest == nil { return nil }
    }
}

struct EMA {
    var value: Double?
    mutating func update(_ x: Double, dt: Double, tau: Double) {
        guard let v = value else { value = x; return }
        value = v + (1 - exp(-dt / tau)) * (x - v)
    }
}

/// Least-squares fit; returns slope (per x unit) and r².
func linearFit(_ pts: [(x: Double, y: Double)]) -> (slope: Double, r2: Double)? {
    guard pts.count >= 3 else { return nil }
    let n = Double(pts.count)
    let mx = pts.map(\.x).reduce(0, +) / n, my = pts.map(\.y).reduce(0, +) / n
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for p in pts { sxy += (p.x - mx) * (p.y - my); sxx += (p.x - mx) * (p.x - mx); syy += (p.y - my) * (p.y - my) }
    guard sxx > 0 else { return nil }
    let slope = sxy / sxx
    return (slope, syy > 0 ? (sxy * sxy) / (sxx * syy) : 1)
}

/// Turns the sample stream into findings. Uses each snapshot's own time (not the clock), so it works
/// the same live, in tests, and over a replayed trace. Not thread-safe.
public final class Analyzer {
    public var thresholds = Thresholds()
    public private(set) var baseline: Baseline?
    public private(set) var findings: [Finding] = []

    private var last: Date?
    private var appCPU: [String: EMA] = [:]
    private var appMem: [String: [(Date, Double)]] = [:]
    private var lastMemSample: Date?
    private var swap: [(Date, Double)] = []
    private var volumeFree: [(Date, Double)] = []
    private var cpuEMA = EMA(), cpuSlow = EMA(), diskEMA = EMA(), netEMA = EMA(), wattsEMA = EMA()
    private var since: [String: Date] = [:]

    public init() {}

    /// Seed from history (the black box's coarse tier): builds the baseline and the disk-space trend.
    public func seed(history frames: [Snapshot]) {
        baseline = Baseline(frames: frames)
        var lastT: Date?
        for f in frames {
            if let lastT, f.time.timeIntervalSince(lastT) < 60 { continue }
            if let v = Self.startupVolume(f) { volumeFree.append((f.time, Double(v.available))) }
            lastT = f.time
        }
    }

    public static func startupVolume(_ s: Snapshot) -> VolumeInfo? {
        s.disk.volumes.first { $0.path == "/" } ?? s.disk.volumes.first { $0.isInternal }
    }

    @discardableResult
    public func ingest(_ s: Snapshot) -> [Finding] {
        let t = s.time
        let dt = last.map { t.timeIntervalSince($0) } ?? 1
        if dt > 120 { resetShortTerm() }   // a gap breaks every "sustained" condition: we don't know what happened
        last = t
        let step = min(max(dt, 0.1), 60)
        let apps = AppUsage.aggregate(s.processes)
        let byKey = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for a in apps { appCPU[a.id, default: EMA()].update(a.cpu, dt: step, tau: 20) }
        appCPU = appCPU.filter { byKey[$0.key] != nil }
        if let c = s.cpu.total.value { cpuEMA.update(c, dt: step, tau: 20); cpuSlow.update(c, dt: step, tau: 60) }
        if let r = s.disk.readBps.value, let w = s.disk.writeBps.value { diskEMA.update(r + w, dt: step, tau: 15) }
        if let i = s.network.inBps.value, let o = s.network.outBps.value { netEMA.update(i + o, dt: step, tau: 15) }
        if let w = s.power.systemWatts.value { wattsEMA.update(w, dt: step, tau: 60) }

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
        func add(_ id: String, _ sev: Finding.Severity, _ icon: String, _ title: String, _ detail: String? = nil, _ dest: String? = nil) {
            active.append(Finding(id: id, severity: sev, icon: icon, title: title, detail: detail, since: t, destination: dest))
        }
        func describe(_ a: AppUsage) -> String { a.processes > 1 ? "\(a.name) (\(a.processes) processes)" : a.name }
        let topCPU = apps.max { $0.cpu < $1.cpu }
        let topMem = apps.max { $0.memory < $1.memory }

        // CPU hogs, by app
        let hogs = appCPU.compactMap { k, e in e.value.flatMap { $0 > thresholds.appCPU ? (k, $0) : nil } }
            .sorted { $0.1 > $1.1 }.prefix(3)
        for (k, v) in hogs {
            guard let a = byKey[k] else { continue }
            add("cpu:\(k)", .caution, "cpu", String(format: "%@ is using %.0f%% CPU", describe(a), v),
                KnownProcess.explain(a.name) ?? "Quit it or let it finish if you don't need it right now.", "Processes")
        }
        if hogs.isEmpty, let c = cpuEMA.value, c > 90 {
            add("cpu-saturated", .caution, "cpu", String(format: "CPU is %.0f%% busy", c),
                topCPU.map { "Biggest user: \(describe($0)) at \(Int($0.cpu))%." }, "Performance:CPU")
        }

        // Memory
        if s.memory.pressureLevel >= 2 {
            add("mem-pressure", s.memory.pressureLevel >= 4 ? .warning : .caution, "memorychip",
                "Memory pressure is \(s.memory.pressureLevel >= 4 ? "critical" : "elevated")",
                (topMem.map { "Biggest user: \(describe($0)) with \(Fmt.bytes($0.memory)). " } ?? "") + "macOS is compressing memory and swapping to disk.",
                "Performance:Memory")
        }
        if let sw = s.memory.swapUsed.value {
            if let old = swap.first(where: { t.timeIntervalSince($0.0) >= 540 }), sw - old.1 > 1e9 {
                add("swap-growing", .caution, "arrow.left.arrow.right", "Swap grew by \(Fmt.bytes(sw - old.1)) in 10 minutes",
                    "The Mac is running out of memory and moving it to disk.", "Performance:Memory")
            } else if sw > 2e9 {
                add("swap-used", .info, "arrow.left.arrow.right", "Swap in use: \(Fmt.bytes(sw))", nil, "Performance:Memory")
            }
        }
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
                    "Processes")
            }
        }

        // Thermals
        if s.power.thermalState >= 2 {
            var d = s.power.hottest.value.map { String(format: "Hottest sensor %.0f °C. ", $0) } ?? ""
            if let kt = byKey["proc:kernel_task"], kt.cpu > 50 { d += KnownProcess.explain("kernel_task")! }
            else if let top = topCPU { d += "Biggest CPU user: \(describe(top))." }
            add("thermal", .warning, "thermometer.high",
                "Thermal pressure is \(["Nominal", "Fair", "Serious", "Critical"][min(s.power.thermalState, 3)]): the Mac is slowing itself down to cool off",
                d, "Performance:Thermals")
        }

        // I/O
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
                "Frequent wake-ups keep the CPU from resting and cost battery, even at low CPU %.", "Processes")
        }

        // Network quality: Wi-Fi signal (local) and, when the opt-in probe runs, where the trouble is
        if let w = s.wifi, w.rssi < -75 {
            add("wifi-weak", .info, "wifi.exclamationmark", "Wi-Fi signal is weak (\(w.rssi) dBm)",
                "Signal-to-noise \(w.snr) dB, link \(Int(w.txRate)) Mbps. Moving closer to the router or switching to 5/6 GHz usually helps.",
                "Performance:Network")
        }
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

        // Compared with what's normal for this Mac
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

        // Storage
        if let v = Self.startupVolume(s) {
            let free = Double(v.available)
            if free < 10e9 || free < Double(v.capacity) * 0.05 {
                add("disk-low", .caution, "externaldrive.badge.exclamationmark", "Startup disk is almost full (\(Fmt.bytes(v.available)) free)",
                    "macOS needs free space for swap and updates. Disk Space shows what's using it.", "Disk Space")
            } else if let days = daysUntilFull(), days < 14 {
                add("disk-full", days < 3 ? .caution : .info, "calendar.badge.exclamationmark",
                    "At the current rate the startup disk will be full in about \(max(Int(days.rounded()), 1)) day\(days < 1.5 ? "" : "s")",
                    "\(Fmt.bytes(v.available)) free, shrinking steadily.", "Disk Space")
            }
        }
        if let h = s.power.battery?.health, h < 80 {
            add("battery-health", .info, "battery.75", String(format: "Battery health is %.0f%%", h),
                "Below 80% Apple recommends service.", "Performance:Energy")
        }

        // Keep the original start time of conditions that are still going.
        for i in active.indices { active[i].since = since[active[i].id] ?? t }
        since = Dictionary(active.map { ($0.id, $0.since) }, uniquingKeysWith: { a, _ in a })
        findings = active.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.since < $1.since }
        return findings
    }

    /// Linear trend of startup-volume free space; needs 2 h of history and a clearly shrinking trend.
    public func daysUntilFull() -> Double? {
        guard let first = volumeFree.first, let lastV = volumeFree.last, lastV.0.timeIntervalSince(first.0) >= 7200,
              let fit = linearFit(volumeFree.map { ($0.0.timeIntervalSince(first.0), $0.1) }),
              fit.slope < 0, fit.r2 >= 0.6 else { return nil }
        return lastV.1 / -fit.slope / 86_400
    }

    private func resetShortTerm() {
        appCPU = [:]; cpuEMA = EMA(); cpuSlow = EMA(); diskEMA = EMA(); netEMA = EMA(); wattsEMA = EMA(); since = [:]
    }
}

/// Confined to one queue by its owner.
extension Analyzer: @unchecked Sendable {}
