import Foundation
// Schemas and output of `wait_for_event` (block until something happens, for clients without notifications) and
// `triage` (everything wrong right now, ranked). `MCPTools.specs` appends `eventSpecs`.

extension MCPTools {
    static let maxWait = 600

    static var eventSpecs: [MCPToolSpec] {
        [
            MCPToolSpec(name: "wait_for_event", title: "Wait for an event",
                        description: "Blocks until something happens on this Mac, then returns it: a Flight Log incident opening or closing, a new finding, a crash/hang/panic report, a thermal state change or low battery; filtered by kind, app and severity. Or, with until_cpu_below, until total CPU has stayed below that % for settle_seconds (e.g. a build finished and the Mac settled). Returns matched=false after timeout_seconds (max 600). For clients without MCP notifications; subscribed clients get the same events pushed (resources flightdeck://events etc.).",
                        inputSchema: Self.schema([
                            ("kinds", ["type": "array", "description": "Only these event kinds (default all).",
                                       "items": ["type": "string", "enum": .strings(MCPEvent.Kind.allCases.map(\.rawValue))]]),
                            ("app", ["type": "string", "description": "Only events about this app or process (case-insensitive substring of its name or the event title)."]),
                            ("min_severity", Self.enumeration("Lowest severity to accept.", ["info", "caution", "warning"], "info")),
                            ("timeout_seconds", Self.int("Give up after this long.", 1, Self.maxWait, 120)),
                            ("after_seq", ["type": "integer", "description": "Return an already-seen event newer than this seq if one matches (pass the last seq you got, so nothing between calls is missed)."]),
                            ("until_cpu_below", ["type": "number", "minimum": 1, "maximum": 100, "description": "Instead of events: wait until total CPU % stays below this."]),
                            ("settle_seconds", Self.int("With until_cpu_below: how long CPU must stay below it.", 2, 300, 10)),
                        ])),
            MCPToolSpec(name: "triage", title: "Triage: what's wrong right now",
                        description: "One call for \"what's wrong with this Mac right now?\": every current problem across CPU, memory, thermals, disk, battery, network, findings, the Flight Log, crash/hang/panic reports of the last 24 h and unexpected restarts of the last 7 days, ranked by severity (ongoing and recent first), each with evidence numbers and the tool (and arguments) to call next for detail; plus the healthy readings. Read-only and fast (no stack sampling, no Checkup).",
                        inputSchema: Self.schema([("limit", Self.int("Problems to list.", 1, 50, 15))])),
        ]
    }

    func waitForEvent(_ a: Args) async throws -> JSON {
        let timeout = try a.int("timeout_seconds", default: 120, 1...Self.maxWait)
        let started = now()
        if let raw = a.j["until_cpu_below"], raw != .null {
            guard let limit = raw.double ?? raw.int.map(Double.init), (1...100).contains(limit) else { throw ArgError(message: "until_cpu_below must be a number from 1 to 100") }
            return try await waitForCPU(below: limit, settle: try a.int("settle_seconds", default: 10, 2...300), timeout: timeout)
        }
        let kinds = Set(try a.choices("kinds", MCPEvent.Kind.allCases.map(\.rawValue)))
        let app = try a.string("app")?.lowercased()
        let minSev: Finding.Severity = switch try a.choice("min_severity", ["info", "caution", "warning"], default: "info") {
        case "warning": .warning; case "caution": .caution; default: .info
        }
        let after = a.j["after_seq"]?.int
        guard let hub = events else { throw ArgError(message: "Events aren't available from this server.") }
        let hit = await hub.wait(timeout: TimeInterval(timeout), afterSeq: after) { e in
            (kinds.isEmpty || kinds.contains(e.kind.rawValue)) && e.severity >= minSev
                && (app.map { q in (e.app?.lowercased().contains(q) ?? false) || e.title.lowercased().contains(q) } ?? true)
        }
        let waited = F.duration(now().timeIntervalSince(started))
        guard let hit else {
            return object([("matched", false), ("summary", .str("Nothing matching happened in \(timeout) s.")), ("waited", waited),
                           ("last_seq", .int(hub.lastSeq))])
        }
        return object([("matched", true), ("summary", .str("\(hit.title) (\(hit.kind.rawValue), \(F.severity(hit.severity).string ?? "")). Next: \(hit.nextTool).")),
                       ("waited", waited), ("event", hit.json), ("last_seq", .int(max(hit.seq, hub.lastSeq)))])
    }

    /// Polls the latest sample every 2 s, only for the duration of the call.
    func waitForCPU(below limit: Double, settle: Int, timeout: Int) async throws -> JSON {
        let step = 2.0
        var elapsed = 0.0, calm = 0.0
        var last: Double?
        while elapsed <= Double(timeout) {
            if let c = await source.snapshot()?.cpu.total.value {
                last = c
                calm = c < limit ? calm + step : 0
                if calm >= Double(settle) {
                    return object([("matched", true), ("summary", .str(String(format: "CPU settled: below %.0f%% for %d s (now %.0f%%).", limit, settle, c))),
                                   ("waited", F.duration(elapsed)), ("cpu_percent", F.r1(c))])
                }
            }
            if Task.isCancelled { break }
            try? await sleeper(step)
            elapsed += step
        }
        return object([("matched", false),
                       ("summary", .str(String(format: "CPU didn't stay below %.0f%% for %d s within %d s.", limit, settle, timeout))),
                       ("cpu_percent", last.map(F.r1) ?? F.unavailable("no sample"))])
    }

    func triage(_ a: Args) async throws -> JSON {
        let limit = try a.int("limit", default: 15, 1...50)
        let t = now()
        async let snap = source.snapshot()
        async let findings = source.findings()
        async let incidents = source.incidents()
        async let reports = source.reports(since: t.addingTimeInterval(-86_400))
        let read = bootReader
        async let boots = Task.detached(priority: .utility) { read() }.value
        var x = TriageInput(snapshot: await snap, now: t)
        x.findings = await findings; x.incidents = await incidents; x.reports = await reports; x.boots = await boots
        let items = Triage.rank(x)
        let summary: String
        if let worst = items.first {
            let serious = items.filter { $0.severity >= .caution }.count
            summary = "\(items.count) problem\(items.count == 1 ? "" : "s") (\(serious) caution or worse); worst: \(worst.title)."
        } else {
            summary = "Nothing is wrong right now: no findings, ongoing incidents, recent crashes or unexpected restarts."
        }
        let rows: [JSON] = items.prefix(limit).enumerated().map { n, i in
            .object(dropping: [("rank", .int(n + 1)), ("severity", F.severity(i.severity)), ("subsystem", .str(i.subsystem)), ("title", .str(i.title)),
                               ("evidence", .str(i.evidence)), ("since", i.since.map(F.time)), ("ongoing", i.ongoing ? true : nil),
                               ("next", ["tool": .str(i.nextTool), "arguments": i.nextArgs])])
        }
        return object([("time", F.time(t)), ("summary", .str(summary)), ("problems", .array(rows)),
                       ("readings", x.snapshot.map(Self.triageReadings) ?? F.unavailable("no sample could be taken"))])
    }

    /// The headline numbers, so "nothing wrong" comes with evidence too.
    static func triageReadings(_ s: Snapshot) -> JSON {
        let v = Analyzer.startupVolume(s)
        return .object(dropping: [
            ("cpu_percent", F.m(s.cpu.total)), ("memory_pressure_percent", F.m(s.memory.pressure)), ("swap_used", F.m(s.memory.swapUsed, F.bytes)),
            ("thermal_state", F.thermal(s.power.thermalState)), ("hottest_c", F.m(s.power.hottest)),
            ("startup_disk_free", v.map { .str(Fmt.storage($0.available)) }),
            ("battery_percent", s.power.battery.map { F.r1($0.percent) }), ("power_source", .str(s.power.powerSource)),
            ("network_in", F.m(s.network.inBps, F.rate)), ("network_out", F.m(s.network.outBps, F.rate)),
        ])
    }
}
