import Foundation
// Output of the MCP tools that look back in time: recent_incidents (Flight Log), diagnostic_reports (macOS reports),
// history (black box statistics), checkup and trends (daily log). See MCPTools.swift for the conventions.

extension MCPTools {
    // MARK: recent_incidents

    func recentIncidents(_ a: Args) async throws -> JSON {
        let hours = try a.int("hours", default: 24, 1...168)
        let limit = try a.int("limit", default: 20, 1...100)
        let minSev: Finding.Severity = switch try a.choice("min_severity", ["info", "caution", "warning"], default: "info") {
        case "warning": .warning; case "caution": .caution; default: .info
        }
        let now = now(), from = now.addingTimeInterval(-Double(hours) * 3600)
        // An incident is in the window if any part of it is: it ended after `from` (or is still going).
        let all = await source.incidents().filter { ($0.end ?? now) >= from && $0.severity >= minSev }.sorted { $0.start > $1.start }
        let rows: [JSON] = all.prefix(limit).map { i in
            ["start": F.time(i.start), "duration": F.duration((i.end ?? now).timeIntervalSince(i.start)), "ongoing": i.end == nil ? true : nil,
             "severity": F.severity(i.severity), "title": .str(i.title), "detail": i.detail.map(JSON.str),
             // Stack samples for hangs and hogs; for network incidents, the state saved with them (a file the user can open).
             (i.key.hasPrefix("net-") ? "evidence_summary" : "stack_summary"): i.evidenceSummary.map(JSON.str),
             "evidence_file": i.evidencePath.flatMap { FileManager.default.fileExists(atPath: $0) ? JSON.str($0) : nil }]
        }
        let ongoing = all.filter { $0.end == nil }.count
        let summary = all.isEmpty ? "No incidents in the last \(hours) h." : "\(all.count) incident\(all.count == 1 ? "" : "s") in the last \(hours) h" + (ongoing > 0 ? ", \(ongoing) ongoing." : ".")
        return object([("now", F.time(now)), ("summary", .str(summary)), ("shown", .int(rows.count)), ("incidents", .array(rows))])
    }

    // MARK: diagnostic_reports

    /// Tool names for report kinds (the enum's raw values are UI labels).
    static func kindName(_ k: DiagnosticReport.Kind) -> String {
        switch k {
        case .crash: "crash"; case .panic: "panic"; case .userFault: "fault"; case .hang: "hang"; case .jetsam: "jetsam"
        case .cpuLimit: "cpu_limit"; case .diskWrites: "disk_writes"; case .wakeups: "wakeups"; case .other: "other"
        }
    }

    func diagnosticReports(_ a: Args) async throws -> JSON {
        let hours = try a.int("hours", default: 24, 1...168)
        let kind = try a.string("kind")
        if let kind, !Self.reportKinds.contains(kind) { throw ArgError(message: "kind must be one of: \(Self.reportKinds.joined(separator: ", "))") }
        let process = try a.string("process")?.lowercased()
        let limit = try a.int("limit", default: 20, 1...100)
        let now = now()
        let all = await source.reports(since: now.addingTimeInterval(-Double(hours) * 3600))
            .filter { r in (kind == nil || Self.kindName(r.kind) == kind) && (process.map { r.process.lowercased().contains($0) } ?? true) }
            .sorted { $0.time > $1.time }
        var byKind: [String: Int] = [:], byProcess: [String: Int] = [:]
        for r in all { byKind[Self.kindName(r.kind), default: 0] += 1; byProcess[r.process, default: 0] += 1 }
        let rows: [JSON] = all.prefix(limit).map { r in
            ["time": F.time(r.time), "kind": .str(Self.kindName(r.kind)), "process": .str(r.process), "summary": r.summary.map(JSON.str),
             "file": .str((r.path as NSString).lastPathComponent)]
        }
        return object([
            ("now", F.time(now)), ("window_hours", .int(hours)), ("total", .int(all.count)),
            ("by_kind", .object(byKind.sorted { $0.value > $1.value }.map { ($0.key, .int($0.value)) })),
            ("top_processes", .object(byProcess.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(10).map { ($0.key, .int($0.value)) })),
            ("shown", .int(rows.count)), ("reports", .array(rows)),
        ])
    }

    // MARK: history

    func history(_ a: Args) async throws -> JSON {
        let minutes = try a.int("minutes", default: 60, 1...1440)
        let now = now(), from = now.addingTimeInterval(-Double(minutes) * 60)
        // Every sample when the fine tier covers the window, else one per 10 s (as Replay Black Box chooses).
        let tier: BlackBox.Tier = Double(minutes) * 60 <= source.blackBoxConfig.fineRetention ? .fine : .coarse
        guard let t = await source.blackBox(tier, from: from, to: now), !t.frames.isEmpty else {
            return object([("summary", .str("The black box has no samples from the last \(minutes) minutes. It records only while the FlightDeck app runs (Settings can turn it off)."))])
        }
        let st = await Task.detached(priority: .userInitiated) { TraceStats.compute(t) }.value
        func stat(_ x: TraceStats.Stat?, _ f: (Double) -> JSON = F.r1) -> JSON {
            x.map { ["avg": f($0.avg), "p95": f($0.p95), "peak": f($0.peak)] } ?? F.unavailable("not measured in this window")
        }
        let stats: JSON = [
            "cpu_percent": stat(st.cpu), "memory_pressure_percent": stat(st.pressure),
            "memory_used_percent": stat(st.memoryUsedFraction) { F.r1($0 * 100) }, "swap_used": stat(st.swap, F.bytes),
            "disk": stat(st.diskBps, F.rate), "network": stat(st.netBps, F.rate), "system_watts": stat(st.watts),
            "hottest_c": stat(st.hottest), "gpu_percent": stat(st.gpu), "worst_thermal_state": F.thermal(st.worstThermalState),
        ]
        let problems: [JSON] = st.findings.sorted { $0.start > $1.start }.prefix(15).map { i in
            ["start": F.time(i.start), "duration": F.duration(i.duration), "severity": F.severity(i.severity), "title": .str(i.title)]
        }
        return object([
            ("from", F.time(st.start)), ("to", F.time(st.end)), ("samples", .int(st.frames)), ("sample_every_s", F.r1(t.interval)),
            ("coverage_note", Double(st.frames) * t.interval < Double(minutes) * 60 * 0.8
                ? "Samples cover less than the window: FlightDeck wasn't running (or the Mac slept) part of the time." : nil),
            ("stats", stats),
            ("top_cpu_apps", .array(st.topCPU.prefix(8).map { ["app": .str($0.name), "avg_cpu_percent": F.r1($0.avg)] })),
            ("top_memory_apps", .array(st.topMemory.prefix(8).map { ["app": .str($0.name), "peak": F.bytes($0.peak)] })),
            ("problems", problems.isEmpty ? "none lasting 20 s or more" : .array(problems)),
        ])
    }

    // MARK: checkup

    func checkup() async throws -> JSON {
        let r = await source.checkup()
        let helper = await source.helperAccess()
        let attention = r.filter { $0.status == .attention }, unknown = r.filter { $0.status == .unknown }
        func row(_ c: CheckResult) -> JSON {
            ["group": .str(c.group), "title": .str(c.title), "value": .str(c.value), "detail": c.detail.isEmpty ? nil : .str(c.detail)]
        }
        return object([
            ("summary", .str("\(r.count - attention.count - unknown.count) OK, \(attention.count) need attention, \(unknown.count) unknown")),
            ("needs_attention", .array(attention.map(row))),
            ("unknown", unknown.isEmpty ? nil : .array(unknown.map(row))),
            // Passing checks in one line each: the model rarely needs their detail.
            ("ok", .strings(r.filter { $0.status == .pass }.map { "\($0.title): \($0.value)" })),
        ] + helperPairs(helper))
    }

    // MARK: trends

    func trends(_ a: Args) async throws -> JSON {
        let n = try a.int("days", default: 7, 1...90)
        let appName = try a.string("app")
        guard let h = await source.dailyHistory(), !h.days.isEmpty else {
            return object([("summary", .str("No daily history yet: FlightDeck builds it while the app runs."))])
        }
        let days = Array(h.days.suffix(n))
        let firstDay = days.first!.start
        var pairs: [(String, JSON?)] = [("days_recorded", .int(h.days.count)), ("shown", .int(days.count))]
        func opt(_ v: Double?, _ f: (Double) -> JSON = F.r1) -> JSON { v.map(f) ?? .null }
        func optInt(_ v: Int?) -> JSON { v.map(JSON.int) ?? .null }
        if let appName {
            let key = appName.lowercased()
            let rows: [JSON] = days.compactMap { d in
                guard let x = d.apps.first(where: { $0.name.lowercased() == key }) else { return nil }
                return [.str(d.day), x.version.map(JSON.str) ?? .null, opt(x.averageCPU), opt(x.averageMemory, F.bytes),
                        F.bytes(Double(x.peakMemory)), opt(x.energyWh, F.r2), F.r1(x.runningSeconds / 3600),
                        optInt(d.crashesByProcess?[x.name]), optInt(d.hangsByProcess?[x.name])]
            }
            guard !rows.isEmpty else {
                let known = Set(days.flatMap { $0.apps.map(\.name) }).sorted().prefix(30)
                throw ArgError(message: "No days with an app named '\(appName)' (apps tracked: \(known.joined(separator: ", ")))")
            }
            pairs += [("app", .str(appName)),
                      ("columns", ["day", "version", "avg_cpu_percent", "avg_memory", "peak_memory", "energy_wh", "running_h", "crashes", "hangs"]),
                      ("rows", .array(rows))]
        } else {
            let rows: [JSON] = days.map { d in
                [.str(d.day), F.r1(d.observedSeconds / 3600), opt(d.cpuAverage), opt(d.cpuP95), opt(d.pressureAverage),
                 opt(d.swapMax, F.bytes), opt(d.energyWh), opt(d.hottest), opt(d.sleepHours), optInt(d.crashes), optInt(d.hangs),
                 optInt(d.incidents), d.osVersion.map(JSON.str) ?? .null]
            }
            pairs += [("columns", ["day", "observed_h", "cpu_avg_percent", "cpu_p95_percent", "pressure_avg_percent", "swap_max", "energy_wh",
                                   "hottest_c", "sleep_h", "crashes", "hangs", "incidents", "macos"]),
                      ("rows", .array(rows)), ("note", "null = not measured that day")]
        }
        // Updates in the window, compared over the full history (the comparison needs days on both sides).
        let updates = Trends.updates(h.days).filter { $0.date >= firstDay }
            .filter { e in appName.map { n in if case .app(_, let name) = e.subject { return name.lowercased() == n.lowercased() }; return false } ?? true }
            .suffix(10)
        if !updates.isEmpty {
            pairs.append(("updates", .array(updates.reversed().map { e in
                ["day": .str(e.day), "update": .str(e.title), "from": e.from.map(JSON.str), "to": .str(e.to),
                 "comparison": .str(Trends.compare(h.days, around: e).summary)]
            })))
        }
        return object(pairs)
    }
}
