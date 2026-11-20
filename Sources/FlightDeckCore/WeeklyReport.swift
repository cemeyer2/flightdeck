import Foundation
// The Weekly Report, part 1: the record. One `WeeklyReport` per calendar week (Monday 00:00 to the next Monday, local
// time), built from data FlightDeck already keeps (the daily log, the Flight Log, boot and panic records, battery
// history, destinations, the startup disk) by WeeklyReportBuilder, worded by WeeklyDigest, and saved as a small JSON
// file per week in ~/Library/Application Support/Flightdeck/Reports, so a week stays readable after the raw data
// behind it has aged out (the Flight Log keeps 7 days, destinations 30, the daily log 90).
//
// Never invent zeros: every value FlightDeck didn't measure is nil, and the digest leaves its line out or says why.

/// A Monday-to-Sunday week in local time. `id` ("2026-11-16", the Monday) names the saved file.
public struct WeekRange: Codable, Sendable, Hashable, Identifiable, Comparable {
    public var id: String
    public var start: Date
    /// The next Monday's midnight (exclusive).
    public var end: Date

    public init(start: Date, end: Date, id: String) { self.start = start; self.end = end; self.id = id }

    /// The calendar `cal` with weeks starting on Monday.
    static func mondayCalendar(_ cal: Calendar) -> Calendar { var c = cal; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c }

    public static func containing(_ d: Date, calendar: Calendar = .current) -> WeekRange {
        let c = mondayCalendar(calendar)
        let day = c.startOfDay(for: d)
        let back = (c.component(.weekday, from: day) + 5) % 7   // Monday 0 … Sunday 6
        let start = c.date(byAdding: .day, value: -back, to: day)!
        let end = c.date(byAdding: .day, value: 7, to: start)!
        let k = c.dateComponents([.year, .month, .day], from: start)
        return WeekRange(start: start, end: end, id: String(format: "%04d-%02d-%02d", k.year ?? 0, k.month ?? 0, k.day ?? 0))
    }

    public func previous(calendar: Calendar = .current) -> WeekRange {
        Self.containing(start.addingTimeInterval(-3600), calendar: calendar)
    }
    public func contains(_ d: Date) -> Bool { d >= start && d < end }
    /// "Nov 10 – 16", "Dec 29 – Jan 4".
    public var title: String {
        let last = end.addingTimeInterval(-3600)
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd")
        let sameMonth = Calendar.current.component(.month, from: start) == Calendar.current.component(.month, from: last)
        let g = DateFormatter(); g.setLocalizedDateFormatFromTemplate(sameMonth ? "d" : "MMMd")
        return "\(f.string(from: start)) – \(g.string(from: last))"
    }
    public static func < (a: Self, b: Self) -> Bool { a.start < b.start }
}

/// What kind of slowdown an incident was, for the hours and the "what slowed the Mac down" list.
public enum SlowdownKind: String, Codable, Sendable, CaseIterable {
    case cpu, memory, heat, hang, other
}

/// One kind of incident on one day: how often, for how long in all, and the app behind it (when there was one).
public struct WeeklyIncident: Codable, Sendable, Hashable {
    public var kind: SlowdownKind
    /// Plain-English label, without the numbers that changed while it lasted ("Xcode kept the CPU busy").
    public var label: String
    public var app: String?
    public var count: Int
    public var seconds: Double
    /// Worst `Finding.Severity` raw value.
    public var severity: Int
    /// Page to open for it (a Destination raw value).
    public var destination: String?
    public init(kind: SlowdownKind, label: String, app: String?, count: Int, seconds: Double, severity: Int, destination: String?) {
        self.kind = kind; self.label = label; self.app = app; self.count = count; self.seconds = seconds
        self.severity = severity; self.destination = destination
    }
}

/// The Flight Log for one day of the week. Kept per day because the Flight Log only holds 7 days: a day whose
/// incidents may already have been trimmed when the report is rebuilt keeps the tallies saved earlier.
public struct WeeklyDay: Codable, Sendable, Hashable {
    public var day: String
    public var start: Date
    /// Hours (wall clock, overlaps merged) with a CPU, memory or heat incident ongoing.
    public var cpuHours: Double
    public var memoryHours: Double
    public var heatHours: Double
    public var incidents: [WeeklyIncident]
    /// false when the Flight Log may no longer hold all of this day's incidents (built more than 7 days later).
    public var complete: Bool
}

/// An unexpected shutdown, kernel panic or app freeze.
public struct WeeklyEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case panic, unexpected, freeze }
    public var time: Date
    public var kind: Kind
    public var title: String
    public var detail: String?
    public init(time: Date, kind: Kind, title: String, detail: String? = nil) { self.time = time; self.kind = kind; self.title = title; self.detail = detail }
}

public struct WeeklyApp: Codable, Sendable, Hashable {
    public var name: String
    public var cpuHours: Double
    public init(name: String, cpuHours: Double) { self.name = name; self.cpuHours = cpuHours }
}

public struct WeeklyBattery: Codable, Sendable, Hashable {
    /// Cycle count and health (% of design) at the start (the last reading before the week, else its first) and end.
    public var cyclesStart: Int?, cyclesEnd: Int?
    public var healthStart: Double?, healthEnd: Double?
    /// When health is forecast to reach 80%, from the history up to this week's end and up to the previous week's end.
    public var forecast80: Date?
    public var forecast80Before: Date?
    /// Why there is no forecast (BatteryForecast's wording), when there isn't one.
    public var forecastNote: String?
    public var cyclesUsed: Int? { cyclesEnd.flatMap { e in cyclesStart.map { max(e - $0, 0) } } }
    public var healthChange: Double? { healthEnd.flatMap { e in healthStart.map { e - $0 } } }
}

/// The startup disk as read once during (or just after) the week.
public struct WeeklyStorage: Codable, Sendable, Hashable {
    public var readAt: Date
    public var used: UInt64
    public var capacity: UInt64
    /// Days until full at the current rate (Analyzer.daysUntilFull), only when free space was clearly shrinking.
    public var fullInDays: Double?
    public init(readAt: Date, used: UInt64, capacity: UInt64, fullInDays: Double?) {
        self.readAt = readAt; self.used = used; self.capacity = capacity; self.fullInDays = fullInDays
    }
    public var free: UInt64 { capacity > used ? capacity - used : 0 }
}

/// A destination an established app contacted for the first time this week.
public struct WeeklyDestination: Codable, Sendable, Hashable {
    public var app: String
    public var destination: String
    public var first: Date
    /// Bytes in + out this week; nil when the day files for the week are gone.
    public var bytes: UInt64?
    public var local: Bool
}

public struct WeeklyReport: Codable, Sendable, Hashable, Identifiable {
    public static let formatVersion = 1
    public var version = WeeklyReport.formatVersion
    public var id: String { week.id }
    public var week: WeekRange
    public var builtAt: Date
    /// Built after the week ended: nothing more will be added (it is never rebuilt).
    public var isFinal: Bool { builtAt >= week.end }

    /// Daily-log coverage: days with a record, and the hours FlightDeck was sampling.
    public var daysRecorded = 0
    public var observedHours: Double?

    // What slowed the Mac down.
    public var days: [WeeklyDay] = []
    public var topApps: [WeeklyApp] = []
    public var cpuAverage: Double?
    public var pressureMax: Double?
    public var hottest: Double?
    public var worstThermalState: Int?

    // Restarts, panics, freezes and crashes.
    public var restarts: [WeeklyEvent] = []
    public var boots: Int?
    public var freezes: [WeeklyEvent] = []
    /// macOS crash and hang reports counted by the daily log (nil = not counted any day).
    public var crashes: Int?
    public var hangs: Int?
    public var crashesByProcess: [String: Int] = [:]

    public var battery: WeeklyBattery?
    public var storage: WeeklyStorage?

    /// Internet data counted this week (nil = not counted on any day), and on how many days.
    public var dataUsed: UInt64?
    public var dataDays = 0
    public var newDestinations: [WeeklyDestination] = []

    public init(week: WeekRange, builtAt: Date) { self.week = week; self.builtAt = builtAt }

    // Week totals over the per-day Flight Log tallies.
    public var cpuHours: Double { days.reduce(0) { $0 + $1.cpuHours } }
    public var memoryHours: Double { days.reduce(0) { $0 + $1.memoryHours } }
    public var heatHours: Double { days.reduce(0) { $0 + $1.heatHours } }
    public var incidentCount: Int { days.reduce(0) { $0 + $1.incidents.reduce(0) { $0 + $1.count } } }
    public var incompleteDays: Int { days.filter { !$0.complete }.count }
    public var panics: Int { restarts.filter { $0.kind == .panic }.count }
    public var unexpected: Int { restarts.filter { $0.kind == .unexpected }.count }

    /// The week's incidents merged across days (same kind and label), longest first.
    public var incidents: [WeeklyIncident] {
        var by: [String: WeeklyIncident] = [:], order: [String] = []
        for d in days { for i in d.incidents {
            let k = i.kind.rawValue + "|" + i.label
            if var x = by[k] { x.count += i.count; x.seconds += i.seconds; x.severity = max(x.severity, i.severity); by[k] = x }
            else { by[k] = i; order.append(k) }
        } }
        return order.compactMap { by[$0] }.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.count > $1.count }
    }
}

/// The saved reports: one JSON file per week in `dir` (…/Flightdeck/Reports). Written atomically; unreadable files are
/// skipped. Read-only instances (MCP, off-screen renders) never write.
public final class WeeklyReportStore: @unchecked Sendable {
    public static var defaultDirectory: URL { DailyLog.defaultDirectory.appendingPathComponent("Reports") }
    /// Reports older than this are deleted (two years of weeks is ~200 small files).
    public static let retention: TimeInterval = 2 * 366 * 86_400
    public let dir: URL?
    public let readOnly: Bool
    private let lock = NSLock()
    private var memory: [String: WeeklyReport] = [:]

    public init(dir: URL?, readOnly: Bool = false) { self.dir = dir; self.readOnly = readOnly }
    public convenience init(preview: [WeeklyReport]) { self.init(dir: nil); for r in preview { memory[r.id] = r } }

    private func url(_ id: String) -> URL? { dir?.appendingPathComponent(id + ".json") }

    public func load(_ id: String) -> WeeklyReport? {
        lock.lock(); defer { lock.unlock() }
        if let r = memory[id] { return r }
        guard let u = url(id), let d = try? Data(contentsOf: u) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        guard let r = try? dec.decode(WeeklyReport.self, from: d), r.version <= WeeklyReport.formatVersion else { return nil }
        memory[id] = r
        return r
    }

    /// Every saved week, newest first.
    public func all() -> [WeeklyReport] {
        var ids = Set(lock.withLock { Array(memory.keys) })
        if let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for n in names where n.hasSuffix(".json") { ids.insert(String(n.dropLast(5))) }
        }
        return ids.compactMap(load).sorted { $0.week.start > $1.week.start }
    }

    public func save(_ r: WeeklyReport) {
        lock.withLock { memory[r.id] = r }
        guard let u = url(r.id), !readOnly else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(r) { try? d.write(to: u, options: .atomic) }
    }

    /// Deletes reports for weeks that ended more than `retention` ago.
    public func prune(now: Date = Date()) {
        guard !readOnly else { return }
        for r in all() where now.timeIntervalSince(r.week.end) > Self.retention {
            lock.withLock { memory[r.id] = nil }
            if let u = url(r.id) { try? FileManager.default.removeItem(at: u) }
        }
    }
}
