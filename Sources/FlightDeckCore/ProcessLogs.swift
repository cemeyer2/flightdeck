import Foundation
// `process_logs`: unified-log messages from one app, process or subsystem, grouped so repeats collapse into one row
// with a count. Reading uses LogReader (`log show --style ndjson`, LogInsights.swift) with a predicate narrowed to the
// target, so `log` filters inside the log store rather than this process parsing everything. Bounded three ways: a
// window limit (checked by the tool), an entry cap and a wall-clock timeout. Long windows are read in chunks, newest
// first, so when a cap stops the read, what was read is the most recent part. Grouping is pure and tested on captured ndjson.

public enum ProcessLogs {
    /// The lowest level asked for; each includes the levels above it (info ⊃ default ⊃ error ⊃ fault).
    public enum Level: String, Sendable, CaseIterable { case fault, error, `default`, info
        var included: Set<LogEntry.Level> {
            switch self { case .fault: [.fault]; case .error: [.error, .fault]; case .default: [.default, .error, .fault]; case .info: [.info, .default, .error, .fault] }
        }
        /// Messages at default and info level are far more numerous, so their windows are kept shorter.
        public var maxMinutes: Int { self == .fault || self == .error ? 1440 : 60 }
    }

    public struct Query: Sendable {
        public var app: String?, pid: Int32?, subsystem: String?
        public var level: Level
        public var from: Date, to: Date
        public var maxEntries = 20_000
        public var timeout: TimeInterval = 20
        public init(app: String? = nil, pid: Int32? = nil, subsystem: String? = nil, level: Level, from: Date, to: Date) {
            self.app = app; self.pid = pid; self.subsystem = subsystem; self.level = level; self.from = from; self.to = to
        }
    }

    /// Distinct message shapes: messages that differ only in numbers, hex values or UUIDs share a group.
    public struct Group: Sendable {
        public var process: String, subsystem: String, category: String
        /// The most severe level seen in the group.
        public var level: LogEntry.Level
        public var count: Int
        public var first: Date, last: Date
        /// The newest message of the group, verbatim (with any "<private>" redactions).
        public var message: String
        public var pids: Set<Int32>
    }

    public struct Result: Sendable {
        /// Newest first (by each group's latest message).
        public var groups: [Group]
        public var total: Int
        public var byLevel: [LogEntry.Level: Int]
        public var redacted: Int
        /// How the read ended: finished, stopped at the entry cap, timed out, or failed (with `log`'s message).
        public var outcome: String
        /// When the read stopped early, the oldest time it reached (older messages weren't read).
        public var readBackTo: Date?
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The `log` predicate: the target's conditions (all of them, when several are given) and the level filter.
    public static func predicate(_ q: Query) -> String {
        var parts: [String] = []
        if let app = q.app {
            // The process name for the main executable; the bundle path for its helpers (Chrome Helper, XPC services).
            parts.append("(process ==[c] \(quoted(app)) OR processImagePath CONTAINS[c] \(quoted("/" + app + ".app/")))")
        }
        if let pid = q.pid { parts.append("processID == \(pid)") }
        if let s = q.subsystem { parts.append("(subsystem == \(quoted(s)) OR subsystem BEGINSWITH \(quoted(s + ".")))") }
        let levels = Level.allCases.filter { q.level.included.contains($0.entryLevel) }.map { "messageType == \($0.rawValue)" }
        parts.append("(" + levels.joined(separator: " OR ") + ")")
        return parts.joined(separator: " AND ")
    }

    private static let variable = try! NSRegularExpression(
        pattern: "0x[0-9a-fA-F]+|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9]+")

    /// A message's shape: numbers, hex values and UUIDs become "#".
    public static func shape(_ m: String) -> String {
        variable.stringByReplacingMatches(in: m, range: NSRange(m.startIndex..., in: m), withTemplate: "#")
    }

    static func rank(_ l: LogEntry.Level) -> Int { switch l { case .fault: 3; case .error: 2; case .default: 1; case .info: 0 } }

    /// Folds entries (any order) into groups, newest first.
    public static func group(_ entries: [LogEntry], outcome: String = "finished", readBackTo: Date? = nil) -> Result {
        var groups: [String: Group] = [:]
        var byLevel: [LogEntry.Level: Int] = [:]
        var redacted = 0
        for e in entries {
            byLevel[e.level, default: 0] += 1
            if e.isRedacted { redacted += 1 }
            let key = [e.process, e.subsystem, e.category, shape(e.message)].joined(separator: "\u{1}")
            guard var g = groups[key] else {
                groups[key] = Group(process: e.process, subsystem: e.subsystem, category: e.category, level: e.level, count: 1,
                                    first: e.time, last: e.time, message: e.message, pids: [e.pid])
                continue
            }
            g.count += 1; g.pids.insert(e.pid)
            if rank(e.level) > rank(g.level) { g.level = e.level }
            if e.time > g.last { g.last = e.time; g.message = e.message }
            g.first = min(g.first, e.time)
            groups[key] = g
        }
        return Result(groups: groups.values.sorted { $0.last != $1.last ? $0.last > $1.last : $0.count > $1.count },
                      total: entries.count, byLevel: byLevel, redacted: redacted, outcome: outcome, readBackTo: readBackTo)
    }

    /// Runs `log show` for the query: chunks newest first (5 min for default/info, 15 min for errors), until the window
    /// is read, `maxEntries` are collected or `timeout` passes. Blocks; call off the main thread.
    public static func read(_ q: Query) -> Result {
        let reader = LogReader()
        let timedOut = Flag()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + q.timeout) { timedOut.set(); reader.cancel() }
        defer { reader.cancel() }   // ends the timer's effect early; a finished reader ignores it
        let chunk: TimeInterval = q.level == .error || q.level == .fault ? 900 : 300
        let p = predicate(q)
        var entries: [LogEntry] = []
        var end = q.to.timeIntervalSince1970.rounded(.up)
        let start0 = q.from.timeIntervalSince1970.rounded(.down)
        while end > start0 {
            let start = max(end - chunk, start0)
            var args = ["show", "--style", "ndjson", "--no-backtrace", "--start", "@\(Int(start))", "--end", "@\(Int(end))", "--predicate", p]
            if q.level == .info { args.append("--info") }
            // Both ends are inclusive in `log`, so an entry on a chunk boundary is kept only in the chunk where it falls in [start, end).
            let r = reader.run(args, levels: q.level.included) { e in
                let t = e.time.timeIntervalSince1970
                if t >= start && t < end && e.time >= q.from && e.time <= q.to { entries.append(e) }
                return entries.count < q.maxEntries
            }
            switch r {
            case .finished: break
            case .capped: return group(entries, outcome: "stopped at \(q.maxEntries) messages", readBackTo: Date(timeIntervalSince1970: start))
            case .cancelled:
                return group(entries, outcome: timedOut.get() ? "timed out after \(Int(q.timeout)) s" : "cancelled", readBackTo: Date(timeIntervalSince1970: end))
            case .failed(let m): return group(entries, outcome: "failed: \(m)", readBackTo: Date(timeIntervalSince1970: end))
            }
            end = start
        }
        return group(entries)
    }
}

extension ProcessLogs.Level {
    /// The log's own name for this level, as used in `messageType == …`.
    var entryLevel: LogEntry.Level {
        switch self { case .fault: .fault; case .error: .error; case .default: .default; case .info: .info }
    }
}

/// A thread-safe one-way flag (set by the timeout timer, read by the reading thread).
private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
}
