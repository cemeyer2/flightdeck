import Foundation
import Darwin

// System-wide and per-core CPU usage from Mach host_processor_info tick counters, plus load averages. Called once per
// tick by Sampler on the sampling queue.
/// Core type from the hw.perflevel* sysctls; `.unknown` on Intel or single-level chips.
public enum CoreKind: String, Codable, Sendable { case performance, efficiency, unknown }

/// One logical CPU over the last interval: % of that core's time in user (incl. nice) and system mode.
public struct CoreSample: Codable, Sendable {
    public var index: Int
    public var kind: CoreKind
    public var user: Double   // 0..100
    public var system: Double
    public var total: Double { user + system }
}

/// Whole-machine CPU over the last interval as % of all cores (0...100, not % of one core). Measured values are
/// unavailable on the first sample ("warming up") or if the Mach call fails. `loadAverage` is the 1/5/15-minute
/// run-queue averages from getloadavg.
public struct CPUSample: Codable, Sendable {
    public var total: Measured<Double>
    public var user: Measured<Double>
    public var system: Measured<Double>
    public var cores: [CoreSample]
    public var loadAverage: [Double]
}

/// Stateful: keeps the previous per-core tick counters to diff against. Confined to the sampling queue.
public final class CPUSampler {
    /// Per core, CPU_STATE_MAX counters (user, system, idle, nice) in scheduler ticks, cumulative since boot.
    private var previous: [[UInt32]] = []
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let logicalCount: Int

    /// Topology is read once. On Apple silicon perflevel0 is the performance cluster and perflevel1 the efficiency one.
    public init() {
        logicalCount = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        let levels = Sysctl.int("hw.nperflevels") ?? 1
        if levels >= 2 {
            performanceCores = Sysctl.int("hw.perflevel0.logicalcpu") ?? logicalCount
            efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
        } else {
            performanceCores = logicalCount; efficiencyCores = 0
        }
    }

    /// Apple silicon enumerates efficiency cores first.
    public func kind(of index: Int) -> CoreKind {
        if efficiencyCores == 0 { return .unknown }
        return index < efficiencyCores ? .efficiency : .performance
    }

    public func sample() -> CPUSample {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        // host_processor_info returns an out-of-line Mach array of `integer_t` (count * CPU_STATE_MAX entries) that we own
        // and must vm_deallocate, done by the defer below.
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        guard kr == KERN_SUCCESS, let info else {
            return CPUSample(total: .unavailable("host_processor_info failed"), user: .unavailable(""),
                             system: .unavailable(""), cores: [], loadAverage: load)
        }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        var current: [[UInt32]] = []
        for i in 0..<Int(count) {
            // The kernel counters are 32-bit and wrap; reading them as UInt32 lets `&-` below give the correct delta across
            // a wrap.
            let base = Int(CPU_STATE_MAX) * i
            current.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { previous = current }
        // No baseline yet (or the CPU count changed): report "warming up" rather than a misleading 0%.
        guard previous.count == current.count else {
            return CPUSample(total: .unavailable("warming up"), user: .unavailable("warming up"),
                             system: .unavailable("warming up"), cores: [], loadAverage: load)
        }
        var cores: [CoreSample] = []
        var tu = 0.0, ts = 0.0, tt = 0.0
        for i in 0..<current.count {
            let d = (0..<Int(CPU_STATE_MAX)).map { Double(current[i][$0] &- previous[i][$0]) }
            let user = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let sys = d[Int(CPU_STATE_SYSTEM)]
            let total = d.reduce(0, +)
            tu += user; ts += sys; tt += total
            cores.append(CoreSample(index: i, kind: kind(of: i),
                                    user: total > 0 ? user / total * 100 : 0,
                                    system: total > 0 ? sys / total * 100 : 0))
        }
        // Two samples inside the same scheduler tick have nothing to divide by.
        guard tt > 0 else {
            return CPUSample(total: .unavailable("no ticks"), user: .unavailable(""), system: .unavailable(""), cores: cores, loadAverage: load)
        }
        return CPUSample(total: .value((tu + ts) / tt * 100), user: .value(tu / tt * 100),
                         system: .value(ts / tt * 100), cores: cores, loadAverage: load)
    }
}
