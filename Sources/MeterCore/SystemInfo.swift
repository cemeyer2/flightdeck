import Foundation
import IOKit

public struct InfoItem: Identifiable, Hashable, Sendable {
    public var id: String { section + key }
    public var section: String
    public var key: String
    public var value: String
}

public enum SystemInfo {
    static func ioString(_ cls: String, _ key: String) -> String? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls))
        guard s != 0 else { return nil }; defer { IOObjectRelease(s) }
        let v = IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        if let str = v as? String { return str }
        if let d = v as? Data { return String(decoding: d.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return nil
    }

    public static func gpuInfo() -> [String] {
        var out: [String] = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any] {
                let model = d["model"] as? String ?? (d["IOClass"] as? String ?? "GPU")
                let cores = (d["gpu-core-count"] as? NSNumber).map { " (\($0) cores)" } ?? ""
                out.append(model + cores)
            }
        }
        return out
    }

    public static func gpuUtilization() -> Measured<Double> {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard s != 0 else { return .unavailable("no accelerator") }; defer { IOObjectRelease(s) }
        guard let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let u = (stats["Device Utilization %"] as? NSNumber) ?? (stats["GPU Activity(%)"] as? NSNumber) else {
            return .unavailable("not reported")
        }
        return .value(u.doubleValue)
    }

    public static func collect() -> [InfoItem] {
        var items: [InfoItem] = []
        func add(_ s: String, _ k: String, _ v: String?) { if let v, !v.isEmpty { items.append(InfoItem(section: s, key: k, value: v)) } }
        let pi = ProcessInfo.processInfo
        add("System", "Computer Name", Host.current().localizedName)
        add("System", "Model", Sysctl.string("hw.model"))
        add("System", "macOS", pi.operatingSystemVersionString)
        add("System", "Kernel", Sysctl.string("kern.version")?.components(separatedBy: ":").first)
        add("System", "Build", Sysctl.string("kern.osversion"))
        add("System", "Serial Number", ioString("IOPlatformExpertDevice", "IOPlatformSerialNumber"))
        add("System", "Hardware UUID", ioString("IOPlatformExpertDevice", "IOPlatformUUID"))
        if let boot = Sysctl.timeval("kern.boottime") {
            add("System", "Booted", DateFormatter.localizedString(from: boot, dateStyle: .medium, timeStyle: .short))
            add("System", "Uptime", Fmt.duration(Date().timeIntervalSince(boot)))
        }
        add("Processor", "Chip", Sysctl.string("machdep.cpu.brand_string"))
        add("Processor", "Architecture", Sysctl.int("hw.optional.arm64") == 1 ? "arm64 (Apple silicon)" : "x86_64")
        add("Processor", "Physical Cores", Sysctl.int("hw.physicalcpu").map(String.init))
        add("Processor", "Logical Processors", Sysctl.int("hw.logicalcpu").map(String.init))
        if (Sysctl.int("hw.nperflevels") ?? 1) >= 2 {
            add("Processor", "Performance Cores", Sysctl.int("hw.perflevel0.logicalcpu").map(String.init))
            add("Processor", "Efficiency Cores", Sysctl.int("hw.perflevel1.logicalcpu").map(String.init))
            add("Processor", "P-core L2 Cache", Sysctl.int("hw.perflevel0.l2cachesize").map { Fmt.bytes(Double($0)) })
            add("Processor", "E-core L2 Cache", Sysctl.int("hw.perflevel1.l2cachesize").map { Fmt.bytes(Double($0)) })
        }
        add("Processor", "L1 Data Cache", Sysctl.int("hw.l1dcachesize").map { Fmt.bytes(Double($0)) })
        add("Processor", "Cache Line", Sysctl.int("hw.cachelinesize").map { "\($0) bytes" })
        add("Processor", "Translated (Rosetta)", Sysctl.int("sysctl.proc_translated") == 1 ? "Yes" : "No")
        add("Memory", "Installed", Sysctl.int("hw.memsize").map { Fmt.bytes(Double($0)) })
        add("Memory", "Page Size", Sysctl.int("hw.pagesize").map { "\($0) bytes" })
        for (i, g) in gpuInfo().enumerated() { add("Graphics", "GPU \(i + 1)", g) }
        for v in DiskSampler.volumes() {
            add("Storage", v.name, "\(Fmt.bytes(v.capacity)) \(v.fileSystem) — \(Fmt.bytes(v.available)) free")
        }
        add("Security", "System Integrity Protection", csrStatus())
        return items
    }

    static func csrStatus() -> String {
        let out = Shell.run("/usr/bin/csrutil", ["status"]) ?? ""
        if out.contains("enabled") { return "Enabled" }
        if out.contains("disabled") { return "Disabled" }
        return "Unknown"
    }
}

public enum Shell {
    /// Runs a tool and returns stdout, or nil on failure. Times out after `timeout` seconds.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); timer.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}
