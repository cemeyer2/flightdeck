import Foundation
// `measure` with `compare_to`: the same headline figures for two windows (the work, and a baseline run of it), their
// differences, and a plain-English verdict per figure, so an agent can answer "did my change make the tests slower or
// hungrier?" without doing arithmetic. Differences inside a noise band count as "about the same": a run is never
// identical twice, and calling a 2 % wobble a regression would send the agent chasing nothing.

/// The headline figures of one window, for one process tree when a filter is given, else for the whole Mac.
/// nil = not measured in that window (never 0).
public struct MeasureFigures: Sendable {
    public var durationSeconds: Double
    public var cpuSeconds: Double?
    public var avgCPUPercent: Double?
    public var peakMemory: Double?
    public var swapGrowth: Double?
    public var diskBytes: Double?
    public var networkBytes: Double?
    public var energyWh: Double?
    public var hottest: Double?

    public init(_ m: WindowMeasurement, tree: WindowMeasurement.TreeCost?) {
        durationSeconds = m.seconds
        // Whole-Mac levels only describe the tree when there is no filter; with one they are context (compared
        // separately), or a busy browser in one run would read as "your build got hungrier".
        if tree == nil {
            avgCPUPercent = m.cpu?.avg
            swapGrowth = m.swapEnd.flatMap { e in m.swapStart.map { e - $0 } }
            networkBytes = m.netIn.flatMap { i in m.netOut.map { i + $0 } }
            hottest = m.hottest?.peak
        }
        if let tree {
            cpuSeconds = tree.cpuSeconds; peakMemory = Double(tree.peakMemory); diskBytes = tree.diskBytes
            energyWh = tree.energyJoules.map { $0 / 3600 }
        } else {
            cpuSeconds = m.systemCPUSeconds; peakMemory = m.memoryUsed?.peak
            diskBytes = m.diskRead.flatMap { r in m.diskWrite.map { r + $0 } }
            energyWh = m.energyWh
        }
    }
}

/// One figure compared between the measured window and the baseline.
public struct MetricDelta: Sendable {
    public enum Verdict: String, Sendable { case same = "about the same", higher, lower }
    public var key: String
    public var current: Double
    public var baseline: Double
    public var change: Double { current - baseline }
    /// Relative change in % of the baseline; nil when the baseline is 0 (any change is "new").
    public var percent: Double? { baseline != 0 ? change / abs(baseline) * 100 : nil }
    public var verdict: Verdict
    /// "12% higher", "2.3× higher", "about the same".
    public var words: String {
        switch verdict {
        case .same: return "about the same"
        case .higher, .lower:
            guard let p = percent else { return verdict == .higher ? "new (baseline was 0)" : "lower" }
            if verdict == .higher && p >= 100 { return String(format: "%.1f× higher", current / baseline) }
            return String(format: "%.0f%% %@", abs(p), verdict.rawValue)
        }
    }
}

public enum MeasureCompare {
    /// Relative band treated as noise, and per-figure absolute floors below which a change is noise however large in %.
    /// The floors are roughly what varies between two idle minutes on a laptop.
    public static let relativeNoise = 5.0
    static let floors: [String: Double] = [
        "duration_s": 1, "cpu_seconds": 1, "avg_cpu_percent": 2, "peak_memory": 50e6, "swap_growth": 50e6,
        "disk_bytes": 10e6, "network_bytes": 1e6, "energy_wh": 0.05, "hottest_c": 2,
    ]
    /// Figures where higher means "slower or hungrier". All of them, today; listed so a new one is a deliberate choice.
    static let order = ["duration_s", "cpu_seconds", "avg_cpu_percent", "peak_memory", "swap_growth", "disk_bytes",
                        "network_bytes", "energy_wh", "hottest_c"]

    public static func delta(_ key: String, _ current: Double?, _ baseline: Double?) -> MetricDelta? {
        guard let current, let baseline else { return nil }
        let diff = current - baseline
        let floor = floors[key] ?? 0
        let rel = baseline != 0 ? abs(diff) / abs(baseline) * 100 : (diff == 0 ? 0 : .infinity)
        let v: MetricDelta.Verdict = abs(diff) < floor || rel < relativeNoise ? .same : (diff > 0 ? .higher : .lower)
        return MetricDelta(key: key, current: current, baseline: baseline, verdict: v)
    }

    /// Deltas in a fixed order, skipping figures either window didn't measure.
    public static func compare(_ cur: MeasureFigures, _ base: MeasureFigures) -> [MetricDelta] {
        let pairs: [String: (Double?, Double?)] = [
            "duration_s": (cur.durationSeconds, base.durationSeconds), "cpu_seconds": (cur.cpuSeconds, base.cpuSeconds),
            "avg_cpu_percent": (cur.avgCPUPercent, base.avgCPUPercent), "peak_memory": (cur.peakMemory, base.peakMemory),
            "swap_growth": (cur.swapGrowth, base.swapGrowth), "disk_bytes": (cur.diskBytes, base.diskBytes),
            "network_bytes": (cur.networkBytes, base.networkBytes), "energy_wh": (cur.energyWh, base.energyWh),
            "hottest_c": (cur.hottest, base.hottest),
        ]
        return order.compactMap { k in pairs[k].flatMap { delta(k, $0.0, $0.1) } }
    }

    static let names: [String: String] = [
        "duration_s": "took", "cpu_seconds": "CPU time", "avg_cpu_percent": "average CPU load", "peak_memory": "peak memory",
        "swap_growth": "swap growth", "disk_bytes": "disk I/O", "network_bytes": "network traffic", "energy_wh": "energy",
        "hottest_c": "peak temperature",
    ]

    /// One or two sentences: the overall answer first ("slower and hungrier", "no meaningful change"), then each figure
    /// that moved beyond the noise band. `subject` names what was measured ("xcodebuild and its children", "the Mac").
    public static func verdict(_ deltas: [MetricDelta], subject: String) -> String {
        let moved = deltas.filter { $0.verdict != .same }
        guard !moved.isEmpty else {
            return "No meaningful change: every figure for \(subject) is within \(Int(relativeNoise))% (or a small absolute margin) of the baseline."
        }
        // "Slower" is about wall-clock time only; more CPU time in the same time is more work, so it counts as hungrier.
        let time = Set(["duration_s"]), hunger = Set(["cpu_seconds", "peak_memory", "swap_growth", "energy_wh", "disk_bytes"])
        func dir(_ keys: Set<String>) -> MetricDelta.Verdict? {
            let m = moved.filter { keys.contains($0.key) }
            if m.contains(where: { $0.verdict == .higher }) && !m.contains(where: { $0.verdict == .lower }) { return .higher }
            if m.contains(where: { $0.verdict == .lower }) && !m.contains(where: { $0.verdict == .higher }) { return .lower }
            return m.isEmpty ? nil : .same   // mixed
        }
        var head: [String] = []
        switch dir(time) { case .higher: head.append("slower"); case .lower: head.append("faster"); case .same, nil: break }
        switch dir(hunger) { case .higher: head.append("hungrier"); case .lower: head.append("leaner"); case .same: head.append("mixed on resources"); case nil: break }
        let parts = moved.map { d in
            d.key == "duration_s" ? "it took \(d.words.replacingOccurrences(of: "higher", with: "longer").replacingOccurrences(of: "lower", with: "less time"))"
                : "\(names[d.key] ?? d.key) \(d.words)"
        }
        let lead = head.isEmpty ? "Changed compared with the baseline" : "Compared with the baseline, \(subject) was \(head.joined(separator: " and "))"
        return lead + ": " + parts.joined(separator: ", ") + "."
    }
}
