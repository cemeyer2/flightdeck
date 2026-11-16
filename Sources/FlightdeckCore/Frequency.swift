import Foundation
import IOKit

public struct ClusterFrequencies: Sendable, Hashable {
    public var name: String
    public var steps: [Double]   // MHz
    public var maxMHz: Double { steps.max() ?? 0 }
    public var minMHz: Double { steps.filter { $0 > 0 }.min() ?? 0 }
}

public enum Frequency {
    /// Reads DVFS tables from the power manager node (Apple silicon). Live per-core frequency requires
    /// private IOReport channels, so it is reported unavailable rather than estimated.
    public static func clusters() -> [ClusterFrequencies] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iter) == KERN_SUCCESS else { return intelFallback() }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(s, &name)
            guard String(cString: name) == "pmgr" else { continue }
            func table(_ key: String) -> [Double] {
                guard let d = IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return [] }
                let words = d.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
                let freqs = stride(from: 0, to: words.count, by: 2).map { Double(words[$0]) }
                let mx = freqs.max() ?? 0
                let scale = mx > 100_000_000 ? 1e6 : 1e3   // Hz on M1–M3, kHz on later chips
                return freqs.map { $0 / scale }.filter { $0 > 0 }
            }
            var out: [ClusterFrequencies] = []
            let e = table("voltage-states1-sram"); if !e.isEmpty { out.append(.init(name: "Efficiency cluster", steps: e)) }
            let p = table("voltage-states5-sram"); if !p.isEmpty { out.append(.init(name: "Performance cluster", steps: p)) }
            let g = table("voltage-states9"); if !g.isEmpty { out.append(.init(name: "GPU", steps: g)) }
            if !out.isEmpty { return out }
        }
        return intelFallback()
    }

    static func intelFallback() -> [ClusterFrequencies] {
        guard let hz = Sysctl.int("hw.cpufrequency_max") else { return [] }
        return [.init(name: "CPU", steps: [Double(Sysctl.int("hw.cpufrequency_min") ?? hz) / 1e6, Double(hz) / 1e6])]
    }

    public static func pmsetSettings() -> [(String, String)] {
        guard let out = Shell.run("/usr/bin/pmset", ["-g"]) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasSuffix(":"), let r = t.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            return (String(t[..<r]), t[r...].trimmingCharacters(in: .whitespaces))
        }
    }
}
