import Foundation
// The Weekly Report, part 2: building a week from what FlightDeck already keeps. `WeeklySources` is everything read
// once (the daily log's days, the Flight Log, boots and panics, app freezes, battery history, destinations, the
// startup disk now); `WeeklyReportBuilder.build` folds one week out of it, merging in the version saved earlier for
// whatever has aged out of the sources since. Pure: no reading or writing here (WeeklyReports.refresh does that).

public struct WeeklySources: Sendable {
    public var now: Date
    public var days: [DayRecord] = []
    public var incidents: [Incident] = []
    /// How long the Flight Log keeps incidents (IncidentLog.retention).
    public var incidentRetention: TimeInterval = 7 * 86_400
    /// Unexpected shutdowns and panics, and every boot (nil when the boot records couldn't be read).
    public var restarts: [WeeklyEvent] = []
    public var boots: [Date]?
    /// App hangs from macOS's diagnostic reports.
    public var freezes: [WeeklyEvent] = []
    public var battery: [BatteryDay] = []
    public var destinationDays: [DestinationDay] = []
    public var known: KnownDestinations?
    /// The startup disk now, with Analyzer.daysUntilFull if it has a trend.
    public var storage: WeeklyStorage?
    public init(now: Date) { self.now = now }

    /// Takes the restarts, panics and freezes from a RestartsCollector report.
    public mutating func add(_ r: RestartsReport) {
        boots = r.events.map(\.boot)
        var seenPanics = Set<String>()
        for e in r.events where e.previous.isUnexpected {
            let at = e.previous.ended ?? e.boot
            if let p = e.previous.panic { seenPanics.insert(p.path) }
            restarts.append(WeeklyEvent(time: at, kind: e.previous.kind == .panic ? .panic : .unexpected,
                                        title: e.previous.kind == .panic ? "Kernel panic" + (e.previous.panic?.culpritName.map { " (\($0))" } ?? "") : e.previous.title,
                                        detail: e.previous.panic?.explanation ?? e.previous.detail))
        }
        for p in r.panics where !seenPanics.contains(p.path) {
            restarts.append(WeeklyEvent(time: p.time, kind: .panic, title: "Kernel panic" + (p.culpritName.map { " (\($0))" } ?? ""), detail: p.explanation))
        }
        freezes = r.hangs.map { WeeklyEvent(time: $0.time, kind: .freeze, title: "\($0.process) froze", detail: $0.summary) }
    }
}

public enum WeeklyReportBuilder {
    /// Builds `week` from `src`, keeping from `saved` (this week's earlier version) what the sources no longer hold.
    public static func build(_ week: WeekRange, from src: WeeklySources, saved: WeeklyReport? = nil, calendar: Calendar = .current) -> WeeklyReport {
        var r = WeeklyReport(week: week, builtAt: src.now)
        dailyLog(&r, src.days.filter { week.contains($0.start) })
        r.days = flightLog(week, src, saved: saved, calendar: calendar)
        restarts(&r, src, saved: saved)
        r.battery = battery(week, src.battery)
        if src.now < week.end { r.storage = src.storage }
        else { r.storage = saved?.storage ?? (src.now < week.end.addingTimeInterval(86_400) ? src.storage : nil) }
        r.newDestinations = destinations(week, src, saved: saved)
        return r
    }

    static func dailyLog(_ r: inout WeeklyReport, _ days: [DayRecord]) {
        r.daysRecorded = days.count
        let observed = days.reduce(0) { $0 + $1.observedSeconds }
        r.observedHours = observed > 0 ? observed / 3600 : nil
        var cpu = 0.0, w = 0.0
        for d in days { if let c = d.cpuAverage, d.observedSeconds > 0 { cpu += c * d.observedSeconds; w += d.observedSeconds } }
        r.cpuAverage = w > 0 ? cpu / w : nil
        r.pressureMax = days.compactMap(\.pressureMax).max()
        r.hottest = days.compactMap(\.hottest).max()
        r.worstThermalState = days.compactMap(\.worstThermalState).max()
        let crashes = days.compactMap(\.crashes), hangs = days.compactMap(\.hangs)
        r.crashes = crashes.isEmpty ? nil : crashes.reduce(0, +)
        r.hangs = hangs.isEmpty ? nil : hangs.reduce(0, +)
        for d in days { for (k, v) in d.crashesByProcess ?? [:] { r.crashesByProcess[k, default: 0] += v } }
        var apps: [String: Double] = [:]
        for d in days { for a in d.apps { apps[a.name, default: 0] += a.cpuSeconds } }
        r.topApps = apps.filter { $0.value >= 360 }.sorted { $0.value > $1.value }.prefix(5).map { WeeklyApp(name: $0.key, cpuHours: $0.value / 3600) }
        let usage = days.compactMap(\.dataUsage)
        r.dataDays = usage.count
        r.dataUsed = usage.isEmpty ? nil : usage.reduce(0) { $0 + $1.total }
    }

    // MARK: Flight Log

    static func flightLog(_ week: WeekRange, _ src: WeeklySources, saved: WeeklyReport?, calendar: Calendar) -> [WeeklyDay] {
        let classified = src.incidents.compactMap { i in IncidentKinds.classify(i).map { (i, $0) } }
        let retainedFrom = src.now.addingTimeInterval(-src.incidentRetention)
        var out: [WeeklyDay] = []
        var dayStart = week.start
        while dayStart < week.end && dayStart < src.now {
            let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
            let upTo = min(next, src.now)
            func hours(_ kind: SlowdownKind) -> Double {
                let spans = classified.filter { $0.1.kind == kind }.map { ($0.0.start, min($0.0.end ?? src.now, src.now)) }
                return Self.union(spans, from: dayStart, to: upTo) / 3600
            }
            var groups: [String: WeeklyIncident] = [:], order: [String] = []
            for (inc, c) in classified where inc.start >= dayStart && inc.start < upTo {
                let secs = max(min(inc.end ?? src.now, src.now, week.end).timeIntervalSince(inc.start), 0)
                let k = c.kind.rawValue + "|" + c.label
                if var g = groups[k] { g.count += 1; g.seconds += secs; g.severity = max(g.severity, inc.severity.rawValue); groups[k] = g }
                else {
                    groups[k] = WeeklyIncident(kind: c.kind, label: c.label, app: c.app, count: 1, seconds: secs, severity: inc.severity.rawValue, destination: inc.destination)
                    order.append(k)
                }
            }
            let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            var d = WeeklyDay(day: f.string(from: dayStart), start: dayStart, cpuHours: hours(.cpu), memoryHours: hours(.memory),
                              heatHours: hours(.heat), incidents: order.compactMap { groups[$0] }, complete: dayStart >= retainedFrom)
            // A day the Flight Log may have trimmed keeps its earlier tallies, unless the new ones somehow hold more.
            if !d.complete, let old = saved?.days.first(where: { $0.day == d.day }),
               old.complete || old.incidents.reduce(0, { $0 + $1.count }) >= d.incidents.reduce(0, { $0 + $1.count }) { d = old }
            out.append(d)
            dayStart = next
        }
        return out
    }

    /// Seconds of [from, to) covered by at least one span (overlaps counted once).
    static func union(_ spans: [(Date, Date)], from: Date, to: Date) -> Double {
        var clipped: [(Date, Date)] = []
        for s in spans {
            let a = max(s.0, from), b = min(s.1, to)
            if a < b { clipped.append((a, b)) }
        }
        clipped.sort { (l: (Date, Date), r: (Date, Date)) -> Bool in l.0 < r.0 }
        var total = 0.0, cur: (Date, Date)?
        for s in clipped {
            if let c = cur, s.0 <= c.1 { cur = (c.0, max(c.1, s.1)) }
            else { if let c = cur { total += c.1.timeIntervalSince(c.0) }; cur = s }
        }
        if let c = cur { total += c.1.timeIntervalSince(c.0) }
        return total
    }

    // MARK: Restarts, battery, destinations

    static func restarts(_ r: inout WeeklyReport, _ src: WeeklySources, saved: WeeklyReport?) {
        let w = r.week
        func merged(_ new: [WeeklyEvent], _ old: [WeeklyEvent]) -> [WeeklyEvent] {
            var out = new
            for o in old where !out.contains(where: { $0.kind == o.kind && abs($0.time.timeIntervalSince(o.time)) < 300 }) { out.append(o) }
            return out.sorted { $0.time < $1.time }
        }
        r.restarts = merged(src.restarts.filter { w.contains($0.time) }, saved?.restarts ?? [])
        r.freezes = merged(src.freezes.filter { w.contains($0.time) }, saved?.freezes ?? [])
        if let b = src.boots { r.boots = max(b.filter { w.contains($0) }.count, saved?.boots ?? 0) } else { r.boots = saved?.boots }
    }

    static func battery(_ week: WeekRange, _ history: [BatteryDay]) -> WeeklyBattery? {
        let h = history.sorted { $0.start < $1.start }
        let inWeek = h.filter { week.contains($0.start) }, before = h.filter { $0.start < week.start }
        guard !inWeek.isEmpty else { return nil }
        var b = WeeklyBattery()
        b.cyclesStart = before.last(where: { $0.cycles != nil })?.cycles ?? inWeek.first(where: { $0.cycles != nil })?.cycles
        b.cyclesEnd = inWeek.last(where: { $0.cycles != nil })?.cycles
        b.healthStart = before.last(where: { $0.health != nil })?.health ?? inWeek.first(where: { $0.health != nil })?.health
        b.healthEnd = inWeek.last(where: { $0.health != nil })?.health
        let now = BatteryForecast.compute(h.filter { $0.start < week.end }, designCycles: nil, currentCycles: nil)
        let then = BatteryForecast.compute(before, designCycles: nil, currentCycles: nil)
        b.forecast80 = now.status == .forecast ? now.date80 : nil
        b.forecast80Before = then.status == .forecast ? then.date80 : nil
        switch now.status {
        case .forecast: if now.beyondHorizon { b.forecastNote = "Health is falling slowly enough that 80% is more than \(Int(BatteryForecast.horizonYears)) years away." }
        case .insufficient(let needed, _): b.forecastNote = needed
        case .notDeclining(let why): b.forecastNote = why
        case .belowThreshold: b.forecastNote = "Health is already below 80%, the usual service point."
        }
        return b
    }

    static func destinations(_ week: WeekRange, _ src: WeeklySources, saved: WeeklyReport?) -> [WeeklyDestination] {
        var out: [WeeklyDestination] = saved?.newDestinations ?? []
        guard let known = src.known else { return out }
        var bytes: [String: UInt64] = [:], local: [String: Bool] = [:]
        for d in src.destinationDays where week.contains(d.start) {
            for row in d.rows where !row.isOther {
                let k = row.app + "|" + row.destinationKey
                bytes[k, default: 0] += row.total; local[k] = row.scope.isLocal
            }
        }
        for (appKey, a) in known.apps {
            for (dest, seen) in a.dests where week.contains(seen.first) && seen.first.timeIntervalSince(a.first) >= KnownDestinations.learning {
                let k = appKey + "|" + dest
                let item = WeeklyDestination(app: a.name, destination: dest, first: seen.first, bytes: bytes[k], local: local[k] ?? false)
                if let i = out.firstIndex(where: { $0.app == a.name && $0.destination == dest }) {
                    if out[i].bytes ?? 0 <= item.bytes ?? 0 { out[i] = item }
                } else { out.append(item) }
            }
        }
        return out.sorted { $0.first < $1.first }
    }
}
