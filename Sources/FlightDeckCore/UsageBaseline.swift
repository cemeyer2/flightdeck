import Foundation
// "Normal for this Mac": a per-app baseline of typical daily use, built from the daily records, and the findings that
// compare an app's current use with it ("Safari is using 3× its usual memory (usually ~1.8 GB)").
//
// Unlike the Analyzer's 24 h baseline (whole machine, from the black box), this is per app and spans weeks, so it
// knows that Xcode routinely takes 6 GB while Notes doesn't. To avoid crying wolf it only speaks with several days of
// history, and only when the excess is large in both relative and absolute terms and has lasted for minutes.

/// An app's typical use: the median over recent days of its daily averages while running. The median ignores a few
/// unusual days (a big export, a stuck tab) that would drag a mean.
public struct AppBaseline: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Days the baseline is built from.
    public var days: Int
    /// Typical footprint while running, bytes.
    public var memory: Double
    /// Typical CPU % (of one core) while running.
    public var cpu: Double

    /// Limits that decide when a baseline exists and when it fires.
    public struct Rules: Sendable {
        /// Days of history (each with at least `minRunning` seconds of the app running) before a baseline exists.
        public var minDays = 5
        /// Only the last `lookbackDays` count, so the baseline follows changing habits.
        public var lookbackDays = 30
        public var minRunning: TimeInterval = 1800
        /// "Large": at least `ratio` × usual AND at least the absolute margin above it.
        public var ratio = 3.0
        public var memoryMargin = 1e9
        public var cpuMargin = 50.0
        /// "Sustained": over the limit at every look for this long.
        public var sustain: TimeInterval = 10 * 60
        public init() {}
    }

    /// Baselines from closed days (`days` oldest first, today excluded by the caller). Apps without `minDays` qualifying
    /// days get none, which is what keeps a young history from producing findings.
    public static func build(from days: [DayRecord], now: Date, rules: Rules = Rules()) -> [String: AppBaseline] {
        let from = now.addingTimeInterval(-Double(rules.lookbackDays) * 86_400)
        var mem: [String: [Double]] = [:], cpu: [String: [Double]] = [:], names: [String: String] = [:]
        for d in days where d.start >= from {
            for a in d.apps where a.runningSeconds >= rules.minRunning {
                if let m = a.averageMemory { mem[a.id, default: []].append(m) }
                if let c = a.averageCPU { cpu[a.id, default: []].append(c) }
                names[a.id] = a.name
            }
        }
        var out: [String: AppBaseline] = [:]
        for (id, m) in mem where m.count >= rules.minDays {
            out[id] = AppBaseline(id: id, name: names[id] ?? id, days: m.count, memory: median(m), cpu: median(cpu[id] ?? [0]))
        }
        return out
    }

    /// How many more days of history the app needs before it has a baseline (0 when it has one).
    public static func daysNeeded(_ id: String, in days: [DayRecord], now: Date, rules: Rules = Rules()) -> Int {
        let from = now.addingTimeInterval(-Double(rules.lookbackDays) * 86_400)
        let have = days.filter { $0.start >= from && ($0.apps.first { $0.id == id }?.runningSeconds ?? 0) >= rules.minRunning }.count
        return max(rules.minDays - have, 0)
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

/// Tracks, per app and metric, how long current use has been above its baseline's limit, and builds findings once
/// that has lasted `Rules.sustain`. Fed by `DailyLog` once per app pass (every ~10 s), O(apps).
struct BaselineWatch {
    var rules = AppBaseline.Rules()
    /// "mem:<id>" / "cpu:<id>" → when the current unbroken excess began.
    private var overSince: [String: Date] = [:]
    private(set) var findings: [Finding] = []

    /// `apps`: current use per app (CPU % averaged over the last pass, summed footprint, PIDs busiest first).
    /// A look that's under the limit, or missing (the app quit), ends the excess.
    mutating func update(_ apps: [String: (name: String, cpu: Double?, memory: Double, pids: [Int32])], baselines: [String: AppBaseline], at t: Date) {
        var next: [String: Date] = [:]
        var out: [Finding] = []
        for (id, a) in apps {
            guard let b = baselines[id] else { continue }
            func check(_ key: String, _ now: Double?, _ usual: Double, _ margin: Double, _ make: (Double, Date) -> Finding) {
                guard let now, now >= usual * rules.ratio, now - usual >= margin else { return }
                let since = overSince[key] ?? t
                next[key] = since
                if t.timeIntervalSince(since) >= rules.sustain { out.append(make(now, since)) }
            }
            check("mem:\(id)", a.memory, b.memory, rules.memoryMargin) { now, since in
                Finding(id: "usual-mem:\(id)", severity: .caution, icon: "memorychip",
                        title: "\(a.name) is using \(Self.times(now / max(b.memory, 1))) its usual memory (usually ~\(Fmt.bytes(b.memory)))",
                        detail: "Now \(Fmt.bytes(now)) for \(Int(t.timeIntervalSince(since) / 60)) min. \"Usual\" is its typical daily average on this Mac over \(b.days) days. Restarting the app usually returns it to normal.",
                        since: since, destination: "Trends", pids: a.pids)
            }
            check("cpu:\(id)", a.cpu, b.cpu, rules.cpuMargin) { now, since in
                Finding(id: "usual-cpu:\(id)", severity: .caution, icon: "cpu",
                        title: "\(a.name) is using \(Self.times(now / max(b.cpu, 0.1))) its usual CPU (usually ~\(Int(b.cpu.rounded()))%)",
                        detail: "Now \(Int(now.rounded()))% of a core for \(Int(t.timeIntervalSince(since) / 60)) min. \"Usual\" is its typical daily average on this Mac over \(b.days) days.",
                        since: since, destination: "Trends", pids: a.pids)
            }
        }
        overSince = next
        findings = out.sorted { $0.id < $1.id }
    }

    /// Clears everything (after a sampling gap: an excess can't be called sustained across time we didn't see).
    mutating func reset() { overSince = [:]; findings = [] }

    /// "3×" for big ratios, "2.5×" below 10.
    static func times(_ r: Double) -> String { r >= 10 ? "\(Int(r.rounded()))×" : String(format: "%.1f×", r).replacingOccurrences(of: ".0×", with: "×") }
}
