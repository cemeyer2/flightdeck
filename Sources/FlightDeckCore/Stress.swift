import Foundation
// Scoring behind the Stress Map: "which apps are causing misery to which parts of the Mac, right now?". Pure
// functions of one Snapshot, so the map works the same live and in replay and can be unit-tested with synthetic
// frames. Two numbers are computed:
//
//   • per subsystem, a stress level 0…1 (how close that part of the Mac is to hurting), drawn as the map's hubs;
//   • per app and subsystem, a misery contribution 0…1 = (the app's share of that resource) × (that subsystem's stress).
//
// Multiplying share by stress is the point of the design: an app using all of an idle CPU causes no misery, and a
// saturated CPU is only blamed on the apps actually using it. Following the "no invented zeros" principle, a metric
// that wasn't measured is no evidence: its stress is nil and nobody is blamed for it, rather than treating it as 0
// or guessing.

/// The parts of the Mac the Stress Map shows as hubs. The raw value is the display name.
public enum Subsystem: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu = "CPU", memory = "Memory", disk = "Disk", network = "Network", gpu = "GPU", thermal = "Thermal", energy = "Energy"
    public var id: String { rawValue }
}

/// How stressed one subsystem is right now. `stress` is nil when the reading behind it wasn't measured (the hub is
/// then drawn as "unmeasured", not as calm). `reading` is the key value in words, e.g. "72%" or "120 MB/s" ("—" if unmeasured).
public struct SubsystemStress: Sendable, Hashable, Identifiable {
    public var id: Subsystem { subsystem }
    public var subsystem: Subsystem
    public var stress: Double?
    public var reading: String
}

/// One app's misery, summed over its processes (see `AppUsage.aggregate`).
public struct AppMisery: Sendable, Identifiable {
    public var id: String { app.id }
    public var app: AppUsage
    /// Misery 0…1 per subsystem; subsystems the app doesn't measurably stress are absent.
    public var contributions: [Subsystem: Double]
    /// The share (0…1) of each resource the app accounts for, kept for the hover detail ("38% of CPU use").
    public var shares: [Subsystem: Double]
    /// At least one of its processes is reported hung by the window server. A hung app is maximal misery.
    public var hung: Bool
    /// Combined misery 0…1 (1 for hung apps).
    public var total: Double
    /// The process the inspector should open for this app: the hung one if any, else the busiest by CPU.
    public var busiest: ProcessIdentity?

    /// The subsystem this app hurts most, or nil if it hurts none measurably.
    public var main: Subsystem? { contributions.max { $0.value < $1.value }?.key }
    /// Its largest single contribution (0 if none).
    public var worst: Double { contributions.values.max() ?? 0 }
}

/// The full Stress Map state for one frame.
public struct StressReport: Sendable {
    /// Every subsystem in `Subsystem.allCases` order.
    public var hubs: [SubsystemStress]
    /// Apps above `Stress.threshold`, most miserable first, at most `limit` of them.
    public var apps: [AppMisery]
    public func hub(_ s: Subsystem) -> SubsystemStress? { hubs.first { $0.subsystem == s } }
}

/// The Stress Map's scoring. All tuning constants live here so the reasoning behind them is in one place.
public enum Stress {
    /// Below this combined misery an app isn't shown; it keeps an idle Mac's map empty ("All quiet").
    public static let threshold = 0.05
    /// Disk and network have no natural 100%; these rates count as fully stressed. 200 MB/s keeps an SSD's normal
    /// background traffic calm while a big copy lights up; 20 MB/s is a saturated typical home connection.
    public static let diskFull = 200.0 * 1_048_576
    public static let netFull = 20.0 * 1_048_576
    /// System power between these is mapped linearly to 0…1. ~10 W is an idle laptop with its screen on (system power includes the display), ~60 W a laptop working flat out.
    public static let energyIdleWatts = 10.0
    public static let energyFullWatts = 60.0

    /// Piecewise-linear curve through (0,0), (knee, kneeStress), (1,1), clamped. Used to keep normal levels quiet and
    /// emphasise the range where users actually feel it (e.g. CPU above ~60%).
    public static func ramp(_ x: Double, knee: Double, kneeStress: Double) -> Double {
        let x = min(max(x, 0), 1)
        if x <= knee { return knee > 0 ? x / knee * kneeStress : kneeStress }
        return kneeStress + (x - knee) / (1 - knee) * (1 - kneeStress)
    }

    /// CPU stress from whole-machine CPU % (0…100 of all cores): 60% → 0.25, 100% → 1.
    public static func cpuStress(_ s: Snapshot) -> Double? {
        s.cpu.total.value.map { ramp($0 / 100, knee: 0.6, kneeStress: 0.25) }
    }

    /// Memory stress from memory pressure (100 − kernel "available" level), raised to at least the kernel's own verdict
    /// (warning 0.6, critical 0.9), plus a little for swap in use (swap ÷ RAM × 0.2, at most 0.2: swap that's sitting
    /// there isn't current pain, but a lot of it means the Mac has been short of RAM). Normal pressure on macOS sits
    /// around 30–60%, hence the low knee.
    public static func memoryStress(_ s: Snapshot) -> Double? {
        let p = s.memory.pressure.value.map { ramp($0 / 100, knee: 0.6, kneeStress: 0.1) }
        let level: Double? = s.memory.pressureLevel >= 4 ? 0.9 : s.memory.pressureLevel >= 2 ? 0.6 : nil
        let swap = s.memory.swapUsed.value.map { s.memory.total > 0 ? min(0.2, $0 / Double(s.memory.total) * 0.2) : 0 }
        let parts = [p, level, swap].compactMap { $0 }
        // pressureLevel is always present (it defaults to "normal"), so it alone is not evidence of calm.
        if p == nil && swap == nil && level == nil { return nil }
        return parts.max()
    }

    /// Sum of the measured parts of a two-way rate; nil only when neither direction was measured.
    static func sum(_ a: Measured<Double>, _ b: Measured<Double>) -> Double? {
        switch (a.value, b.value) {
        case (nil, nil): return nil
        case let (x, y): return (x ?? 0) + (y ?? 0)
        }
    }

    public static func diskStress(_ s: Snapshot) -> Double? { sum(s.disk.readBps, s.disk.writeBps).map { min(1, $0 / diskFull) } }
    public static func networkStress(_ s: Snapshot) -> Double? { sum(s.network.inBps, s.network.outBps).map { min(1, $0 / netFull) } }
    /// GPU utilisation as-is: a GPU at 80% is already dropping frames for whoever needs it.
    public static func gpuStress(_ s: Snapshot) -> Double? { s.gpu.value.map { min(max($0 / 100, 0), 1) } }

    /// Thermal stress: the larger of macOS's thermal state (nominal 0, fair 0.4, serious 0.75, critical 1) and the
    /// hottest sensor (70 °C → 0, 100 °C → 1). Apple silicon runs warm without harm, so only the top range counts.
    public static func thermalStress(_ s: Snapshot) -> Double? {
        let state = [0, 0.4, 0.75, 1][min(max(s.power.thermalState, 0), 3)]
        let temp = s.power.hottest.value.map { min(max(($0 - 70) / 30, 0), 1) }
        return max(state, temp ?? 0)
    }

    public static func energyStress(_ s: Snapshot) -> Double? {
        // Power draw is only real misery on battery (it's what drains it). On AC it's scaled down to a quarter, so a busy
        // plugged-in Mac's main complaint stays CPU/thermal rather than "energy".
        let onBattery = s.power.powerSource == "Battery"
        return s.power.systemWatts.value.map { min(max(($0 - energyIdleWatts) / (energyFullWatts - energyIdleWatts), 0), 1) * (onBattery ? 1 : 0.25) }
    }

    /// The key reading shown beside each hub.
    static func reading(_ sub: Subsystem, _ s: Snapshot) -> String {
        switch sub {
        case .cpu: return s.cpu.total.value.map { String(format: "%.0f%%", $0) } ?? "—"
        case .memory: return s.memory.pressure.value.map { String(format: "pressure %.0f%%", $0) } ?? "—"
        case .disk: return sum(s.disk.readBps, s.disk.writeBps).map(Fmt.rate) ?? "—"
        case .network: return sum(s.network.inBps, s.network.outBps).map(Fmt.rate) ?? "—"
        case .gpu: return s.gpu.value.map { String(format: "%.0f%%", $0) } ?? "—"
        case .thermal:
            let state = ["Nominal", "Fair", "Serious", "Critical"][min(max(s.power.thermalState, 0), 3)]
            return s.power.hottest.value.map { "\(state) · \(Fmt.temp($0))" } ?? state
        case .energy: return s.power.systemWatts.value.map { String(format: "%.1f W", $0) } ?? "—"
        }
    }

    /// Stress of every subsystem, in `Subsystem.allCases` order.
    public static func hubs(_ s: Snapshot) -> [SubsystemStress] {
        Subsystem.allCases.map { sub in
            let v: Double?
            switch sub {
            case .cpu: v = cpuStress(s); case .memory: v = memoryStress(s); case .disk: v = diskStress(s)
            case .network: v = networkStress(s); case .gpu: v = gpuStress(s); case .thermal: v = thermalStress(s)
            case .energy: v = energyStress(s)
            }
            return SubsystemStress(subsystem: sub, stress: v, reading: reading(sub, s))
        }
    }

    /// Combines per-subsystem misery into one number with a probabilistic OR, 1 − Π(1 − cᵢ): stays in 0…1, is never
    /// below the largest contribution, and an app hurting two things scores above one hurting only one of them.
    public static func combine(_ c: some Sequence<Double>) -> Double {
        1 - c.reduce(1) { $0 * (1 - min(max($1, 0), 1)) }
    }

    /// Scores every app in `s` and returns the hubs plus the apps above `threshold` (hung apps always qualify),
    /// most miserable first, capped at `limit`. Cost is linear in the process count (one aggregate pass).
    public static func report(_ s: Snapshot, limit: Int = 12) -> StressReport {
        let hubs = hubs(s)
        var stress: [Subsystem: Double] = [:]
        for h in hubs { if let v = h.stress { stress[h.subsystem] = v } }

        let apps = AppUsage.aggregate(s.processes)
        // Each app's share is relative to all apps' use of that resource, so shares add up to 1 across apps.
        let tCPU = apps.reduce(0) { $0 + $1.cpu }
        let tDisk = apps.reduce(0) { $0 + $1.diskBps }
        let tNet = apps.reduce(0) { $0 + $1.netBps }
        let tGPU = apps.reduce(0) { $0 + ($1.gpu ?? 0) }
        let tEnergy = apps.reduce(0) { $0 + ($1.energyWatts ?? 0) }
        let used = Double(s.memory.used)
        func share(_ x: Double, _ t: Double) -> Double { t > 0 ? min(max(x / t, 0), 1) : 0 }

        // Processes by PID, to pick each app's busiest (or hung) process for the inspector.
        let byPID = Dictionary(s.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [AppMisery] = []
        for a in apps {
            var sh: [Subsystem: Double] = [:]
            sh[.cpu] = share(a.cpu, tCPU)
            if used > 0 { sh[.memory] = min(Double(a.memory) / used, 1) }
            sh[.disk] = share(a.diskBps, tDisk)
            sh[.network] = share(a.netBps, tNet)
            if let g = a.gpu { sh[.gpu] = share(g, tGPU) }
            if let w = a.energyWatts { sh[.energy] = share(w, tEnergy) }
            // Heat comes from the CPU and GPU, so thermal blame follows those shares, weighted by how hard each is working.
            let wc = stress[.cpu] ?? 0, wg = stress[.gpu] ?? 0
            let cs = sh[.cpu] ?? 0, gs = sh[.gpu] ?? 0
            sh[.thermal] = wc + wg > 0 ? (cs * wc + gs * wg) / (wc + wg) : cs

            var c: [Subsystem: Double] = [:]
            for (sub, x) in sh { if let st = stress[sub], x * st > 0.001 { c[sub] = min(x * st, 1) } }
            let members = a.pids.compactMap { byPID[$0] }
            let hung = members.contains { $0.notResponding == true }
            let busiest = (members.first { $0.notResponding == true } ?? members.max { $0.cpu < $1.cpu })?.identity
            let total = hung ? 1 : combine(c.values)
            guard hung || total >= threshold else { continue }
            out.append(AppMisery(app: a, contributions: c, shares: sh, hung: hung, total: total, busiest: busiest))
        }
        // Ties (e.g. two hung apps) are broken by name so the order doesn't flicker between frames.
        out.sort { $0.total != $1.total ? $0.total > $1.total : $0.app.name < $1.app.name }
        return StressReport(hubs: hubs, apps: Array(out.prefix(limit)))
    }
}
