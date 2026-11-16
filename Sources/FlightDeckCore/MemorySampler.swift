import Foundation
import Darwin

public struct MemorySample: Codable, Sendable {
    public var total: UInt64
    public var used: UInt64          // app + wired + compressed
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64        // file-backed + purgeable
    public var free: UInt64
    public var swapUsed: Measured<Double>
    public var swapTotal: Measured<Double>
    public var pressure: Measured<Double>      // 0..100 (derived from kern.memorystatus_level)
    public var pressureLevel: Int              // 1 normal, 2 warn, 4 critical
    public var pageIns: UInt64
    public var pageOuts: UInt64
    public var compressions: UInt64
    public var decompressions: UInt64
    /// Pages swapped to / from disk since boot, and the page size (optional: absent in older traces).
    public var swapIns: UInt64? = nil
    public var swapOuts: UInt64? = nil
    public var pageSize: UInt64? = nil
}

public final class MemorySampler {
    public init() {}
    public func sample() -> MemorySample {
        let total = UInt64(Sysctl.int("hw.memsize") ?? 0)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        var swap = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        let level = Sysctl.int("kern.memorystatus_level")
        let plevel = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        guard kr == KERN_SUCCESS else {
            return MemorySample(total: total, used: 0, app: 0, wired: 0, compressed: 0, cached: 0, free: 0,
                                swapUsed: .unavailable("n/a"), swapTotal: .unavailable("n/a"),
                                pressure: .unavailable("n/a"), pressureLevel: plevel,
                                pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0)
        }
        let internalPages = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let app = internalPages * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        let free = UInt64(stats.free_count) * page
        return MemorySample(
            total: total, used: app + wired + compressed, app: app, wired: wired, compressed: compressed,
            cached: cached, free: free,
            swapUsed: swapOK ? .value(Double(swap.xsu_used)) : .unavailable("vm.swapusage"),
            swapTotal: swapOK ? .value(Double(swap.xsu_total)) : .unavailable("vm.swapusage"),
            pressure: level.map { .value(Double(100 - $0)) } ?? .unavailable("memorystatus_level"),
            pressureLevel: plevel,
            pageIns: UInt64(stats.pageins), pageOuts: UInt64(stats.pageouts),
            compressions: UInt64(stats.compressions), decompressions: UInt64(stats.decompressions),
            swapIns: UInt64(stats.swapins), swapOuts: UInt64(stats.swapouts), pageSize: page)
    }
}
