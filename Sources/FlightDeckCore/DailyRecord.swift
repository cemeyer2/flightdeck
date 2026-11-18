import Foundation
// The long-term history's data model: one compact `DayRecord` per calendar day (system statistics, macOS version,
// battery health, event counts and the top apps' usage), kept for 90 days by `DailyLog`. The Trends view, the
// "normal for this Mac" baselines and the before/after-an-update comparison are all computed from these records.
//
// Never invent zeros: every statistic is optional and stays nil when it wasn't measured that day (no battery, no
// system power sensor, FlightDeck not running), so charts show a gap rather than a misleading 0.

/// One app's use on one day. Totals come from cumulative per-process counters (CPU time, billed energy), so they are
/// exact however coarsely the app was looked at; memory is sampled every `DailyLog.Config.appInterval` seconds.
public struct AppDay: Codable, Sendable, Hashable, Identifiable {
    /// `AppUsage` grouping key: bundle path, or "proc:<name>".
    public var id: String
    public var name: String
    /// CFBundleShortVersionString of the app bundle (nil for bare processes, or before it was read).
    public var version: String?
    /// CPU time used by all of the app's processes, in seconds.
    public var cpuSeconds: Double = 0
    /// Billed energy, Wh. nil when no member process reported energy (not 0).
    public var energyWh: Double?
    /// Highest summed footprint seen at one look, bytes.
    public var peakMemory: UInt64 = 0
    /// Footprint × seconds, for the average while running.
    public var memorySeconds: Double = 0
    /// Seconds the app was seen running (at least one process present).
    public var runningSeconds: Double = 0

    public init(id: String, name: String) { self.id = id; self.name = name }

    /// Average footprint while running, bytes.
    public var averageMemory: Double? { runningSeconds > 0 ? memorySeconds / runningSeconds : nil }
    /// Average CPU % (of one core) while running.
    public var averageCPU: Double? { runningSeconds > 0 ? cpuSeconds / runningSeconds * 100 : nil }
    /// Average power while running, W.
    public var averageWatts: Double? { runningSeconds > 0 ? energyWh.map { $0 * 3600 / runningSeconds } : nil }
}

/// Running sums behind a day's averages. Kept (and persisted) only while the day is open; dropped when it closes.
struct DaySums: Codable, Sendable, Hashable {
    /// Time-weighted CPU %: sum of value × seconds, and the seconds.
    var cpu = 0.0, cpuWeight = 0.0
    /// Seconds spent in each 1% CPU bin (0..<1, 1..<2, … 99...100), for the 95th percentile without keeping samples.
    var cpuHist = [Double](repeating: 0, count: 100)
    var pressure = 0.0, pressureWeight = 0.0
    /// Integrated system power, Wh, and whether any reading contributed.
    var energy = 0.0, energySeen = false
}

/// One calendar day (local time) of this Mac.
public struct DayRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: String { day }
    /// "yyyy-MM-dd" in local time; also the sort key.
    public var day: String
    /// Local midnight that starts the day.
    public var start: Date
    /// Seconds FlightDeck was sampling this day (gaps such as sleep excluded).
    public var observedSeconds: Double = 0

    // System statistics (nil = not measured that day).
    /// Whole-machine CPU %, time-weighted average and 95th percentile (1% resolution).
    public var cpuAverage: Double?
    public var cpuP95: Double?
    public var pressureAverage: Double?
    public var pressureMax: Double?
    /// Most swap in use at once, bytes.
    public var swapMax: Double?
    /// System energy (measured system power integrated over observed time), Wh.
    public var energyWh: Double?
    public var hottest: Double?
    /// Worst `ProcessInfo.ThermalState` raw value seen (0 nominal … 3 critical).
    public var worstThermalState: Int?
    /// Hours asleep in sleeps that ended this day (from the power log).
    public var sleepHours: Double?

    public var osVersion: String?
    public var osBuild: String?
    /// Battery full-charge capacity as % of design, and cycle count, as last read that day.
    public var batteryHealth: Double?
    public var cycleCount: Int?

    /// macOS crash and hang reports, and Flight Log incidents, that happened this day. nil = never counted.
    public var crashes: Int?
    public var hangs: Int?
    public var incidents: Int?
    /// Crash / hang reports by process name (matches `AppDay.name` for apps whose executable has the app's name).
    public var crashesByProcess: [String: Int]?
    public var hangsByProcess: [String: Int]?

    /// Busiest apps, by CPU time (trimmed when the day closes).
    public var apps: [AppDay] = []
    /// Per-app internet data usage (DataUsage.swift). nil = not counted that day (nettop unavailable, FlightDeck not
    /// running, or a record from before this was added: optional, so older files still decode).
    public var dataUsage: DataUsageDay? = nil
    /// Present only while the day is still being accumulated.
    var sums: DaySums? = nil

    public init(day: String, start: Date) { self.day = day; self.start = start }

    /// Recomputes the averages from the running sums (no-op for a closed day).
    mutating func finalizeStats() {
        guard let s = sums else { return }
        if s.cpuWeight > 0 {
            cpuAverage = s.cpu / s.cpuWeight
            // First bin where the cumulative time reaches 95%; reported as its upper edge.
            var acc = 0.0
            for (i, w) in s.cpuHist.enumerated() { acc += w; if acc >= s.cpuWeight * 0.95 { cpuP95 = Double(i + 1); break } }
        }
        if s.pressureWeight > 0 { pressureAverage = s.pressure / s.pressureWeight }
        if s.energySeen { energyWh = s.energy }
    }

    /// Average system power over the observed time, W (energy alone depends on how long the Mac was used).
    public var averageWatts: Double? {
        guard let e = energyWh, observedSeconds > 600 else { return nil }
        return e * 3600 / observedSeconds
    }

    public func app(named name: String) -> AppDay? { apps.first { $0.name == name } }
}
