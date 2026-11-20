// Demo mode's Weekly Report: three invented weeks run through the real builder. Last week was busy (a kernel panic
// blamed on WindowServer, an afternoon of heat slowdowns during a video export, a sync app's new destination and a
// jump in battery cycles from travel); the week before was calm, for the deltas; this week has barely started.
// Nothing here comes from this Mac, and nothing is saved.
import Foundation
import FlightDeckCore

enum DemoWeekly {
    /// The invented reports, newest first, and the busy week's id (the page opens on it in demo mode).
    static func reports(now: Date = Date(), calendar: Calendar = .current) -> (reports: [WeeklyReport], busy: String) {
        let current = WeekRange.containing(now, calendar: calendar)
        let busy = current.previous(calendar: calendar), calm = busy.previous(calendar: calendar)
        let src = sources(now: now, busy: busy, calm: calm, current: current, calendar: calendar)
        // The calm week's report was saved a week ago, so it has its own disk reading; the busy week's was read Monday.
        var calmReport = WeeklyReportBuilder.build(calm, from: src, calendar: calendar)
        calmReport.builtAt = calm.end.addingTimeInterval(9 * 3600)
        calmReport.storage = WeeklyStorage(readAt: calm.end.addingTimeInterval(9 * 3600), used: 402_000_000_000, capacity: 994_000_000_000, fullInDays: nil)
        var busyReport = WeeklyReportBuilder.build(busy, from: src, calendar: calendar)
        busyReport.builtAt = busy.end.addingTimeInterval(9 * 3600)
        busyReport.storage = WeeklyStorage(readAt: busy.end.addingTimeInterval(9 * 3600), used: 431_000_000_000, capacity: 994_000_000_000, fullInDays: nil)
        let now = WeeklyReportBuilder.build(current, from: src, saved: nil, calendar: calendar)
        return ([now, busyReport, calmReport], busy.id)
    }

    static func sources(now: Date, busy: WeekRange, calm: WeekRange, current: WeekRange, calendar: Calendar) -> WeeklySources {
        var s = WeeklySources(now: now)
        s.incidentRetention = 60 * 86_400   // invented incidents never age out
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.calendar = calendar
        func at(_ w: WeekRange, _ day: Int, _ hour: Double) -> Date {
            calendar.date(byAdding: .day, value: day, to: w.start)!.addingTimeInterval(hour * 3600)
        }
        // Daily records for both weeks and this week so far.
        var k = 0
        for (w, isBusy) in [(calm, false), (busy, true), (current, false)] {
            for i in 0..<7 {
                let start = calendar.date(byAdding: .day, value: i, to: w.start)!
                guard start < calendar.startOfDay(for: now) || w != current else { continue }
                k += 1
                var d = DayRecord(day: fmt.string(from: start), start: start)
                d.observedSeconds = (i >= 5 ? 3 : 8) * 3600
                d.cpuAverage = isBusy ? 27 + Double(i % 3) * 4 : 15 + Double(i % 2) * 3
                d.pressureMax = isBusy ? 78 : 52
                d.hottest = isBusy && i == 2 ? 96 : (isBusy ? 84 : 71)
                d.worstThermalState = isBusy && i == 2 ? 2 : 0
                d.crashes = isBusy && i == 3 ? 2 : 0; d.crashesByProcess = isBusy && i == 3 ? ["Photo Editor": 2] : [:]
                d.hangs = isBusy && (i == 1 || i == 4) ? 1 : 0
                d.batteryHealth = 91.6 - Double(k) * 0.05
                d.cycleCount = 300 + k / 2 + (isBusy ? (i + 1) * 2 : 0) + (w == current ? 14 : 0)
                func app(_ n: String, _ hours: Double) -> AppDay { var a = AppDay(id: "/Applications/\(n).app", name: n); a.cpuSeconds = hours * 3600; a.runningSeconds = 6 * 3600; return a }
                d.apps = isBusy ? [app("Video Studio", i == 2 ? 3.4 : 0.6), app("Safari", 0.5), app("CloudSyncr", 0.4)] : [app("Safari", 0.4), app("Mail", 0.1)]
                d.dataUsage = DataUsageDay(apps: [], totalIn: UInt64(isBusy ? 6.1e9 : 2.8e9), totalOut: UInt64(isBusy ? 1.2e9 : 0.4e9),
                                           countedSeconds: d.observedSeconds, firstCounted: start)
                s.days.append(d)
            }
        }
        // Battery history: four months of slow decline (health and cycles), so the forecast has a trend; the days
        // above override their own dates.
        var battery: [BatteryDay] = []
        for back in stride(from: 120, to: 0, by: -2) {
            let start = calendar.date(byAdding: .day, value: -back, to: calm.start)!
            battery.append(BatteryDay(day: fmt.string(from: start), start: start, health: 94.5 - Double(120 - back) * 0.022, cycles: 240 + (120 - back) / 2, source: .demo))
        }
        s.battery = BatteryHistory.merge(battery, s.days.compactMap(BatteryDay.init).map { var b = $0; b.source = .demo; return b })

        func inc(_ key: String, _ title: String, _ detail: String?, _ start: Date, minutes: Double, _ sev: Finding.Severity = .caution, _ dest: String = "Processes") -> Incident {
            Incident(id: UUID(), key: key, severity: sev, icon: "cpu", title: title, detail: detail, destination: dest, start: start, end: start.addingTimeInterval(minutes * 60))
        }
        s.incidents = [
            // The calm week: two short busy spells.
            inc("cpu:/Applications/Safari.app", "Safari is using 140% CPU", nil, at(calm, 1, 14), minutes: 25),
            inc("mem-pressure", "Memory pressure is elevated", "Biggest user: Safari with 3.1 GB. macOS is compressing memory.", at(calm, 3, 16), minutes: 40, .caution, "Performance:Memory"),
            // The busy week: an export that heated the Mac, memory pressure from it, freezes and a sync app.
            inc("cpu:/Applications/Video Studio.app", "Video Studio is using 640% CPU", nil, at(busy, 2, 13), minutes: 170),
            inc("thermal", "Thermal pressure is Serious", "Hottest sensor 96 °C. Biggest CPU user: Video Studio.", at(busy, 2, 13.6), minutes: 95, .warning, "Performance:Thermals"),
            inc("cpu-throttled", "CPU is throttled", nil, at(busy, 2, 14), minutes: 50, .caution, "Performance:Thermals"),
            inc("mem-pressure", "Memory pressure is elevated", "Biggest user: Video Studio with 14 GB. macOS is compressing memory.", at(busy, 2, 14.2), minutes: 120, .caution, "Performance:Memory"),
            inc("cpu:/Applications/Video Studio.app", "Video Studio is using 580% CPU", nil, at(busy, 4, 10), minutes: 65),
            inc("mem-pressure", "Memory pressure is critical", "Biggest user: Video Studio with 16 GB.", at(busy, 4, 10.3), minutes: 55, .warning, "Performance:Memory"),
            inc("hang:812-1", "Mail is not responding", nil, at(busy, 1, 9.5), minutes: 2, .warning),
            inc("hang:913-1", "Photo Editor is not responding", nil, at(busy, 4, 15), minutes: 1.5, .warning),
            inc("cpu:/Applications/CloudSyncr.app", "CloudSyncr is using 180% CPU", nil, at(busy, 0, 8.2), minutes: 30),
            inc("cpu:/Applications/CloudSyncr.app", "CloudSyncr is using 160% CPU", nil, at(busy, 5, 8.1), minutes: 20),
        ]
        s.restarts = [WeeklyEvent(time: at(busy, 3, 11.4), kind: .panic, title: "Kernel panic (WindowServer)",
                                  detail: "WindowServer stopped responding for 120 seconds and the watchdog restarted the Mac. Usually a display or graphics driver problem; keep macOS up to date.")]
        s.boots = [at(calm, 0, 8.5), at(calm, 4, 8.6), at(busy, 0, 8.4), at(busy, 3, 11.45), at(busy, 6, 9)]
        s.freezes = [WeeklyEvent(time: at(busy, 1, 9.5), kind: .freeze, title: "Mail froze", detail: "lasted 95.20s"),
                     WeeklyEvent(time: at(busy, 4, 15), kind: .freeze, title: "Photo Editor froze", detail: "lasted 31.04s")]
        // Destinations: CloudSyncr (known for months) reached a new host last Wednesday; a browser's new sites are counted only.
        var row = DestinationRow(app: "/Applications/CloudSyncr.app", appName: "CloudSyncr", ip: "203.0.113.40", scope: .publicInternet,
                                 host: "upload-eu.datahaven.example", nameSource: .reverseDNS, first: at(busy, 2, 21), last: at(busy, 2, 23))
        row.bytesOut = 2_400_000_000; row.bytesIn = 30_000_000
        var known = KnownDestinations()
        let longAgo = calm.start.addingTimeInterval(-90 * 86_400)
        known.note(app: "/Applications/CloudSyncr.app", name: "CloudSyncr", dest: "cloudsyncr.example", at: longAgo)
        known.note(app: "/Applications/CloudSyncr.app", name: "CloudSyncr", dest: row.destinationKey, at: at(busy, 2, 21))
        known.note(app: "/Applications/Safari.app", name: "Safari", dest: "news.example", at: longAgo)
        known.note(app: "/Applications/Safari.app", name: "Safari", dest: "recipes.example", at: at(busy, 5, 19))
        s.known = known
        s.destinationDays = [DestinationDay(start: calendar.date(byAdding: .day, value: 2, to: busy.start)!, rows: [row])]
        return s
    }
}
