import Foundation
import IOKit

// GPU detail for each snapshot (Snapshot.gpuDetail) plus per-process GPU share. Combines the accelerator's public
// IORegistry PerformanceStatistics, per-client accumulated GPU time from the accelerator's user clients, and private
// IOReport channels (P-state residency, energy, thermal capping) via IOReportSampler. Runs on the sampling queue.
/// One process using the GPU, aggregated over all of its accelerator user clients (Metal/OpenGL/CoreML contexts).
public struct GPUClient: Codable, Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var percent: Double          // share of GPU time over the last sample
    public var totalSeconds: Double     // accumulated GPU time
    /// API names the driver reports for its clients, e.g. "Metal".
    public var apis: [String]
}

/// Live average frequency of one CPU cluster or the GPU, estimated from IOReport P-state residency and the DVFS table.
public struct ClusterFrequency: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String             // "E-cluster", "P-cluster 0", "GPU"
    public var mhz: Double?             // residency-weighted average while active; nil if idle
    public var active: Double           // % of time not idle/off
    /// Top of the cluster's DVFS table, for scaling gauges.
    public var maxMHz: Double
}

/// Everything about the GPU for one sample. Fields the hardware/driver doesn't expose are nil (shown "—").
public struct GPUDetail: Codable, Sendable {
    /// Utilisation %, from PerformanceStatistics (device = any engine busy; renderer/tiler = those pipeline stages).
    public var deviceUtilization: Double?
    public var rendererUtilization: Double?
    public var tilerUtilization: Double?
    /// Bytes of system (unified) memory the GPU driver has in use / has allocated.
    public var memoryInUse: UInt64?
    public var memoryAllocated: UInt64?
    public var recoveryCount: Int?          // GPU restarts after a hang (driver recovery)
    public var activeResidency: Double?     // % of time the GPU was powered/active (IOReport)
    public var frequencyMHz: Double?        // average while active
    public var stateResidency: [Double]?    // % per P-state (P1 … Pn), lowest first
    public var stateMHz: [Double]?          // frequency of each P-state
    /// GPU power in W from the IOReport Energy Model; the cpu/ane/dram variants are the matching CPU, Neural Engine and
    /// memory channels. Without IOReport (Intel, or channels missing) all stay nil.
    public var powerWatts: Double?
    public var thermalLimited: Double?      // % of time the GPU was frequency-capped for temperature (CLTM)
    public var clients: [GPUClient]
    public var cpuClusters: [ClusterFrequency]
    public var cpuPowerWatts: Double?
    public var anePowerWatts: Double?
    public var dramPowerWatts: Double?
}

/// Static GPU facts (read once).
/// Vendor is decoded from the low byte of the little-endian PCI vendor-id (0x1002 AMD, 0x8086 Intel, 0x10de NVIDIA);
/// Apple's own GPUs (0x106b) fall through to the "Apple" default.
public struct GPUInfo: Sendable {
    public var model: String
    public var cores: Int?
    public var vendor: String
    public var frequencyRange: (min: Double, max: Double)?
    public var metal: [(String, String)]    // filled by the app (Metal is an app-level framework here)
}

/// Stateful (IOReport baseline, previous per-client GPU time); confined to the sampling queue. Only the first
/// IOAccelerator is read, so on Macs with two GPUs the second is not reported.
public final class GPUSampler: @unchecked Sendable {
    private let report = IOReportSampler()
    private var lastClientTime: [Int32: UInt64] = [:]
    private var lastClientSample: Date?
    /// DVFS tables keyed "E", "P", "GPU" (MHz), read once from Frequency.clusters(); used to turn state residency into MHz.
    private let freqs: [String: [Double]]

    public init() {
        var f: [String: [Double]] = [:]
        for c in Frequency.clusters() {
            if c.name.hasPrefix("Efficiency") { f["E"] = c.steps } else if c.name.hasPrefix("Performance") { f["P"] = c.steps } else if c.name == "GPU" { f["GPU"] = c.steps }
        }
        freqs = f
    }

    /// Model, core count, vendor and frequency range for the GPU header. Static; called on demand by the UI.
    public static func info() -> GPUInfo {
        var model = "GPU", cores: Int?, vendor = "Apple"
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            model = (IORegistryEntryCreateCFProperty(svc, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? model
            cores = (IORegistryEntryCreateCFProperty(svc, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            if let v = (IORegistryEntryCreateCFProperty(svc, "vendor-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data)?.first {
                vendor = [0x02: "AMD", 0x86: "Intel", 0xde: "NVIDIA"][v] ?? vendor
            }
        }
        let g = Frequency.clusters().first { $0.name == "GPU" }
        return GPUInfo(model: model, cores: cores, vendor: vendor, frequencyRange: g.map { ($0.minMHz, $0.maxMHz) }, metal: [])
    }

    /// Builds one GPUDetail. Each field is filled only if its source answered, so a missing source leaves nil (never 0).
    /// The PID was reused by a new process: forget the old one's accumulated GPU time.
    public func forget(pid: Int32) { lastClientTime[pid] = nil }

    public func sample() -> GPUDetail {
        var d = GPUDetail(clients: [], cpuClusters: [])
        // Accelerator performance statistics (all Macs)
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            if let ps = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                func n(_ k: String) -> Double? { (ps[k] as? NSNumber)?.doubleValue }
                d.deviceUtilization = n("Device Utilization %") ?? n("GPU Activity(%)")
                d.rendererUtilization = n("Renderer Utilization %")
                d.tilerUtilization = n("Tiler Utilization %")
                d.memoryInUse = n("In use system memory").map { UInt64($0) }
                d.memoryAllocated = n("Alloc system memory").map { UInt64($0) }
                d.recoveryCount = n("recoveryCount").map { Int($0) }
            }
            d.clients = clients(svc)
        }
        // IOReport: residency, frequency, power, thermal capping
        if let (chans, dt) = report.sample(), dt > 0 {
            // Energy channels report energy used during the interval in the channel's unit; dividing by dt gives watts.
            func watts(_ c: IOReportSampler.Channel) -> Double {
                let scale: Double = c.unit == "mJ" ? 1e-3 : c.unit == "uJ" ? 1e-6 : 1e-9   // nJ default
                return Double(c.value) * scale / dt
            }
            // CPU energy is published per cluster ("ECPU... CPU Energy", "PCPU... CPU Energy") and summed. otherEnergy tracks
            // whether any non-GPU energy channel moved at all (see the check after the loop).
            var cpuW = 0.0, cpuSeen = false, otherEnergy: Int64 = 0
            for c in chans {
                switch (c.group, c.subgroup) {
                case ("Energy Model", _):
                    if c.name != "GPU Energy" && c.name != "GPU" { otherEnergy += abs(c.value) }
                    if c.name == "GPU Energy" || c.name == "GPU" { d.powerWatts = watts(c) }
                    else if c.name.hasPrefix("ANE") { d.anePowerWatts = (d.anePowerWatts ?? 0) + watts(c) }
                    else if c.name.hasPrefix("DRAM") { d.dramPowerWatts = (d.dramPowerWatts ?? 0) + watts(c) }
                    else if c.name.hasSuffix("CPU Energy") || c.name == "CPU Energy" { cpuW += watts(c); cpuSeen = true }
                // GPUPH is the GPU's power/performance-state residency: OFF, IDLE, then P1...Pn from slowest to fastest. Active
                // residency is everything but OFF/IDLE; the average frequency weights each active state's DVFS-table
                // frequency by its
                // residency (the table's zero "off" entries were already filtered, so index i of `active` matches index i
                // of the table).
                case ("GPU Stats", "GPU Performance States") where c.name == "GPUPH":
                    let total = Double(c.states.reduce(0) { $0 + $1.residency })
                    guard total > 0 else { break }
                    let active = c.states.filter { $0.name != "OFF" && $0.name != "IDLE" }
                    let activeTotal = Double(active.reduce(0) { $0 + $1.residency })
                    d.activeResidency = activeTotal / total * 100
                    // The DVFS table can be shorter than the state list; states beyond it have no known frequency.
                    let table = freqs["GPU"] ?? []
                    let lastUsed = active.lastIndex { $0.residency > 0 } ?? 0
                    let shown = max(table.count, lastUsed + 1)
                    d.stateResidency = active.prefix(shown).map { Double($0.residency) / total * 100 }
                    if !table.isEmpty {
                        d.stateMHz = table
                        let known = zip(active, table)
                        let knownTotal = Double(known.reduce(0) { $0 + $1.0.residency })
                        if knownTotal > 0 { d.frequencyMHz = known.reduce(0) { $0 + Double($1.0.residency) * $1.1 } / knownTotal }
                    }
                // CLTM (closed-loop thermal management) residency: any state other than NO_CLTM means the GPU was capped
                // for heat.
                case ("GPU Stats", let sg) where sg.contains("CLTM"):
                    let total = Double(c.states.reduce(0) { $0 + $1.residency })
                    if total > 0 { d.thermalLimited = Double(c.states.filter { $0.name != "NO_CLTM" }.reduce(0) { $0 + $1.residency }) / total * 100 }
                // Per-cluster CPU residency (ECPU, PCPU, PCPU1, ...); the CPM channels are complex-level duplicates and skipped.
                // The MHz estimate is nil when the cluster was fully idle or the DVFS table is shorter than the state list,
                // rather
                // than mapping states to the wrong frequencies.
                case ("CPU Stats", "CPU Complex Performance States") where !c.name.hasSuffix("CPM") && !c.name.contains("CPM"):
                    let kind = c.name.hasPrefix("E") ? "E" : "P"
                    let total = Double(c.states.reduce(0) { $0 + $1.residency })
                    let active = c.states.filter { $0.name != "IDLE" && $0.name != "OFF" }
                    let activeTotal = Double(active.reduce(0) { $0 + $1.residency })
                    guard total > 0, let table = freqs[kind] else { break }
                    let mhz = activeTotal > 0 && table.count >= active.count
                        ? zip(active, table).reduce(0) { $0 + Double($1.0.residency) * $1.1 } / activeTotal : nil
                    let label = kind == "E" ? "E-cluster" : (c.name == "PCPU" ? "P-cluster" : "P-cluster \(c.name.dropFirst(4))")
                    d.cpuClusters.append(ClusterFrequency(name: label, mhz: mhz, active: activeTotal / total * 100, maxMHz: table.max() ?? 0))
                default: break
                }
            }
            // Without root, macOS may report every non-GPU energy channel as 0 (a running CPU never uses 0 J):
            // that is "not available", not zero.
            if otherEnergy == 0 { d.anePowerWatts = nil; d.dramPowerWatts = nil } else if cpuSeen { d.cpuPowerWatts = cpuW }
        }
        return d
    }

    /// Per-process GPU time from the accelerator's user clients ("AppUsage" → accumulatedGPUTime, ns).
    /// Each user client's IOUserClientCreator reads "pid 123, AppName". Clients are summed per PID. The share is the GPU-time
    /// delta divided by wall time, so it can exceed 100 when work overlaps on several GPU queues; it is clamped to 100.
    /// A PID seen for the first time reports 0 until the next sample, and history is keyed by bare PID; the `e.ns >= prev`
    /// check makes a recycled PID with a smaller counter read 0 instead of a bogus spike.
    private func clients(_ accel: io_service_t) -> [GPUClient] {
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var byPID: [Int32: (name: String, ns: UInt64, apis: Set<String>)] = [:]
        while case let c = IOIteratorNext(iter), c != 0 {
            defer { IOObjectRelease(c) }
            guard let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  let r = creator.range(of: #"pid (\d+), (.*)"#, options: .regularExpression) else { continue }
            let parts = creator[r].dropFirst(4).split(separator: ",", maxSplits: 1)
            guard let pid = Int32(parts[0]) else { continue }
            let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] ?? []
            var e = byPID[pid] ?? (String(parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""), 0, [])
            for u in usage {
                e.ns += (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
                if let api = u["API"] as? String { e.apis.insert(api) }
            }
            byPID[pid] = e
        }
        let now = Date()
        let dt = lastClientSample.map { now.timeIntervalSince($0) }
        var out: [GPUClient] = []
        for (pid, e) in byPID {
            var pct = 0.0
            if let dt, dt > 0, let prev = lastClientTime[pid], e.ns >= prev { pct = Double(e.ns - prev) / 1e9 / dt * 100 }
            out.append(GPUClient(pid: pid, name: e.name, percent: min(pct, 100), totalSeconds: Double(e.ns) / 1e9, apis: e.apis.sorted()))
        }
        lastClientTime = byPID.mapValues(\.ns); lastClientSample = now
        return out.sorted { $0.percent != $1.percent ? $0.percent > $1.percent : $0.totalSeconds > $1.totalSeconds }
    }
}
