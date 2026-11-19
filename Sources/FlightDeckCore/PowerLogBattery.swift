import Foundation
import SQLite3
// Battery history macOS already has, readable without root: powerd's power log, an SQLite file that is world-readable
// (mode 644) on current macOS. Its PLBatteryAgent_EventNone_BatteryConfig table gets one row a day or so with the
// gauge's cycle count, nominal capacity and Maximum Capacity %, plus lifetime fields the gauge keeps (hottest and
// coldest temperature, total operating time). powerd keeps only about ten days of these rows, so this seeds the days
// just before FlightDeck started; DailyLog then keeps them (marked `.macOS`) after powerd has rotated them away.
//
// Undocumented and private: table and column names can change with any macOS release, so every column is optional,
// the read is one read-only query, and any failure simply means "no seed". Read at most once a day, off the main thread.
//
// What else was checked (on a MacBook Pro, macOS 26) and found to hold no history: AppleSmartBattery's keys and its
// BatteryData dictionary (current values only; no lifetime or Qmax history is published there any more),
// IOPowerSources (current values; its DesignCycleCount of 300 is a placeholder, the gauge's DesignCycleCount9C is
// used instead), system_profiler SPPowerDataType (cycle count, condition and Maximum Capacity now), and `pmset -g log`
// (about a week of charge % at power events, no health).

/// Lifetime figures the battery gauge keeps, as of the latest power-log row.
public struct BatteryLifetime: Codable, Sendable, Hashable {
    /// Hottest and coldest battery temperature the gauge has recorded, °C.
    public var maxTemp: Double?
    public var minTemp: Double?
    /// Hours the battery has been in operation. (The field grows by ~24 a day, so it counts hours.)
    public var operatingHours: Int?
    public var asOf: Date
    public init(maxTemp: Double?, minTemp: Double?, operatingHours: Int?, asOf: Date) {
        self.maxTemp = maxTemp; self.minTemp = minTemp; self.operatingHours = operatingHours; self.asOf = asOf
    }
}

public struct PowerLogSeed: Sendable {
    public var days: [BatteryDay]
    public var lifetime: BatteryLifetime?
}

public enum PowerLogBattery {
    public static let path = "/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL"
    static let table = "PLBatteryAgent_EventNone_BatteryConfig"

    /// Reads and parses the power log; nil when it is missing, unreadable or changed shape. `designCapacity` (mAh, from
    /// the live reading) turns nominal capacity into health the way `BatteryInfo.health` does.
    public static func read(designCapacity: Int?, path: String = path, calendar: Calendar = .current) -> PowerLogSeed? {
        guard let rows = query(path) else { return nil }
        let seed = parse(rows, designCapacity: designCapacity, calendar: calendar)
        return seed.days.isEmpty && seed.lifetime == nil ? nil : seed
    }

    /// One row per (local) day, the day's last; health from nominal ÷ design, else the gauge's Maximum Capacity %.
    public static func parse(_ rows: [[String: Double]], designCapacity: Int?, calendar: Calendar = .current) -> PowerLogSeed {
        var byDay: [Date: [String: Double]] = [:]
        for r in rows {
            guard let ts = r["timestamp"], ts > 1_000_000_000 else { continue }
            let start = calendar.startOfDay(for: Date(timeIntervalSince1970: ts))
            if (byDay[start]?["timestamp"] ?? 0) <= ts { byDay[start] = r }
        }
        let days: [BatteryDay] = byDay.keys.sorted().compactMap { start in
            let r = byDay[start]!
            var health: Double?
            if let n = r["NominalChargeCapacity"], n > 0, let d = designCapacity, d > 0 { health = n / Double(d) * 100 }
            else if let m = r["MaximumCapacityPercent"], m > 0, m <= 110 { health = m }
            let cycles = r["CycleCount"].flatMap { $0 >= 0 ? Int($0) : nil }
            guard health != nil || cycles != nil else { return nil }
            let c = calendar.dateComponents([.year, .month, .day], from: start)
            let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            return BatteryDay(day: key, start: start, health: health, cycles: cycles, source: .macOS)
        }
        var lifetime: BatteryLifetime?
        if let latest = rows.max(by: { ($0["timestamp"] ?? 0) < ($1["timestamp"] ?? 0) }), let ts = latest["timestamp"] {
            // Plausibility bounds: a value outside them is a placeholder or a changed unit, and is dropped.
            let maxT = latest["MaximumTemperature"].flatMap { $0 > 0 && $0 < 100 ? $0 : nil }
            let minT = latest["MinimumTemperature"].flatMap { $0 > -50 && $0 < 60 ? $0 : nil }
            let hours = latest["TotalOperatingTime"].flatMap { $0 > 0 && $0 < 200_000 ? Int($0) : nil }
            if maxT != nil || minT != nil || hours != nil {
                lifetime = BatteryLifetime(maxTemp: maxT, minTemp: minT, operatingHours: hours, asOf: Date(timeIntervalSince1970: ts))
            }
        }
        return PowerLogSeed(days: days, lifetime: lifetime)
    }

    /// The table's numeric columns, row by row. Read-only; nil on any error (missing file, no permission, no table).
    static func query(_ path: String) -> [[String: Double]]? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_000)   // powerd may be writing; wait briefly rather than fail
        var st: OpaquePointer?
        // SELECT * so a column that a macOS release drops doesn't fail the query; only the ones used are kept.
        guard sqlite3_prepare_v2(db, "SELECT * FROM \(table) ORDER BY timestamp", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        let wanted: Set<String> = ["timestamp", "CycleCount", "NominalChargeCapacity", "MaximumCapacityPercent",
                                   "MaximumTemperature", "MinimumTemperature", "TotalOperatingTime"]
        var cols: [(Int32, String)] = []
        for i in 0..<sqlite3_column_count(st) {
            if let n = sqlite3_column_name(st, i).map({ String(cString: $0) }), wanted.contains(n) { cols.append((i, n)) }
        }
        var rows: [[String: Double]] = []
        while sqlite3_step(st) == SQLITE_ROW, rows.count < 10_000 {
            var r: [String: Double] = [:]
            for (i, n) in cols {
                let t = sqlite3_column_type(st, i)
                if t == SQLITE_INTEGER || t == SQLITE_FLOAT { r[n] = sqlite3_column_double(st, i) }
            }
            rows.append(r)
        }
        return rows
    }
}
