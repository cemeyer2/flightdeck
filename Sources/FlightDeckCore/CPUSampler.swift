import Foundation
import Darwin

public enum CoreKind: String, Codable, Sendable { case performance, efficiency, unknown }

public struct CoreSample: Codable, Sendable {
    public var index: Int
    public var kind: CoreKind
    public var user: Double   // 0..100
    public var system: Double
    public var total: Double { user + system }
}

public struct CPUSample: Codable, Sendable {
    public var total: Measured<Double>
    public var user: Measured<Double>
    public var system: Measured<Double>
    public var cores: [CoreSample]
    public var loadAverage: [Double]
}

public final class CPUSampler {
    private var previous: [[UInt32]] = []
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let logicalCount: Int

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
            let base = Int(CPU_STATE_MAX) * i
            current.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { previous = current }
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
        guard tt > 0 else {
            return CPUSample(total: .unavailable("no ticks"), user: .unavailable(""), system: .unavailable(""), cores: cores, loadAverage: load)
        }
        return CPUSample(total: .value((tu + ts) / tt * 100), user: .value(tu / tt * 100),
                         system: .value(ts / tt * 100), cores: cores, loadAverage: load)
    }
}
