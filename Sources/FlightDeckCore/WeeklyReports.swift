import Foundation
// The Weekly Report, part 3: sorting Flight Log incidents into slowdown kinds, deciding which weeks to (re)build and
// save, and the opt-in notification's schedule.

/// Which slowdown a Flight Log incident was, by its finding id (see Analyzer), with a label free of the numbers that
/// changed while it lasted, and the app behind it when one can be named.
public enum IncidentKinds {
    public static func classify(_ i: Incident) -> (kind: SlowdownKind, label: String, app: String?)? {
        let parts = i.key.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts[0], rest = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "restart", "awake": return nil   // restarts have their own section; keeping awake is usually intended
        case "cpu":
            let a = appName(rest); return (.cpu, "\(a) kept the CPU busy", a)
        case "cpu-saturated":
            let a = biggest(i.detail); return (.cpu, "The CPU was fully busy", a)
        case "unusual-cpu": return (.cpu, "CPU use was unusually high", nil)
        case "gpu":
            let a = appName(rest); return (.cpu, "\(a) kept the GPU busy", a)
        case "mem-pressure", "swapping", "swap-growing":
            return (.memory, kind == "mem-pressure" ? "Memory pressure" : "Heavy swapping", biggest(i.detail))
        case "leak":
            let a = appName(rest); return (.memory, "\(a) kept growing in memory", a)
        case "thermal": return (.heat, "Slowed itself down to cool off", biggest(i.detail))
        case "cpu-throttled": return (.heat, "CPU throttled for heat", nil)
        case "gpu-thermal": return (.heat, "GPU slowed down for heat", nil)
        case "temp-alert": return (.heat, "Temperature alert", nil)
        case "hang":
            let a = i.title.hasSuffix(" is not responding") ? String(i.title.dropLast(" is not responding".count)) : nil
            return (.hang, "\(a ?? "An app") stopped responding", a)
        default: return (.other, i.title, nil)
        }
    }

    /// "/Applications/Xcode.app" → "Xcode", "proc:node" → "node".
    static func appName(_ key: String) -> String {
        if key.hasPrefix("proc:") { return String(key.dropFirst(5)) }
        let last = (key as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// The app in "Biggest user: X with 3 GB." / "Biggest CPU user: X (4 processes) at 80%.".
    static func biggest(_ detail: String?) -> String? {
        guard let d = detail else { return nil }
        for marker in ["Biggest user: ", "Biggest CPU user: ", "Biggest memory user: "] {
            guard let r = d.range(of: marker) else { continue }
            var name = String(d[r.upperBound...])
            for stop in [" with ", " at ", " (", "."] { if let s = name.range(of: stop) { name = String(name[..<s.lowerBound]) } }
            return name.isEmpty ? nil : name
        }
        return nil
    }
}

public enum WeeklyReports {
    /// Weeks to offer: every week the daily log or the saved reports reach, plus this one.
    public static func weeks(_ src: WeeklySources, saved: [WeeklyReport], calendar: Calendar = .current) -> [WeekRange] {
        var ids: [String: WeekRange] = [:]
        let current = WeekRange.containing(src.now, calendar: calendar)
        ids[current.id] = current
        for d in src.days { let w = WeekRange.containing(d.start, calendar: calendar); ids[w.id] = w }
        for r in saved { ids[r.id] = r.week }
        return ids.values.sorted(by: >)
    }

    /// Builds every week the sources reach that isn't saved as final yet, saves each (unless the store is read-only),
    /// and returns all reports, newest first. Final weeks are never rebuilt: their raw data may be gone.
    @discardableResult
    public static func refresh(store: WeeklyReportStore, sources src: WeeklySources, calendar: Calendar = .current) -> [WeeklyReport] {
        let saved = store.all()
        let byId = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let reachable = Set(src.days.map { WeekRange.containing($0.start, calendar: calendar).id })
        let current = WeekRange.containing(src.now, calendar: calendar)
        for w in weeks(src, saved: saved, calendar: calendar) where !(byId[w.id]?.isFinal ?? false) {
            // Weeks without daily-log days (and not this week) have nothing new to add.
            guard reachable.contains(w.id) || w == current || byId[w.id] != nil else { continue }
            store.save(WeeklyReportBuilder.build(w, from: src, saved: byId[w.id], calendar: calendar))
        }
        store.prune(now: src.now)
        return store.all()
    }

    /// The report for `week` from the saved ones, or built now (not saved) when there is none or it isn't final.
    public static func report(_ week: WeekRange, store: WeeklyReportStore, sources: WeeklySources?, calendar: Calendar = .current) -> WeeklyReport? {
        let saved = store.load(week.id)
        if let saved, saved.isFinal { return saved }
        guard let sources else { return saved }
        // Nothing to build from: a week the daily log doesn't reach (and not this one) has no report.
        let reachable = week.contains(sources.now) || sources.days.contains { week.contains($0.start) }
        guard saved != nil || reachable else { return nil }
        return WeeklyReportBuilder.build(week, from: sources, saved: saved, calendar: calendar)
    }
}

/// When the opt-in weekly notification is due: the latest scheduled time (weekday, minutes after midnight) at or before
/// now that hasn't been delivered. A Mac asleep or FlightDeck not running at that time gets it at the next check
/// (wake or launch). It covers the last finished week.
public enum WeeklySchedule {
    public static let enabledKey = "weeklyReportNotify"
    public static let weekdayKey = "weeklyReportWeekday"
    public static let minutesKey = "weeklyReportMinutes"
    public static let deliveredKey = "weeklyReportDelivered"
    /// Defaults: Monday (Calendar weekday 2), 9:00.
    public static let defaultWeekday = 2
    public static let defaultMinutes = 9 * 60

    /// The most recent scheduled time at or before `now`.
    public static func lastOccurrence(before now: Date, weekday: Int, minutes: Int, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        for back in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today), calendar.component(.weekday, from: day) == weekday,
                  let t = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day), t <= now else { continue }
            return t
        }
        return calendar.date(byAdding: .day, value: -7, to: today)!
    }

    /// The occurrence to deliver now, or nil. `lastDelivered` nil means the schedule was just turned on: nothing is
    /// owed yet (the caller records now as delivered), so turning it on never sends an old week at once.
    public static func due(now: Date, lastDelivered: Date?, weekday: Int, minutes: Int, calendar: Calendar = .current) -> Date? {
        guard let last = lastDelivered else { return nil }
        let t = lastOccurrence(before: now, weekday: weekday, minutes: minutes, calendar: calendar)
        return t > last ? t : nil
    }

    /// The week a notification at `occurrence` reports on: the last one finished by then.
    public static func week(for occurrence: Date, calendar: Calendar = .current) -> WeekRange {
        WeekRange.containing(occurrence, calendar: calendar).previous(calendar: calendar)
    }
}
