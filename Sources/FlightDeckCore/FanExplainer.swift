import Foundation
// "Why is the fan loud?": turns one Snapshot into a plain-English explanation that connects fan speed, the hottest
// sensor, whether macOS is holding the CPU/GPU back for heat, and which apps are producing the heat. Pure (no system
// access), so the Thermals card and tests share exactly the same wording. Unmeasured inputs are left out of the
// explanation rather than guessed.

/// The explanation shown on the Thermals tab.
public struct FanExplanation: Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case info, caution, warning
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    /// An app and its share of the heat (0...1), measured by energy where macOS reports it, otherwise by CPU.
    public struct Culprit: Sendable, Equatable {
        public var name: String
        public var share: Double
    }
    public var severity: Severity
    /// One sentence answering the question, e.g. "Fans at 4,200 rpm (idle ~1,200) because the CPU is at 92 °C; …".
    public var headline: String
    /// Supporting facts, one per line.
    public var details: [String]
    public var culprits: [Culprit]
    /// True when culprit shares are by energy, false when by CPU time.
    public var byEnergy: Bool
    /// False on fanless Macs, where the explanation is about throttling instead.
    public var hasFans: Bool
}

public enum FanExplainer {
    /// A fan counts as "above idle" above this multiple of its minimum speed. Apple silicon fans often stop entirely
    /// when cool (0 rpm, below the published minimum), and sit at the minimum when barely needed; both are idle.
    static let aboveIdleFactor = 1.2
    /// Without a published minimum, a fan running above this fraction of its maximum (or, with no maximum either, above
    /// `fallbackRPM`) counts as above idle.
    static let fallbackFraction = 0.35, fallbackRPM = 2500.0
    /// Apps below this share aren't named as heat sources.
    static let culpritShare = 0.15

    /// nil when there is nothing to explain: fans at idle (or unknown), thermal state nominal, GPU not heat-limited.
    public static func explain(_ s: Snapshot) -> FanExplanation? {
        let fans = s.power.fans
        let busy = (fans ?? []).filter(isAboveIdle)
        let state = s.power.thermalState
        let gpuLimited = s.gpuDetail?.thermalLimited
        guard !busy.isEmpty || state >= 1 || (gpuLimited ?? 0) > 1 else { return nil }

        let hot = hottestSensor(s)
        let (culprits, byEnergy) = heatSources(s)
        // e.g. "Photos is responsible for ~60% of the power draw" / "… ~60% of the CPU load"
        let blame: String? = culprits.first.map { c in
            "\(c.name) is responsible for ~\(Int((c.share * 100).rounded()))% of the \(byEnergy ? "power draw" : "CPU load")"
        }
        let heat = hot.map { "\($0.part) is at \(String(format: "%.0f", $0.celsius)) °C" }

        var headline: String
        if let top = busy.max(by: { $0.rpm < $1.rpm }) {
            let who = (fans?.count ?? 0) > 1 ? "Fans at" : "Fan at"
            let ref = top.minRPM.map { "idle ~\(group($0))" } ?? top.maxRPM.map { "max \(group($0))" }
            headline = "\(who) \(group(top.rpm)) rpm" + (ref.map { " (\($0))" } ?? "")
            if let heat { headline += " because \(heat)" }
        } else if fans?.isEmpty == true {
            // Known fanless (e.g. MacBook Air): heat is shed by slowing down, which is what the user will notice.
            headline = "This Mac has no fans, so it cools down by slowing the CPU and GPU"
            if let heat { headline += "; \(heat)" }
        } else {
            headline = "Thermal pressure is \(stateName(state).lowercased())" + (fans == nil ? "" : " while the fans are still near idle")
            if let heat { headline += "; \(heat)" }
        }
        if let blame { headline += "; \(blame)" }
        headline += "."

        var details: [String] = []
        for f in fans ?? [] {
            var line = "Fan \(f.index + 1): \(group(f.rpm)) rpm"
            if let mx = f.maxRPM, let fr = f.fraction { line += ", \(Int((fr * 100).rounded()))% of its \(group(mx)) rpm maximum" }
            if let mn = f.minRPM { line += " (minimum \(group(mn)))" }
            details.append(line)
        }
        switch state {
        case 0: details.append("macOS isn't holding the CPU back for heat (thermal state nominal).")
        case 1: details.append("Thermal state is fair: macOS may start trimming performance slightly to keep temperatures in check.")
        case 2: details.append("Thermal state is serious: macOS is slowing the CPU and GPU to cool down, so apps will feel slower.")
        default: details.append("Thermal state is critical: macOS is throttling heavily to protect the hardware.")
        }
        // thermalLimited is nil when the GPU's thermal residency isn't reported; then nothing is claimed either way.
        if let g = gpuLimited {
            details.append(g > 1 ? "The GPU was clock-limited by temperature \(Int(g.rounded()))% of the time."
                                 : "The GPU is not being limited by heat.")
        }
        if !culprits.isEmpty {
            details.append("Heat sources: " + culprits.map { "\($0.name) ~\(Int(($0.share * 100).rounded()))%" }.joined(separator: ", ")
                           + (byEnergy ? " of the energy used by apps." : " of the CPU time used by apps (energy isn't reported)."))
        }
        // kernel_task's CPU climbs under heat because macOS idles cores on purpose; it is the cure, not the cause.
        if let k = s.processes.first(where: { $0.pid == 0 }), k.cpu >= 50, state >= 1 {
            details.append("kernel_task is at \(Int(k.cpu.rounded()))% CPU: that is macOS keeping cores idle to cool down, not the source of the heat.")
        }
        let fastest = busy.compactMap(\.fraction).max() ?? 0
        let severity: FanExplanation.Severity = state >= 2 ? .warning : (state == 1 || fastest >= 0.7 || (gpuLimited ?? 0) > 10) ? .caution : .info
        return FanExplanation(severity: severity, headline: headline, details: details, culprits: culprits,
                              byEnergy: byEnergy, hasFans: fans.map { !$0.isEmpty } ?? true)
    }

    static func isAboveIdle(_ f: FanReading) -> Bool {
        if let mn = f.minRPM, mn > 0 { return f.rpm > mn * aboveIdleFactor }
        if let mx = f.maxRPM, mx > 0 { return f.rpm > mx * fallbackFraction }
        return f.rpm > fallbackRPM
    }

    /// The hottest component sensor, named in plain English. "tcal" sensors are skipped: they are calibration
    /// references that read well above every real component on Apple silicon and would blame nothing in particular.
    static func hottestSensor(_ s: Snapshot) -> (part: String, celsius: Double)? {
        if let t = s.power.temperatures.filter({ !$0.name.lowercased().contains("tcal") }).max(by: { $0.celsius < $1.celsius }) {
            return (part(of: t.name), t.celsius)
        }
        return s.power.hottest.value.map { ("the hottest sensor", $0) }
    }

    /// Maps raw sensor names to the component they measure. Apple silicon "PMU tdie/tdev/TP" sensors sit on the SoC
    /// die, which holds the CPU and GPU together, so they read as "the chip".
    static func part(of name: String) -> String {
        let n = name.lowercased()
        if n.contains("gpu") { return "the GPU" }
        if n.contains("cpu") || n.contains("pacc") || n.contains("eacc") { return "the CPU" }
        if n.contains("tdie") || n.contains("tdev") || n.hasPrefix("pmu") || n.contains("soc") { return "the chip" }
        if n.contains("nand") || n.contains("ssd") { return "the SSD" }
        if n.contains("battery") || n.contains("gas gauge") { return "the battery" }
        if n.contains("ambient") || n.contains("airflow") { return "the air inside" }
        return "the \(name) sensor"
    }

    /// Apps with at least `culpritShare` of app energy (or of app CPU, when no process reports energy), top 3.
    /// kernel_task is excluded: see the note in `explain`.
    static func heatSources(_ s: Snapshot) -> ([FanExplanation.Culprit], Bool) {
        let apps = AppUsage.aggregate(s.processes.filter { $0.pid != 0 })
        let energy = apps.compactMap(\.energyWatts).reduce(0, +)
        let byEnergy = energy > 0.1
        let total = byEnergy ? energy : apps.map(\.cpu).reduce(0, +)
        guard total > 0 else { return ([], byEnergy) }
        let c = apps.map { FanExplanation.Culprit(name: $0.name, share: (byEnergy ? $0.energyWatts ?? 0 : $0.cpu) / total) }
            .filter { $0.share >= culpritShare }.sorted { $0.share > $1.share }.prefix(3)
        return (Array(c), byEnergy)
    }

    static func stateName(_ s: Int) -> String { ["Nominal", "Fair", "Serious", "Critical"][min(max(s, 0), 3)] }

    /// Whole rpm with comma grouping ("4,200"), independent of the user's locale so the sentence reads the same in tests.
    static func group(_ v: Double) -> String {
        let digits = String(Int(v.rounded()))
        var out = ""
        for (i, ch) in digits.reversed().enumerated() { if i > 0 && i % 3 == 0 { out.append(",") }; out.append(ch) }
        return String(out.reversed())
    }
}
