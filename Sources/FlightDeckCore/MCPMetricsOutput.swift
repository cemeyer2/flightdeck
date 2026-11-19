import Foundation
// Output of query_metrics (black-box time series, MetricSeries.swift) and process_logs (unified log, ProcessLogs.swift).
// See MCPTools.swift for the conventions.

extension MCPTools {
    /// Series answers stay under this, leaving room inside the server's 48 KB cap for the envelope; a larger answer is
    /// refused with a step that would fit, rather than cut mid-array (a truncated array is useless to a model).
    static let seriesBudgetBytes = 44_000
    static let maxSeriesPoints = 300

    // MARK: query_metrics

    func queryMetrics(_ a: Args) async throws -> JSON {
        guard let names = a.j["metrics"]?.array?.compactMap(\.string), !names.isEmpty, names.count == a.j["metrics"]?.array?.count else {
            throw ArgError(message: "metrics must be a non-empty array of metric names, e.g. [\"cpu\", \"memory_used\"]")
        }
        guard names.count <= 12 else { throw ArgError(message: "at most 12 metrics per call") }
        let unknown = names.filter { MetricSeries.metric($0) == nil }
        guard unknown.isEmpty else {
            throw ArgError(message: "unknown metric\(unknown.count == 1 ? "" : "s"): \(unknown.joined(separator: ", ")). Use \(MetricSeries.systemNames.joined(separator: ", ")), or process:<pid or name>.cpu|rss|energy")
        }
        let metrics = names.compactMap(MetricSeries.metric)
        let w = try resolveWindow(try a.string("from") ?? "-60m", try a.string("to"), "window")
        var asked: Double?
        if let v = a.j["step"], v != .null {
            guard let s = v.double, s >= 1, s <= 3600 else { throw ArgError(message: "step must be a number of seconds between 1 and 3600") }
            asked = s
        }
        guard let (trace, fine) = await windowFrames(w.from, w.to) else {
            return object([("window", windowJSON(w.from, w.to, w.fromMark, w.toMark)), ("summary", .str("No data: " + noBlackBoxReason))])
        }
        let span = w.to.timeIntervalSince(w.from)
        let step = max(asked ?? MetricSeries.autoStep(span: span, minStep: trace.interval, maxPoints: Self.maxSeriesPoints), trace.interval)
        let count = max(Int((span / step).rounded(.up)), 1)
        let frames = trace.frames
        let values = await Task.detached(priority: .userInitiated) { MetricSeries.series(frames, metrics: metrics, from: w.from, step: step, count: count) }.value
        func round(_ v: Double?, _ m: MetricSeries.Metric) -> JSON {
            guard let v else { return .null }
            return m.name == "watts" || m.name.hasSuffix(".energy") ? F.r2(v) : F.r1(v)
        }
        let withData = (0..<count).filter { i in values.contains { $0[i] != nil } }.count
        let out = object([
            ("start", F.time(w.from)), ("end", F.time(w.to)), ("step_s", F.r1(step)), ("points", .int(count)),
            ("tier", .str(fine ? "every sample (\(F.r1(trace.interval).text) s)" : "one sample per \(Int(trace.interval)) s")),
            ("step_note", asked.map { $0 < trace.interval ? .str("step raised to the sampling interval, \(trace.interval) s") : nil } ?? nil),
            ("null_means", "no data for that slot: asleep, FlightDeck not running, or (process metrics) not among the busiest processes recorded; never 0"),
            ("points_with_data", .int(withData)),
            ("units", .object(metrics.map { ($0.name, .str($0.unit)) })),
            ("aggregation", .object(metrics.map { ($0.name, .str($0.agg == .avg ? "average of the slot's samples" : "maximum of the slot's samples")) })),
            ("t", .array((0..<count).map { F.r1(Double($0) * step) })),
            ("series", .object(zip(metrics, values).map { m, v in (m.name, .array(v.map { round($0, m) })) })),
        ])
        let bytes = out.text.utf8.count
        if bytes > Self.seriesBudgetBytes {
            let need = step * (Double(bytes) / Double(Self.seriesBudgetBytes)) * 1.1
            let suggest = MetricSeries.niceSteps.first { $0 >= need } ?? need.rounded(.up)
            throw ArgError(message: "\(count) points × \(metrics.count) metrics is about \(bytes / 1000) KB, over the \(Self.seriesBudgetBytes / 1000) KB answer limit. Use step \(Int(suggest)) or more, fewer metrics, or a shorter window.")
        }
        return out
    }

    // MARK: process_logs

    func processLogs(_ a: Args) async throws -> JSON {
        let app = try a.string("app"), subsystem = try a.string("subsystem")
        let pid: Int32? = try a.j["pid"].flatMap { $0 == .null ? nil : $0 }.map { v in
            guard let i = v.int, i > 0, i <= Int(Int32.max) else { throw ArgError(message: "pid must be a positive integer") }
            return Int32(i)
        }
        guard app != nil || pid != nil || subsystem != nil else { throw ArgError(message: "give at least one of app, pid or subsystem") }
        let level = ProcessLogs.Level(rawValue: try a.choice("level", ProcessLogs.Level.allCases.map(\.rawValue), default: "error"))!
        let limit = try a.int("limit", default: 30, 1...100)
        let from: Date, to: Date
        if let f = try a.string("from") {
            let (t, _) = try resolveTime(try a.string("to") ?? "now", "to")
            (from, to) = (try resolveTime(f, "from", notAfter: t).0, t)
        } else {
            to = try resolveTime(try a.string("to") ?? "now", "to").0
            from = to.addingTimeInterval(-Double(try a.int("last_minutes", default: 15, 1...1440)) * 60)
        }
        guard from < to else { throw ArgError(message: "from must be before to") }
        guard to.timeIntervalSince(from) <= Double(level.maxMinutes) * 60 + 1 else {
            throw ArgError(message: "level \(level.rawValue) is limited to \(level.maxMinutes) minutes per call (the log has far more of those messages); shorten the window or use level error")
        }
        let q = ProcessLogs.Query(app: app, pid: pid, subsystem: subsystem, level: level, from: from, to: to)
        let runner = logRunner
        let r = await Task.detached(priority: .userInitiated) { runner(q) }.value
        let target = [app.map { "app \($0)" }, pid.map { "PID \($0)" }, subsystem.map { "subsystem \($0)" }].compactMap { $0 }.joined(separator: ", ")
        let levelCounts: [(String, JSON)] = [LogEntry.Level.fault, .error, .default, .info].compactMap { l in r.byLevel[l].map { (l.rawValue.lowercased(), .int($0)) } }
        let rows: [JSON] = r.groups.prefix(limit).map { g in
            [F.time(g.last), g.count > 1 ? F.time(g.first) : .null, .int(g.count), .str(g.level.rawValue.lowercased()), .str(g.process),
             .str(g.subsystem.isEmpty ? g.category : g.category.isEmpty ? g.subsystem : "\(g.subsystem):\(g.category)"),
             .str(g.message.count > 300 ? String(g.message.prefix(300)) + "…" : g.message)]
        }
        let summary = r.total == 0
            ? "No \(level == .error ? "errors or faults" : "messages at \(level.rawValue) level or above") from \(target) between \(F.time(from).string!) and \(F.time(to).string!)."
            : "\(r.total) message\(r.total == 1 ? "" : "s") from \(target) in \(r.groups.count) group\(r.groups.count == 1 ? "" : "s"); showing the \(rows.count) most recent."
        return object([
            ("summary", .str(summary)), ("from", F.time(from)), ("to", F.time(to)), ("level", .str(level.rawValue)),
            ("read", .str(r.outcome)), ("read_back_to", r.readBackTo.map { F.time($0) }),
            ("by_level", .object(levelCounts)),
            ("redacted", r.redacted > 0 ? .str("\(r.redacted) \(r.redacted == 1 ? "message contains" : "messages contain") <private>: macOS hides arguments the developer didn't mark public, and FlightDeck can't reveal them") : nil),
            ("columns", ["last", "first", "count", "level", "process", "subsystem", "message"]), ("rows", .array(rows)),
            ("predicate", .str(ProcessLogs.predicate(q))),
        ])
    }
}
