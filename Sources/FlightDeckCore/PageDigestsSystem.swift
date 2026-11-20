import Foundation
// Digests of Restarts & Crashes (how the last session ended, days since an unexpected one), boot time (this boot vs
// the typical one) and battery health (health, cycles, when it reaches 80%) for cockpit instruments. See
// PageDigests.swift.

/// Restarts at a glance, from a RestartsReport (newest boot first).
public struct RestartsDigest: Sendable, Equatable {
    /// How the session before the current boot ended, and the verdict's own title ("Clean shutdown", …).
    public var lastEnd: ShutdownVerdict.Kind?
    public var lastEndTitle: String?
    /// When the most recent unexpected shutdown or panic happened (its end time, else the boot after it).
    public var lastUnexpected: Date?
    /// How far back the boot records reach, for "none since …".
    public var recordsSince: Date?
    /// Session lengths in days for the last `sessions` boots, oldest first; the current one runs to `now`.
    public var sessionDays: [Double] = []

    public init() {}

    /// Whole days since `lastUnexpected`; nil when there was none in the records.
    public func daysSinceUnexpected(now: Date) -> Int? {
        lastUnexpected.map { Int(max(now.timeIntervalSince($0), 0) / 86_400) }
    }

    /// "clean", "unexpected", "kernel panic" or "not recorded".
    public var lastEndLabel: String? {
        lastEnd.map { k in
            switch k { case .clean: "clean"; case .unexpected: "unexpected"; case .panic: "kernel panic"; case .unknown: "not recorded" }
        }
    }

    public static func build(_ r: RestartsReport, now: Date, sessions: Int = 20) -> RestartsDigest {
        var d = RestartsDigest()
        let events = r.events.sorted { $0.boot > $1.boot }
        if let cur = events.first { d.lastEnd = cur.previous.kind; d.lastEndTitle = cur.previous.title }
        if let u = events.first(where: \.previous.isUnexpected) { d.lastUnexpected = u.previous.ended ?? u.boot }
        d.recordsSince = r.oldestBoot ?? events.last?.boot
        var lengths: [Double] = []
        for (i, e) in events.prefix(sessions).enumerated() {
            let end = i == 0 ? now : events[i - 1].boot
            lengths.append(max(end.timeIntervalSince(e.boot), 0) / 86_400)
        }
        d.sessionDays = lengths.reversed()
        return d
    }
}

/// Boot to desktop for this boot against the typical (median) one of FlightDeck's saved earlier boots.
public struct BootTimeDigest: Sendable, Equatable {
    public var current: TimeInterval?
    public var currentBoot: Date?
    /// Median of the earlier measured boots; nil with fewer than `minEarlier` of them.
    public var typical: TimeInterval?
    public var earlierCount = 0
    /// The last `recent` measured boots' boot → desktop, oldest first (the current boot last, when measured).
    public var recent: [Double] = []
    public static let minEarlier = 2

    public init() {}

    /// Seconds slower (+) or faster (−) than typical.
    public var delta: TimeInterval? { current.flatMap { c in typical.map { c - $0 } } }
    /// Noticeably slower: at least 50% and 10 s over typical.
    public var isSlow: Bool { delta.map { d in d >= 10 && d >= 0.5 * (typical ?? 0) } ?? false }

    /// "typical 21 s · 17 s slower", "typical 21 s · as usual", or nil without a typical boot.
    public var comparison: String? {
        guard let t = typical else { return nil }
        let base = "typical " + DigestFormat.span(t)
        guard let d = delta else { return base }
        if abs(d) < max(3, 0.1 * t) { return base + " · as usual" }
        return base + " · " + DigestFormat.span(abs(d)) + (d > 0 ? " slower" : " faster")
    }

    public static func build(_ r: RestartsReport, now: Date, recent: Int = 12) -> BootTimeDigest {
        var d = BootTimeDigest()
        d.currentBoot = r.current?.boot
        d.current = r.current?.bootToDesktop
        let cur = r.current?.boot
        let earlier = r.history
            .filter { rec in cur.map { abs(rec.boot.timeIntervalSince($0)) >= 60 } ?? true }
            .filter { now.timeIntervalSince($0.boot) <= BootStore.retention }
            .sorted { $0.boot < $1.boot }
            .compactMap { rec in rec.timing?.bootToDesktop.map { (rec.boot, $0) } }
            .filter { $0.1 > 0 }
        d.earlierCount = earlier.count
        if earlier.count >= minEarlier {
            let v = earlier.map(\.1).sorted(), n = v.count
            d.typical = n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
        }
        var series = earlier.map(\.1)
        if let c = d.current { series.append(c) }
        d.recent = Array(series.suffix(recent))
        return d
    }
}

/// Battery health at a glance: health now, cycles, and when the trend reaches 80% (BatteryForecast).
public struct BatteryHealthDigest: Sendable, Equatable {
    public enum Outlook: Sendable, Equatable {
        case reaches(Date), beyondHorizon, reached, notEnoughData, notDeclining
    }
    public var hasBattery = false
    public var health: Double?
    public var cycles: Int?
    public var designCycles: Int?
    public var outlook: Outlook = .notEnoughData
    /// Daily health readings (last `days` days with one), oldest first.
    public var history: [Double] = []

    public init() {}

    /// "Mar 2029", ">10 yr", "reached", "not enough data", "not declining".
    public var outlookLabel: String {
        switch outlook {
        case .reaches(let d): BatteryReport.monthYear(d)
        case .beyondHorizon: ">\(Int(BatteryForecast.horizonYears)) yr"
        case .reached: "reached"
        case .notEnoughData: "not enough data"
        case .notDeclining: "not declining"
        }
    }

    /// The graph's floor: 80% or (if lower) the lowest reading rounded down to 5, so a few points' change shows.
    public var graphFloor: Double {
        let lo = history.min() ?? 80
        return min(80, (lo / 5).rounded(.down) * 5)
    }

    public static func build(_ r: BatteryReport, days: Int = 365) -> BatteryHealthDigest {
        var d = BatteryHealthDigest()
        d.hasBattery = r.hasBattery
        d.health = r.health; d.cycles = r.cycles; d.designCycles = r.designCycles
        let f = r.forecast
        switch f.status {
        case .forecast: d.outlook = f.beyondHorizon ? .beyondHorizon : f.date80.map { .reaches($0) } ?? .beyondHorizon
        case .belowThreshold: d.outlook = .reached
        case .insufficient: d.outlook = .notEnoughData
        case .notDeclining: d.outlook = .notDeclining
        }
        d.history = Array(r.history.sorted { $0.start < $1.start }.compactMap(\.health).suffix(days))
        return d
    }
}
