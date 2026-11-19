import Foundation
// Output of the tools for measuring a coding agent's own work: mark (the one tool that writes, and only FlightDeck's
// marks file), marks, and measure. The arithmetic is in WindowMeasure.swift, ProcessCost.swift and MeasureCompare.swift;
// this file resolves times, picks the black-box tier, and words the result. See MCPTools.swift for the conventions.

extension MCPTools {
    // MARK: Time references

    /// A point in time from a tool argument: "now", a relative "-15m" / "-2h" / "-90s", an ISO 8601 time, a mark id,
    /// or a mark label (its latest use, at or before `notAfter` when given). Returns the date and the mark, if any.
    func resolveTime(_ ref: String, _ arg: String, notAfter: Date? = nil) throws -> (Date, Mark?) {
        let s = ref.trimmingCharacters(in: .whitespaces), now = now()
        if s.lowercased() == "now" { return (now, nil) }
        if s.hasPrefix("-"), let unit = s.last, let n = Double(s.dropFirst().dropLast()), n >= 0,
           let mult = ["s": 1.0, "m": 60, "h": 3600][String(unit)] {
            return (now.addingTimeInterval(-n * mult), nil)
        }
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = opts
            if let d = iso.date(from: s) { return (d, nil) }
        }
        if let m = marks.find(s, notAfter: notAfter, now: now) { return (m.time, m) }
        let known = marks.all(now: now).suffix(8).map { "\($0.label) (\($0.id))" }
        throw ArgError(message: "\(arg) '\(s)' is not \"now\", a relative time like \"-15m\", an ISO 8601 time, or a mark"
                       + (known.isEmpty ? " (there are no marks yet; call mark first)" : ". Recent marks: \(known.joined(separator: ", "))"))
    }

    /// Resolves and checks a window: from before to, not in the future, and inside the black box's 24 h.
    func resolveWindow(_ fromRef: String, _ toRef: String?, _ name: String) throws -> (from: Date, to: Date, fromMark: Mark?, toMark: Mark?) {
        let (to, toMark) = try resolveTime(toRef ?? "now", "\(name) to")
        let (from, fromMark) = try resolveTime(fromRef, "\(name) from", notAfter: to)
        let now = now()
        guard from < to else { throw ArgError(message: "\(name): from (\(F.time(from).string!)) must be before to (\(F.time(to).string!))") }
        guard to <= now.addingTimeInterval(5) else { throw ArgError(message: "\(name): to is in the future") }
        guard now.timeIntervalSince(from) <= source.blackBoxConfig.coarseRetention else {
            throw ArgError(message: "\(name): from is more than \(Int(source.blackBoxConfig.coarseRetention / 3600)) h ago; the black box only keeps the last \(Int(source.blackBoxConfig.coarseRetention / 3600)) h")
        }
        return (from, to, fromMark, toMark)
    }

    /// Black-box frames for [from, to] plus a few before `from` (counter baselines). Every sample when the fine tier
    /// still reaches back to `from`, else the coarse tier (one per 10 s).
    func windowFrames(_ from: Date, _ to: Date) async -> (trace: Trace, fine: Bool)? {
        let cfg = source.blackBoxConfig
        if now().timeIntervalSince(from) < cfg.fineRetention - 10,
           let t = await source.blackBox(.fine, from: from.addingTimeInterval(-3), to: to), t.frames.contains(where: { $0.time >= from }) {
            return (t, true)
        }
        guard let t = await source.blackBox(.coarse, from: from.addingTimeInterval(-cfg.coarseEvery * 2.5), to: to),
              t.frames.contains(where: { $0.time >= from }) else { return nil }
        return (t, false)
    }

    /// Said whenever there is nothing to measure, so the model can tell the user what to do instead of guessing.
    var noBlackBoxReason: String {
        source.standalone
            ? "FlightDeck --mcp is running standalone (the FlightDeck app's MCP server isn't answering) and the app's black box has no samples in this window. Measuring needs the black box, which only the FlightDeck app records, while it runs. Open FlightDeck (with the black box on in Settings) before the work, then measure again. Marks are still stored and will appear on the app's Flight Log timeline."
            : "The black box has no samples in this window: the Mac was asleep, or the black box is off (Settings), or the window is less than a second old."
    }

    // MARK: mark / marks

    func mark(_ a: Args) async throws -> JSON {
        guard let label = try a.string("label") else { throw ArgError(message: "label is required") }
        let m: Mark
        do { m = try marks.add(label: label, at: now()) } catch let e as MarkStore.StoreError { throw ArgError(message: e.description) }
        // Whether a measurement starting here will have data: anything recorded in the last two minutes means the
        // black box is running (the fine tier includes frames not yet written to disk when this is the app).
        let recent = await source.blackBox(.fine, from: m.time.addingTimeInterval(-120), to: m.time)
        let recording = !(recent?.frames.isEmpty ?? true)
        return object([
            ("id", .str(m.id)), ("label", .str(m.label)), ("time", F.time(m.time)),
            ("black_box", recording ? "recording" : .str("not recording: " + noBlackBoxReason)),
            ("next", .str("Run the work, then call mark again (e.g. label \"\(m.label)-end\") and measure from \"\(m.id)\" to the end mark, or to \"now\".")),
        ])
    }

    func listMarks(_ a: Args) async throws -> JSON {
        let hours = try a.int("hours", default: 24, 1...48)
        let limit = try a.int("limit", default: 30, 1...200)
        let now = now()
        let all = marks.all(now: now).filter { now.timeIntervalSince($0.time) <= Double(hours) * 3600 }
        let rows: [JSON] = all.reversed().prefix(limit).map { m in [.str(m.id), .str(m.label), F.time(m.time), F.duration(now.timeIntervalSince(m.time))] }
        return object([("summary", .str(all.isEmpty ? "No marks in the last \(hours) h." : "\(all.count) mark\(all.count == 1 ? "" : "s") in the last \(hours) h, newest first.")),
                       ("columns", ["id", "label", "time", "age"]), ("rows", .array(rows))])
    }

    // MARK: measure

    func measure(_ a: Args) async throws -> JSON {
        guard let fromRef = try a.string("from") else { throw ArgError(message: "from is required (a mark id or label, an ISO time, or e.g. \"-10m\")") }
        let w = try resolveWindow(fromRef, try a.string("to"), "window")
        let process = try a.string("process"), app = try a.string("app")
        if process != nil && app != nil { throw ArgError(message: "give process or app, not both") }
        var baseline: (from: Date, to: Date, fromMark: Mark?, toMark: Mark?)?
        if let c = a.j["compare_to"], c != .null {
            guard let f = c["from"]?.string else { throw ArgError(message: "compare_to must be an object {\"from\": …, \"to\": …} with mark ids, labels or times") }
            baseline = try resolveWindow(f, c["to"]?.string, "compare_to")
        }
        guard let (trace, fine) = await windowFrames(w.from, w.to) else {
            return object([("window", windowJSON(w.from, w.to, w.fromMark, w.toMark)), ("summary", .str("Can't measure: " + noBlackBoxReason))])
        }
        let interval = trace.interval
        let m = await Task.detached(priority: .userInitiated) { WindowMeasurement.compute(trace.frames, interval: interval, from: w.from, to: w.to) }.value
        let tree = (process != nil || app != nil) ? m.tree(process: process, app: app, frames: trace.frames) : nil
        if (process != nil || app != nil) && tree == nil {
            var names = Set<String>()
            let seen = m.topProcesses(\.cpuSeconds, 30).map(\.name).filter { names.insert($0).inserted }.prefix(12)
            throw ArgError(message: "No recorded process matches \(process.map { "process '\($0)'" } ?? "app '\(app!)'") in this window. Busiest recorded: \(seen.joined(separator: ", "))")
        }
        let subject = (process ?? app).map { "the \($0) process tree" } ?? "the Mac"
        var pairs: [(String, JSON?)] = [
            ("window", windowJSON(w.from, w.to, w.fromMark, w.toMark)),
            ("summary", .str(Self.measureSummary(m, tree: tree, subject: subject))),
            ("data", coverageJSON(m, fine: fine)),
            ("system", Self.systemJSON(m)),
            ("top_processes", Self.rankings(m, apps: false)),
            ("top_apps", Self.rankings(m, apps: true)),
        ]
        if let tree { pairs.insert(("filter", Self.treeJSON(tree, m, subject: subject)), at: 2) }
        if let b = baseline {
            if let (bt, bfine) = await windowFrames(b.from, b.to) {
                let iv = bt.interval
                let bm = await Task.detached(priority: .userInitiated) { WindowMeasurement.compute(bt.frames, interval: iv, from: b.from, to: b.to) }.value
                let btree = tree != nil ? bm.tree(process: process, app: app, frames: bt.frames) : nil
                let deltas = MeasureCompare.compare(MeasureFigures(m, tree: tree), MeasureFigures(bm, tree: btree))
                // With a filter, the whole Mac is compared too, as context: was something else busier in one run?
                let context = tree == nil ? nil : MeasureCompare.compare(MeasureFigures(m, tree: nil), MeasureFigures(bm, tree: nil))
                pairs.insert(("comparison", Self.comparisonJSON(deltas, context: context, subject: subject, baseline: windowJSON(b.from, b.to, b.fromMark, b.toMark),
                                                                  baselineCoverage: coverageJSON(bm, fine: bfine), treeMissing: tree != nil && btree == nil)), at: 2)
            } else {
                pairs.insert(("comparison", .str("unavailable (baseline window: \(noBlackBoxReason))")), at: 2)
            }
        }
        pairs.append(("accuracy_note", .str(Self.accuracyNote(fine: fine, interval: interval, filtered: tree != nil))))
        return object(pairs)
    }

    func windowJSON(_ from: Date, _ to: Date, _ fm: Mark?, _ tm: Mark?) -> JSON {
        ["from": F.time(from), "to": F.time(to), "duration": F.duration(to.timeIntervalSince(from)), "duration_s": F.r1(to.timeIntervalSince(from)),
         "from_mark": fm.map { .str("\($0.label) (\($0.id))") }, "to_mark": tm.map { .str("\($0.label) (\($0.id))") }]
    }

    func coverageJSON(_ m: WindowMeasurement, fine: Bool) -> JSON {
        let pct = m.seconds > 0 ? min(m.recordedSeconds / m.seconds * 100, 100) : 0
        let gaps = m.gaps.sorted { $0.seconds > $1.seconds }.prefix(5).map { g -> JSON in ["start": F.time(g.start), "length": F.duration(g.seconds)] }
        var note: String?
        if let last = m.gaps.last, last.start.addingTimeInterval(last.seconds) >= m.to.addingTimeInterval(-1), source.standalone {
            note = "The end of the window isn't on disk yet: the app writes its black box every minute (every 10 minutes beyond the last hour). Measure again shortly for the full window."
        } else if pct < 90 {
            note = "Part of the window wasn't recorded (asleep, FlightDeck not running, or the black box paused); totals cover the recorded part only."
        }
        return .object(dropping: [("tier", .str(fine ? "every sample (\(F.r1(m.interval).text) s)" : "one sample per \(Int(m.interval)) s")),
                                  ("samples", .int(m.frames)), ("recorded_percent", F.r1(pct)),
                                  ("gaps", gaps.isEmpty ? "none" : .array(gaps)), ("note", note.map(JSON.str))])
    }
}
