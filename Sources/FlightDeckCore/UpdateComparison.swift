import Foundation
// "Did that update make things worse?" Finds the days on which macOS or an app changed version in the daily records,
// and compares the days before with the days after, in plain English ("Since Safari 19.2: energy +40%, 3 hangs vs 0").
// Pure functions over `DayRecord`s, computed on demand by the Trends view.

/// A version change seen between two recorded days.
public struct UpdateEvent: Sendable, Hashable, Identifiable {
    public enum Subject: Sendable, Hashable { case macOS, app(id: String, name: String) }
    public var id: String { "\(day)|\(title)" }
    /// The first day recorded with the new version.
    public var day: String
    public var date: Date
    public var subject: Subject
    public var from: String?
    public var to: String
    /// "macOS 26.1 (25B78)" or "Safari 19.2".
    public var title: String
}

/// One compared metric. `before`/`after` are nil when that side had no measurement.
public struct MetricChange: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var before: Double?
    public var after: Double?
    /// Formatted values for display.
    public var beforeText: String
    public var afterText: String
    /// Large enough and in the bad direction to call out.
    public var regression: Bool
    public var improvement: Bool
    /// The phrase used in the summary: "energy +40%", "3 hangs vs 0".
    public var phrase: String
}

public struct UpdateComparison: Sendable {
    public var event: UpdateEvent
    public var beforeDays: Int
    public var afterDays: Int
    public var changes: [MetricChange]
    /// Days still needed after the update before a comparison is meaningful (0 = ready).
    public var needsMoreDaysAfter: Int
    public var needsMoreDaysBefore: Int
    /// "Since Safari 19.2: energy +40%, 3 hangs vs 0" / "Since macOS 26.1: no regressions (5 days before vs 5 after)".
    public var summary: String
}

public enum Trends {
    /// Days needed on each side of an update.
    public static let minDaysEachSide = 2

    /// Version changes between consecutive days that recorded a version, oldest first. An app that disappears for a
    /// few days and comes back with a new version still counts (compared with its last known version).
    public static func updates(_ days: [DayRecord]) -> [UpdateEvent] {
        var out: [UpdateEvent] = []
        var lastOS: (String, String?)?
        var lastApp: [String: String] = [:]
        for d in days.sorted(by: { $0.start < $1.start }) {
            if let v = d.osVersion {
                if let (pv, pb) = lastOS, pv != v || (pb != nil && d.osBuild != nil && pb != d.osBuild) {
                    out.append(UpdateEvent(day: d.day, date: d.start, subject: .macOS, from: pv, to: v,
                                           title: "macOS \(v)" + (d.osBuild.map { " (\($0))" } ?? "")))
                }
                lastOS = (v, d.osBuild)
            }
            for a in d.apps {
                guard let v = a.version else { continue }
                if let pv = lastApp[a.id], pv != v {
                    out.append(UpdateEvent(day: d.day, date: d.start, subject: .app(id: a.id, name: a.name), from: pv, to: v, title: "\(a.name) \(v)"))
                }
                lastApp[a.id] = v
            }
        }
        return out
    }

    /// Compares up to `window` days before the update day with as many days after it (the same count on both
    /// sides, so totals such as hang counts are comparable). The update day itself is left out: it mixes both versions.
    public static func compare(_ days: [DayRecord], around e: UpdateEvent, window: Int = 7) -> UpdateComparison {
        let sorted = days.sorted { $0.start < $1.start }
        let relevant: (DayRecord) -> Bool = { d in
            switch e.subject { case .macOS: d.observedSeconds > 0; case .app(let id, _): d.apps.contains { $0.id == id } }
        }
        let beforeAll = sorted.filter { $0.start < e.date && relevant($0) }
        let afterAll = sorted.filter { $0.start > e.date && relevant($0) }
        let n = min(window, beforeAll.count, afterAll.count)
        let before = Array(beforeAll.suffix(n)), after = Array(afterAll.prefix(n))
        let needAfter = max(minDaysEachSide - afterAll.count, 0), needBefore = max(minDaysEachSide - beforeAll.count, 0)
        var changes: [MetricChange] = []
        if needAfter == 0 && needBefore == 0 {
            switch e.subject {
            case .macOS: changes = systemChanges(before, after)
            case .app(let id, let name): changes = appChanges(id: id, name: name, before, after)
            }
        }
        let regressions = changes.filter(\.regression)
        let summary: String
        if needAfter > 0 || needBefore > 0 {
            let side = needAfter > 0 ? "after" : "before"
            let k = max(needAfter, needBefore)
            summary = "\(e.title): needs \(k) more day\(k == 1 ? "" : "s") of data \(side) the update to compare."
        } else if regressions.isEmpty {
            summary = "Since \(e.title): no regressions (\(n) days before vs \(n) after)."
        } else {
            summary = "Since \(e.title): " + regressions.map(\.phrase).joined(separator: ", ")
        }
        return UpdateComparison(event: e, beforeDays: before.count, afterDays: after.count, changes: changes,
                                needsMoreDaysAfter: needAfter, needsMoreDaysBefore: needBefore, summary: summary)
    }

    /// Mean of the measured values (nil if none).
    static func mean(_ v: [Double?]) -> Double? {
        let m = v.compactMap { $0 }
        return m.isEmpty ? nil : m.reduce(0, +) / Double(m.count)
    }

    /// A rate or level change: regression when worse by at least `pct`% AND by at least `minAbs` units.
    static func level(_ name: String, _ phraseName: String, _ b: Double?, _ a: Double?, minAbs: Double, pct: Double = 25,
                      higherIsWorse: Bool = true, fmt: (Double) -> String) -> MetricChange {
        var reg = false, imp = false, phrase = name
        if let b, let a {
            let d = a - b
            let rel = b > 0 ? d / b * 100 : (d > 0 ? Double.infinity : 0)
            let worse = higherIsWorse ? d : -d
            let relWorse = higherIsWorse ? rel : -rel
            reg = worse >= minAbs && relWorse >= pct
            imp = -worse >= minAbs && -relWorse >= pct
            phrase = b > 0 && rel.isFinite ? "\(phraseName) \(rel >= 0 ? "+" : "")\(Int(rel.rounded()))%" : "\(phraseName) \(fmt(a)) vs \(fmt(b))"
        }
        return MetricChange(name: name, before: b, after: a, beforeText: b.map(fmt) ?? "—", afterText: a.map(fmt) ?? "—",
                            regression: reg, improvement: imp, phrase: phrase)
    }

    /// A count over the window: regression when there are at least 2 more after and at least twice as many.
    static func count(_ name: String, _ b: Int?, _ a: Int?) -> MetricChange {
        let reg = (a ?? 0) >= (b ?? 0) * 2 && (a ?? 0) - (b ?? 0) >= 2
        let imp = (b ?? 0) >= (a ?? 0) * 2 && (b ?? 0) - (a ?? 0) >= 2
        return MetricChange(name: name.capitalized, before: b.map(Double.init), after: a.map(Double.init),
                            beforeText: b.map(String.init) ?? "—", afterText: a.map(String.init) ?? "—",
                            regression: a != nil && b != nil && reg, improvement: a != nil && b != nil && imp,
                            phrase: "\(a ?? 0) \(name) vs \(b ?? 0)")
    }

    /// Sum of counts over days; nil if no day was counted.
    static func total(_ days: [DayRecord], _ f: (DayRecord) -> Int?) -> Int? {
        let v = days.compactMap(f); return v.isEmpty ? nil : v.reduce(0, +)
    }

    static func systemChanges(_ b: [DayRecord], _ a: [DayRecord]) -> [MetricChange] {
        [
            level("Average CPU", "CPU", mean(b.map(\.cpuAverage)), mean(a.map(\.cpuAverage)), minAbs: 3, fmt: { String(format: "%.1f%%", $0) }),
            level("CPU 95th percentile", "busy CPU", mean(b.map(\.cpuP95)), mean(a.map(\.cpuP95)), minAbs: 5, fmt: { String(format: "%.0f%%", $0) }),
            level("Average power", "energy", mean(b.map(\.averageWatts)), mean(a.map(\.averageWatts)), minAbs: 0.5, fmt: { String(format: "%.1f W", $0) }),
            level("Memory pressure", "memory pressure", mean(b.map(\.pressureAverage)), mean(a.map(\.pressureAverage)), minAbs: 5, fmt: { String(format: "%.0f%%", $0) }),
            level("Peak swap", "swap", mean(b.map(\.swapMax)), mean(a.map(\.swapMax)), minAbs: 512e6, pct: 50, fmt: { Fmt.bytes($0) }),
            level("Hottest", "temperature", mean(b.map(\.hottest)), mean(a.map(\.hottest)), minAbs: 4, pct: 5, fmt: { Fmt.temp($0) }),
            count("crashes", total(b, \.crashes), total(a, \.crashes)),
            count("hangs", total(b, \.hangs), total(a, \.hangs)),
        ]
    }

    static func appChanges(id: String, name: String, _ b: [DayRecord], _ a: [DayRecord]) -> [MetricChange] {
        func app(_ d: DayRecord) -> AppDay? { d.apps.first { $0.id == id } }
        // Report counts are keyed by process name; an app's main process normally carries the app's name.
        func reports(_ days: [DayRecord], _ f: (DayRecord) -> [String: Int]?) -> Int? {
            let counted = days.filter { f($0) != nil }
            return counted.isEmpty ? nil : counted.reduce(0) { $0 + (f($1)?[name] ?? 0) }
        }
        return [
            level("CPU while running", "CPU", mean(b.map { app($0)?.averageCPU }), mean(a.map { app($0)?.averageCPU }), minAbs: 2, fmt: { String(format: "%.1f%%", $0) }),
            level("Power while running", "energy", mean(b.map { app($0)?.averageWatts }), mean(a.map { app($0)?.averageWatts }), minAbs: 0.2, fmt: { String(format: "%.2f W", $0) }),
            level("Memory while running", "memory", mean(b.map { app($0)?.averageMemory }), mean(a.map { app($0)?.averageMemory }), minAbs: 200e6, fmt: { Fmt.bytes($0) }),
            level("Peak memory", "peak memory", mean(b.map { app($0).map { Double($0.peakMemory) } }), mean(a.map { app($0).map { Double($0.peakMemory) } }), minAbs: 300e6, fmt: { Fmt.bytes($0) }),
            count("crashes", reports(b, \.crashesByProcess), reports(a, \.crashesByProcess)),
            count("hangs", reports(b, \.hangsByProcess), reports(a, \.hangsByProcess)),
        ]
    }
}
