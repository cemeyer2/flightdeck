import Foundation
// When will this battery reach 80% health, the usual service threshold? A robust (Theil–Sen) line through health
// against time, and another against cycles, with Sen's 95% range for the slope. It refuses to forecast when the data
// can't support one and says what's missing: at least `minSpanDays` of readings and a `minChange` points change in
// health, because health read in 1% steps that wobbles ±1% can't show a trend in less.
//
// Honesty notes: the range treats daily readings as independent, which they aren't quite (a warm week reads low for
// a week), so it is indicative rather than exact; and batteries don't age in a straight line (often faster at first,
// sometimes faster again near the end), so dates years out are the current trend extended, not a promise.

public struct BatteryForecast: Sendable {
    public static let minSpanDays = 14.0
    public static let minPoints = 10
    public static let minChange = 2.0
    public static let threshold = 80.0
    /// Projections beyond this are reported as "more than 10 years" rather than as a date.
    public static let horizonYears = 10.0

    public enum Status: Sendable, Equatable {
        /// `date80` and its range are set.
        case forecast
        /// Not enough data; `needed` says what's missing in words, `weeksNeeded` when it can be estimated.
        case insufficient(needed: String, weeksNeeded: Int?)
        /// Enough data, but health isn't falling (flat, or rising after a recalibration): no date to give.
        case notDeclining(String)
        /// Health is already at or below 80%.
        case belowThreshold
    }

    public var status: Status
    /// Points used (the current battery's days with a health reading), as (date, health).
    public var points: [(date: Date, health: Double)]
    /// x in the fits is days since `origin`.
    public var origin: Date
    public var line: RobustLine?
    public var spanDays: Double
    /// The trend's change per year, points (negative = losing health), and its 95% range.
    public var perYear: Double?
    public var perYearRange: (low: Double, high: Double)?
    /// Reaching 80%: the trend's date, and the range (late is nil when the slow edge of the range doesn't decline,
    /// i.e. the data can't rule out "much later"). A date past the horizon is nil with `beyondHorizon` set.
    public var date80: Date?
    public var date80Early: Date?
    public var date80Late: Date?
    public var beyondHorizon = false
    /// Health against cycles: cycles at which the trend reaches 80%, and its range.
    public var cycles80: Int?
    public var cycles80Range: (low: Int?, high: Int?)?
    public var cyclesPerWeek: Double?
    public var currentCycles: Int?
    public var designCycles: Int?
    /// When a battery replacement was detected, the day the current battery's history starts.
    public var replacedOn: Date?

    public var cyclesRemaining: Int? { designCycles.flatMap { d in currentCycles.map { max(d - $0, 0) } } }
    /// When the design cycle count is reached at the recent cycling rate.
    public var designCyclesDate: Date? {
        guard let r = cyclesRemaining, let w = cyclesPerWeek, w > 0.05 else { return nil }
        let last = points.last?.date ?? origin
        let days = Double(r) / w * 7
        return days / 365 > Self.horizonYears ? nil : last.addingTimeInterval(days * 86_400)
    }

    func date(_ x: Double) -> Date { origin.addingTimeInterval(x * 86_400) }

    /// The trend and band at `d` (for the chart): (low edge, trend, high edge) health.
    public func band(at d: Date) -> (low: Double, mid: Double, high: Double)? {
        guard let l = line else { return nil }
        let x = d.timeIntervalSince(origin) / 86_400
        let a = l.y(x, slope: l.slopeLow ?? l.slope), b = l.y(x, slope: l.slopeHigh ?? l.slope)
        return (min(a, b), l.y(x), max(a, b))
    }

    /// Builds the forecast from the battery history (any order; FlightDeck's own days and seeded ones alike).
    public static func compute(_ history: [BatteryDay], designCycles: Int?, currentCycles: Int?) -> BatteryForecast {
        let current = BatteryHistory.currentBattery(history.sorted { $0.start < $1.start })
        let pts = current.days.compactMap { d in d.health.map { (date: d.start, health: $0) } }
        let origin = pts.first?.date ?? Date()
        var f = BatteryForecast(status: .insufficient(needed: "No battery health readings yet.", weeksNeeded: nil), points: pts, origin: origin,
                                line: nil, spanDays: 0, currentCycles: currentCycles ?? current.days.last(where: { $0.cycles != nil })?.cycles,
                                designCycles: designCycles, replacedOn: current.replacedOn)
        f.cyclesPerWeek = cycleRate(current.days)
        guard let last = pts.last else { return f }
        f.spanDays = last.date.timeIntervalSince(origin) / 86_400
        let have = "\(pts.count) day\(pts.count == 1 ? "" : "s") of readings over \(Int(f.spanDays.rounded())) days"
        if f.spanDays < minSpanDays || pts.count < minPoints {
            let days = max(minSpanDays - f.spanDays, Double(minPoints - pts.count))
            let weeks = Self.weeks(days)
            f.status = .insufficient(needed: "Needs about \(weeks) more week\(weeks == 1 ? "" : "s") of daily readings (has \(have); a forecast needs at least \(Int(minSpanDays)) days and a \(Int(minChange))% change in health).", weeksNeeded: weeks)
            return f
        }
        // Long histories: one median point per week, which bounds the O(n²) fit and damps day-to-day wobble.
        let fitPts = thinned(pts.map { (x: $0.date.timeIntervalSince(origin) / 86_400, y: $0.health) })
        guard let l = TheilSen.fit(fitPts) else { return f }
        f.line = l
        f.perYear = l.slope * 365
        if let lo = l.slopeLow, let hi = l.slopeHigh { f.perYearRange = (lo * 365, hi * 365) }
        let change = l.slope * f.spanDays
        let nowX = f.spanDays, nowHealth = l.y(nowX)
        if abs(change) < minChange {
            // A pace that would take over five years to show 2% is no measurable decline, not a wait to quote.
            let more = l.slope < 0 ? minChange / -l.slope - f.spanDays : .infinity
            if more < 5 * 365 {
                let weeks = Self.weeks(more)
                f.status = .insufficient(needed: String(format: "Health has changed about %.1f%% in %d days; a forecast needs a %d%% change, about %d more week%@ at this pace.", -change, Int(f.spanDays.rounded()), Int(minChange), weeks, weeks == 1 ? "" : "s"), weeksNeeded: weeks)
            } else {
                f.status = .insufficient(needed: "No measurable decline in \(Int(f.spanDays.rounded())) days; a forecast needs a \(Int(minChange))% change in health. How long that takes can't be estimated until the trend shows.", weeksNeeded: nil)
            }
            return f
        }
        if l.slope >= 0 {
            f.status = .notDeclining(String(format: "Health rose about %.1f%% over %d days. That happens when the gauge recalibrates its capacity estimate; there is no decline to project.", change, Int(f.spanDays.rounded())))
            return f
        }
        fitCycles(&f, current.days)
        if nowHealth <= threshold { f.status = .belowThreshold; return f }
        f.status = .forecast
        // A date for a slope, or nil past the horizon / when that slope doesn't decline.
        func when(_ s: Double?) -> Date? {
            guard let s, s < 0, let x = l.x(reaching: threshold, slope: s) else { return nil }
            return (x - nowX) / 365 > horizonYears ? nil : f.date(max(x, nowX))
        }
        f.date80 = when(l.slope)
        f.beyondHorizon = f.date80 == nil
        f.date80Early = when(l.slopeLow)
        f.date80Late = when(l.slopeHigh)
        return f
    }

    /// Whole weeks for `days`, at least 1. The small epsilon keeps float noise (69.9999… vs 70.0000…1 days) from
    /// adding a week.
    static func weeks(_ days: Double) -> Int { max(Int((days / 7 - 1e-6).rounded(.up)), 1) }

    /// Weekly medians when there are more than 120 points; otherwise the points as they are.
    static func thinned(_ p: [(x: Double, y: Double)]) -> [(x: Double, y: Double)] {
        guard p.count > 120 else { return p }
        let weeks = Dictionary(grouping: p, by: { Int($0.x / 7) })
        return weeks.keys.sorted().map { k in
            let w = weeks[k]!
            return (x: TheilSen.median(w.map(\.x)), y: TheilSen.median(w.map(\.y)))
        }
    }

    /// Cycles per week over the last 30 days with cycle counts (needs a week of span), by Theil–Sen.
    static func cycleRate(_ days: [BatteryDay]) -> Double? {
        guard let lastDay = days.last?.start else { return nil }
        let recent = days.filter { $0.cycles != nil && lastDay.timeIntervalSince($0.start) <= 30 * 86_400 }
        guard let first = recent.first?.start, let lastC = recent.last?.start, lastC.timeIntervalSince(first) >= 7 * 86_400 else { return nil }
        let pts = recent.map { (x: $0.start.timeIntervalSince(first) / 86_400, y: Double($0.cycles!)) }
        return TheilSen.fit(pts).map { max($0.slope * 7, 0) }
    }

    /// Health against cycle count: needs 20 cycles of span. Fills `cycles80` and its range.
    static func fitCycles(_ f: inout BatteryForecast, _ days: [BatteryDay]) {
        let pts = thinned(days.compactMap { d in d.health.flatMap { h in d.cycles.map { (x: Double($0), y: h) } } })
        guard let lo = pts.map(\.x).min(), let hi = pts.map(\.x).max(), hi - lo >= 20, let l = TheilSen.fit(pts), l.slope < 0 else { return }
        func at(_ s: Double?) -> Int? {
            guard let s, s < 0, let x = l.x(reaching: threshold, slope: s), x.isFinite, x < 100_000 else { return nil }
            return Int(max(x, hi).rounded())
        }
        f.cycles80 = at(l.slope)
        f.cycles80Range = (at(l.slopeLow), at(l.slopeHigh))
    }
}
