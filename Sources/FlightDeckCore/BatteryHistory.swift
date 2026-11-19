import Foundation
// The battery's long-term history: one small point per day (health, cycle count, the day's wear tallies). The daily
// log keeps full `DayRecord`s for 90 days, which is too short to see a battery age, so DailyLog also keeps these points
// for `BatteryHistory.retentionDays` (about 60 bytes a day). Days before FlightDeck ran can be seeded from macOS's own
// power log (PowerLogBattery.swift); those points are marked `.macOS` and never replace a day FlightDeck measured.

public struct BatteryDay: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable { case flightDeck, macOS, demo }
    public var id: String { day }
    /// "yyyy-MM-dd", local time.
    public var day: String
    public var start: Date
    /// Full-charge capacity as % of design (nominal ÷ design), as in `BatteryInfo.health`.
    public var health: Double?
    public var cycles: Int?
    public var wear: BatteryWearDay?
    public var source: Source

    public init(day: String, start: Date, health: Double?, cycles: Int?, wear: BatteryWearDay? = nil, source: Source) {
        self.day = day; self.start = start; self.health = health; self.cycles = cycles; self.wear = wear; self.source = source
    }

    /// The battery part of a daily record; nil for days with neither health nor cycles (desktops, no reading).
    public init?(_ r: DayRecord) {
        guard r.batteryHealth != nil || r.cycleCount != nil || r.batteryWear != nil else { return nil }
        self.init(day: r.day, start: r.start, health: r.batteryHealth, cycles: r.cycleCount, wear: r.batteryWear, source: .flightDeck)
    }
}

public enum BatteryHistory {
    /// Five years: longer than most batteries are kept, and only ~110 KB.
    public static let retentionDays = 5 * 366

    /// Merges sources by day, oldest first. Later arrays win for the same day, so pass them in increasing authority
    /// (seed, long-term store, daily records); a seeded point only fills a day nothing else covers.
    public static func merge(_ sources: [BatteryDay]...) -> [BatteryDay] {
        var byDay: [String: BatteryDay] = [:]
        for src in sources { for d in src { byDay[d.day] = d } }
        return byDay.values.sorted { $0.start < $1.start }
    }

    /// Drops points older than the retention window.
    public static func trim(_ days: [BatteryDay], now: Date) -> [BatteryDay] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return days.filter { $0.start >= cutoff }
    }

    /// The points belonging to the battery that's in the Mac now. A replacement shows as the cycle count going down
    /// or health jumping up by more than 5 points from one day to the next; history before the last such change is
    /// another battery's and would wreck the fit. Returns the points and the replacement day, if one was found.
    public static func currentBattery(_ days: [BatteryDay]) -> (days: [BatteryDay], replacedOn: Date?) {
        var startIndex = 0
        var lastHealth: Double?, lastCycles: Int?
        for (i, d) in days.enumerated() {
            // The cycle counter never goes down on one battery, so a drop (beyond a little gauge noise) is decisive.
            // Health alone jumps a few points when the gauge recalibrates, so it only counts without cycle counts,
            // and only for a jump far beyond recalibration size.
            let cyclesDropped = d.cycles.flatMap { c in lastCycles.map { c < $0 - 5 } } ?? false
            let noCycles = d.cycles == nil || lastCycles == nil
            let healthJumped = noCycles && (d.health.flatMap { h in lastHealth.map { h > $0 + 8 } } ?? false)
            if cyclesDropped || healthJumped { startIndex = i }
            if let h = d.health { lastHealth = h }
            if let c = d.cycles { lastCycles = c }
        }
        return (Array(days[startIndex...]), startIndex > 0 ? days[startIndex].start : nil)
    }
}
