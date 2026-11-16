import Foundation
import IOKit

// Static CPU/GPU frequency information for the Tools view and for GPUSampler (which uses the GPU table to turn
// IOReport P-state residency into an average MHz). Also parses `pmset -g` for the power-settings list.
/// The DVFS (frequency) steps one cluster can run at, as advertised by the hardware.
public struct ClusterFrequencies: Sendable, Hashable {
    /// "Efficiency cluster", "Performance cluster", "GPU", or "CPU" on Intel.
    public var name: String
    public var steps: [Double]   // MHz
    /// Highest advertised step in MHz; 0 only if the table is empty.
    public var maxMHz: Double { steps.max() ?? 0 }
    /// Lowest non-zero step in MHz (zero entries are "off" states, not a frequency).
    public var minMHz: Double { steps.filter { $0 > 0 }.min() ?? 0 }
}

public enum Frequency {
    /// Reads DVFS tables from the power manager node (Apple silicon). These are the advertised steps only; the live
    /// average frequency is computed separately by GPUSampler from IOReport state residency.
    /// The tables live on the `pmgr` AppleARMIODevice in the IORegistry; falls back to the Intel sysctls when that
    /// node or its tables are absent. Returns [] if neither source exists. Cheap enough to call on demand.
    public static func clusters() -> [ClusterFrequencies] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iter) == KERN_SUCCESS else { return intelFallback() }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            // IORegistryEntryGetName writes into an io_name_t, which is a 128-byte C string.
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(s, &name)
            guard String(cString: name) == "pmgr" else { continue }
            // Each `voltage-states*` property is raw Data of UInt32 pairs: (frequency, voltage). Taking every
            // even word yields the frequency column. The unit differs by chip generation, so it is inferred from
            // magnitude: a max above 100,000,000 can only be Hz (that would be 100 GHz in kHz).
            func table(_ key: String) -> [Double] {
                guard let d = IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return [] }
                let words = d.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
                let freqs = stride(from: 0, to: words.count, by: 2).map { Double(words[$0]) }
                let mx = freqs.max() ?? 0
                let scale = mx > 100_000_000 ? 1e6 : 1e3   // Hz on M1–M3, kHz on later chips
                return freqs.map { $0 / scale }.filter { $0 > 0 }
            }
            // The property numbering is Apple's internal domain index: 1 = E-cluster SRAM, 5 = P-cluster SRAM,
            // 9 = GPU. Chips with extra P clusters expose more tables; only the first P table is shown.
            var out: [ClusterFrequencies] = []
            let e = table("voltage-states1-sram"); if !e.isEmpty { out.append(.init(name: "Efficiency cluster", steps: e)) }
            let p = table("voltage-states5-sram"); if !p.isEmpty { out.append(.init(name: "Performance cluster", steps: p)) }
            let g = table("voltage-states9"); if !g.isEmpty { out.append(.init(name: "GPU", steps: g)) }
            if !out.isEmpty { return out }
        }
        return intelFallback()
    }

    /// Intel Macs publish only min/max nominal frequency (Hz) via sysctl, so the "table" is those two points.
    /// These sysctls don't exist on Apple silicon, which yields [].
    static func intelFallback() -> [ClusterFrequencies] {
        guard let hz = Sysctl.int("hw.cpufrequency_max") else { return [] }
        return [.init(name: "CPU", steps: [Double(Sysctl.int("hw.cpufrequency_min") ?? hz) / 1e6, Double(hz) / 1e6])]
    }

    /// Current power-management settings as (key, value) pairs, parsed from `pmset -g` (there is no public API
    /// returning the same merged view). Section headers such as "Currently in use:" are skipped; each remaining
    /// line is split at its first space or tab. Returns [] if pmset can't be run.
    public static func pmsetSettings() -> [(String, String)] {
        guard let out = Shell.run("/usr/bin/pmset", ["-g"]) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasSuffix(":"), let r = t.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            return (String(t[..<r]), t[r...].trimmingCharacters(in: .whitespaces))
        }
    }
}
