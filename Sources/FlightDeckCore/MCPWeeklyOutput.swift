import Foundation
// Output of the read-only `weekly_report` MCP tool: one week's Weekly Report as structured data plus its Markdown text.
// Finished weeks come from the reports the app saved (…/Flightdeck/Reports); this week, and a week with no final saved
// report, are built on the spot from the same sources the page uses (never saved from here).

extension MCPTools {
    func weeklyReport(_ a: Args) async throws -> JSON {
        let back = try a.int("weeks_ago", default: 1, 0...104)
        let now = self.now()
        var week = WeekRange.containing(now)
        for _ in 0..<back { week = week.previous() }
        let store = weeklyStore
        let saved = store.load(week.id)
        var src: WeeklySources?
        if !(saved?.isFinal ?? false) { src = await weeklySources(now: now) }
        let sources = src
        guard let r = WeeklyReports.report(week, store: store, sources: sources) else {
            return object([("summary", .str("No Weekly Report for \(week.title): FlightDeck has no records that far back."))])
        }
        let prevWeek = week.previous()
        let prev = store.load(prevWeek.id) ?? sources.flatMap { s in s.days.contains { prevWeek.contains($0.start) } ? WeeklyReportBuilder.build(prevWeek, from: s) : nil }
        return Self.weeklyJSON(r, previous: prev, extra: sourceInfo.map { ($0.0, $0.1) })
    }

    /// The sources for building a week here: the data source's daily log, Flight Log, battery history, destinations and
    /// snapshot, plus boots and panics (FlightDeck's saved boot history and macOS's records, read-only).
    func weeklySources(now: Date) async -> WeeklySources {
        var s = WeeklySources(now: now)
        s.days = await source.dailyHistory()?.days ?? []
        s.incidents = await source.incidents()
        s.battery = await source.batteryHistory()?.days ?? []
        if let d = await source.destinations() { s.destinationDays = d.days; s.known = d.known }
        if let snap = await source.snapshot(), let v = Analyzer.startupVolume(snap) {
            s.storage = WeeklyStorage(readAt: snap.time, used: v.used, capacity: v.capacity, fullInDays: nil)
        }
        let reader = restartsReader
        if let r = await Task.detached(priority: .utility, operation: { reader() }).value { s.add(r) }
        return s
    }

    static func weeklyJSON(_ r: WeeklyReport, previous: WeeklyReport?, extra: [(String, JSON?)] = []) -> JSON {
        let d = WeeklyDigest.make(r, previous: previous)
        func h(_ x: Double) -> JSON { F.r1(x) }
        let slow: JSON = .object(dropping: [
            ("high_cpu_hours", h(r.cpuHours)), ("memory_pressure_hours", h(r.memoryHours)), ("heat_hours", h(r.heatHours)),
            ("incidents", .int(r.incidentCount)),
            ("days_missing_from_flight_log", r.incompleteDays > 0 ? .int(r.incompleteDays) : nil),
            ("top_incidents", .array(r.incidents.prefix(8).map { i in
                .object(dropping: [("kind", .str(i.kind.rawValue)), ("what", .str(i.label)), ("app", i.app.map(JSON.str)),
                                   ("times", .int(i.count)), ("hours", h(i.seconds / 3600))])
            })),
            ("top_apps_cpu_hours", .array(r.topApps.map { .object([("app", .str($0.name)), ("cpu_hours", h($0.cpuHours))]) })),
            ("average_cpu_percent", r.cpuAverage.map(F.r1) ?? F.unavailable("not sampled this week")),
            ("hottest_c", r.hottest.map(F.r1) ?? F.unavailable("no temperature recorded")),
            ("worst_thermal_state", r.worstThermalState.map { .str(["nominal", "fair", "serious", "critical"][min(max($0, 0), 3)]) }),
        ])
        func event(_ e: WeeklyEvent) -> JSON {
            .object(dropping: [("time", F.time(e.time)), ("kind", .str(e.kind.rawValue)), ("what", .str(e.title)), ("detail", e.detail.map(JSON.str))])
        }
        let restarts: JSON = .object(dropping: [
            ("unexpected_restarts_and_panics", .array(r.restarts.map(event))),
            ("boots", r.boots.map(JSON.int) ?? F.unavailable("boot records not readable")),
            ("app_freezes", .array(r.freezes.prefix(20).map(event))),
            ("app_crash_reports", r.crashes.map(JSON.int) ?? F.unavailable("not counted this week")),
            ("app_hang_reports", r.hangs.map(JSON.int) ?? F.unavailable("not counted this week")),
        ])
        let battery: JSON? = r.battery.map { b in
            .object(dropping: [("cycles_start", b.cyclesStart.map(JSON.int)), ("cycles_end", b.cyclesEnd.map(JSON.int)),
                               ("cycles_used", b.cyclesUsed.map(JSON.int)), ("health_start_percent", b.healthStart.map(F.r1)),
                               ("health_end_percent", b.healthEnd.map(F.r1)), ("health_80_forecast", b.forecast80.map(F.time)),
                               ("health_80_forecast_week_before", b.forecast80Before.map(F.time)), ("forecast_note", b.forecastNote.map(JSON.str))])
        }
        let storage: JSON? = r.storage.map { s in
            .object(dropping: [("read_at", F.time(s.readAt)), ("used", F.bytes(Double(s.used))), ("capacity", F.bytes(Double(s.capacity))),
                               ("free", F.bytes(Double(s.free))), ("full_in_days", s.fullInDays.map(F.r1))])
        }
        let network: JSON = .object(dropping: [
            ("internet_data", r.dataUsed.map { F.bytes(Double($0)) } ?? F.unavailable("data usage not counted this week")),
            ("days_counted", .int(r.dataDays)),
            ("new_destinations", .array(r.newDestinations.prefix(30).map { n in
                .object(dropping: [("app", .str(n.app)), ("destination", .str(n.destination)), ("first_seen", F.time(n.first)),
                                   ("bytes", n.bytes.map { F.bytes(Double($0)) }), ("local_network", n.local ? .bool(true) : nil)])
            })),
        ])
        return .object(dropping: extra + [
            ("summary", .str(d.headline)),
            ("week", .str(r.week.title)), ("week_start", F.time(r.week.start)), ("week_end", F.time(r.week.end)),
            ("status", .str(r.isFinal ? "final" : "in progress")), ("built_at", F.time(r.builtAt)),
            ("days_recorded", .int(r.daysRecorded)), ("hours_sampled", r.observedHours.map(F.r1)),
            ("slowdowns", slow), ("restarts", restarts), ("battery", battery), ("storage", storage), ("network", network),
            ("compared_with_week_before", previous == nil ? F.unavailable("no report for the week before") : nil),
            ("text", .str(d.markdown)),
        ])
    }
}
