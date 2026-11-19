import Foundation
// Log insights for the Console destination: parses the unified log's ndjson output (`log show` / `log stream
// --style ndjson`) into `LogEntry` values, folds them into per-process/subsystem groups with time buckets
// (`LogAggregator`), and runs the `log` tool itself (`LogReader`). Parsing and grouping are pure and tested on captured
// lines; only `LogReader` touches the system. Everything here runs off the main thread.

/// One message from the unified log: an error or fault for the Console page; `process_logs` (ProcessLogs.swift) also
/// reads default and info messages.
public struct LogEntry: Sendable, Hashable {
    public enum Level: String, Sendable, Hashable { case error = "Error", fault = "Fault", `default` = "Default", info = "Info" }
    public var time: Date
    public var level: Level
    /// Executable name (last path component of processImagePath); "pid N" if the log didn't give a path.
    public var process: String
    public var pid: Int32
    /// "" when the message has no subsystem (common for older C APIs and the kernel).
    public var subsystem: String
    public var category: String
    /// The rendered message, capped at `LogParser.maxMessageLength` characters. macOS replaces arguments not marked
    /// public with "<private>"; that text is kept as is.
    public var message: String
    public init(time: Date, level: Level, process: String, pid: Int32, subsystem: String, category: String, message: String) {
        self.time = time; self.level = level; self.process = process; self.pid = pid
        self.subsystem = subsystem; self.category = category; self.message = message
    }
    /// True if macOS redacted part of the message.
    public var isRedacted: Bool { message.contains("<private>") }
}

/// Parses ndjson lines from `log show` / `log stream`. Lines that aren't log events (the "Filtering the log data…"
/// banner `log stream` prints first, the trailing `{"count":…,"finished":1}` record, a line cut short by a cap) yield nil.
public enum LogParser {
    /// Messages can be many kilobytes (dumped plists, stack text); only the start is useful for grouping and display.
    public static let maxMessageLength = 1000

    /// The Console reads errors and faults only; other levels are skipped unless asked for.
    public static let errorLevels: Set<LogEntry.Level> = [.error, .fault]

    public static func parse(_ line: String, levels: Set<LogEntry.Level> = errorLevels) -> LogEntry? { parse(Data(line.utf8), levels: levels) }

    public static func parse(_ data: Data, levels: Set<LogEntry.Level> = errorLevels) -> LogEntry? {
        // Cheap pre-check: every event line starts with "{"; this skips the banner without invoking the JSON parser.
        guard data.first == UInt8(ascii: "{"),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (o["eventType"] as? String) == "logEvent",
              let level = (o["messageType"] as? String).flatMap(LogEntry.Level.init(rawValue:)), levels.contains(level),
              let ts = o["timestamp"] as? String, let time = parseTimestamp(ts) else { return nil }
        let pid = (o["processID"] as? NSNumber)?.int32Value ?? -1
        let path = o["processImagePath"] as? String ?? ""
        let name = path.isEmpty ? "pid \(pid)" : (path as NSString).lastPathComponent
        var msg = o["eventMessage"] as? String ?? ""
        if msg.count > maxMessageLength { msg = String(msg.prefix(maxMessageLength)) + "…" }
        return LogEntry(time: time, level: level, process: name, pid: pid, subsystem: o["subsystem"] as? String ?? "",
                        category: o["category"] as? String ?? "", message: msg)
    }

    /// Parses the log's timestamp format, "2026-11-16 13:11:02.856331-0600" (local time with a UTC offset), without a
    /// DateFormatter: a 24 h query yields ~500k lines, and DateFormatter would be the slowest part of parsing them.
    public static func parseTimestamp(_ s: String) -> Date? {
        let b = Array(s.utf8)
        // Fixed-width fields: yyyy-MM-dd HH:mm:ss, then optional .fraction, then ±hhmm.
        guard b.count >= 19 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) { guard i < b.count, b[i] >= 48, b[i] <= 57 else { return nil }; v = v * 10 + Int(b[i] - 48) }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var i = 19, frac = 0.0
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1; var scale = 0.1
            while i < b.count, b[i] >= 48, b[i] <= 57 { frac += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
        }
        var offset = 0   // seconds east of UTC; a missing offset is read as UTC
        if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") {
            guard let oh = num(i + 1, 2), let om = num(i + 3, 2) else { return nil }
            offset = (oh * 3600 + om * 60) * (b[i] == UInt8(ascii: "-") ? -1 : 1)
        }
        let secs = daysFromCivil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + sec - offset
        return Date(timeIntervalSince1970: Double(secs) + frac)
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

/// A distinct message text within a group, with how often it occurred and when it was last seen.
public struct LogSample: Sendable, Hashable {
    public var message: String
    public var level: LogEntry.Level
    public var last: Date
    public var count: Int
}

/// All errors and faults from one process and subsystem.
public struct LogGroup: Sendable, Identifiable, Hashable {
    public var id: String { process + "\u{1}" + subsystem }
    public var process: String
    public var subsystem: String
    public var count = 0
    public var faults = 0
    public var first: Date
    public var last: Date
    /// Counts per time bucket, keyed by absolute bucket index (floor(time / bucketWidth)). Absolute keys let the same
    /// structure serve a fixed window (`log show`) and a growing one (live tail).
    public var buckets: [Int: Int] = [:]
    /// Up to `LogAggregator.samplesPerGroup` distinct messages, the most recently seen kept.
    public var samples: [LogSample] = []

    /// `n` counts spanning [from, to], for a sparkline. Each slot sums the aggregator buckets whose start falls inside it.
    public func sparkline(from: Date, to: Date, bucketWidth: TimeInterval, slots n: Int) -> [Double] {
        guard n > 0, to > from, bucketWidth > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        let span = to.timeIntervalSince(from)
        for (k, c) in buckets {
            let t = Double(k) * bucketWidth - from.timeIntervalSince1970
            guard t >= -bucketWidth, t < span else { continue }
            out[min(max(Int(t / span * Double(n)), 0), n - 1)] += Double(c)
        }
        return out
    }
}

/// Per-process totals for the "noisiest processes" summary.
public struct LogProcessTotal: Sendable, Hashable, Identifiable {
    public var id: String { process }
    public var process: String
    public var count: Int
    public var faults: Int
    /// Share of all entries in the summary, 0...1.
    public var share: Double
    public var subsystems: Int
}

/// An immutable copy of an aggregator's state, safe to hand to the main actor.
public struct LogSummary: Sendable {
    /// Sorted by count, highest first.
    public var groups: [LogGroup]
    /// Newest first, at most the aggregator's `maxEntries`.
    public var entries: [LogEntry]
    public var total: Int
    public var faults: Int
    /// How many entries had part of their message replaced with "<private>".
    public var redacted: Int
    public var earliest: Date?
    public var latest: Date?
    public var bucketWidth: TimeInterval

    public static func empty(bucketWidth: TimeInterval) -> LogSummary {
        LogSummary(groups: [], entries: [], total: 0, faults: 0, redacted: 0, earliest: nil, latest: nil, bucketWidth: bucketWidth)
    }

    /// Groups whose process, subsystem or any kept sample message contains `text` (case-insensitive). Empty text = all.
    public func groups(matching text: String) -> [LogGroup] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return groups }
        return groups.filter { g in
            g.process.localizedCaseInsensitiveContains(q) || g.subsystem.localizedCaseInsensitiveContains(q)
                || g.samples.contains { $0.message.localizedCaseInsensitiveContains(q) }
        }
    }

    /// Kept entries of one group, newest first.
    public func entries(of g: LogGroup) -> [LogEntry] { entries.filter { $0.process == g.process && $0.subsystem == g.subsystem } }

    /// The `n` processes with the most entries (all of their subsystems together).
    public func noisiestProcesses(_ n: Int = 5) -> [LogProcessTotal] {
        var by: [String: LogProcessTotal] = [:]
        for g in groups {
            by[g.process, default: LogProcessTotal(process: g.process, count: 0, faults: 0, share: 0, subsystems: 0)].count += g.count
            by[g.process]!.faults += g.faults; by[g.process]!.subsystems += 1
        }
        let t = Double(max(total, 1))
        return by.values.map { var p = $0; p.share = Double(p.count) / t; return p }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.process < $1.process }.prefix(n).map { $0 }
    }
}

/// Folds entries into groups. Counts and sparklines cover every entry added; only the newest `maxEntries` raw entries
/// are kept (memory cap), so sample lists can be shorter than counts. Not thread-safe: use from one queue at a time.
public final class LogAggregator {
    public static let samplesPerGroup = 8
    public let bucketWidth: TimeInterval
    public let maxEntries: Int
    private var groups: [String: LogGroup] = [:]
    private var kept: [LogEntry] = []
    public private(set) var total = 0, faults = 0, redacted = 0
    public private(set) var earliest: Date?, latest: Date?

    public init(bucketWidth: TimeInterval, maxEntries: Int = 20_000) {
        self.bucketWidth = max(bucketWidth, 1); self.maxEntries = max(maxEntries, 1)
    }

    public func add(_ e: LogEntry) {
        total += 1
        if e.level == .fault { faults += 1 }
        if e.isRedacted { redacted += 1 }
        earliest = min(earliest ?? e.time, e.time); latest = max(latest ?? e.time, e.time)
        let key = e.process + "\u{1}" + e.subsystem
        var g = groups[key] ?? LogGroup(process: e.process, subsystem: e.subsystem, first: e.time, last: e.time)
        g.count += 1
        if e.level == .fault { g.faults += 1 }
        g.first = min(g.first, e.time); g.last = max(g.last, e.time)
        g.buckets[Int((e.time.timeIntervalSince1970 / bucketWidth).rounded(.down)), default: 0] += 1
        if let i = g.samples.firstIndex(where: { $0.message == e.message }) {
            g.samples[i].count += 1
            if e.time > g.samples[i].last { g.samples[i].last = e.time; g.samples[i].level = e.level }
        } else if g.samples.count < Self.samplesPerGroup {
            g.samples.append(LogSample(message: e.message, level: e.level, last: e.time, count: 1))
        } else if let oldest = g.samples.indices.min(by: { g.samples[$0].last < g.samples[$1].last }), g.samples[oldest].last < e.time {
            // Full: a newer distinct message replaces the least recently seen one.
            g.samples[oldest] = LogSample(message: e.message, level: e.level, last: e.time, count: 1)
        }
        groups[key] = g
        kept.append(e)
        // Trimming to the newest entries is amortised: only when twice the cap is reached, so add() stays O(1) on average.
        // Entries may arrive out of order (chunks are read newest-first), hence the sort rather than dropping a prefix.
        if kept.count >= maxEntries * 2 { trim() }
    }

    private func trim() {
        kept.sort { $0.time > $1.time }
        if kept.count > maxEntries { kept.removeLast(kept.count - maxEntries) }
    }

    public func summary() -> LogSummary {
        trim()
        return LogSummary(groups: groups.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id },
                          entries: kept, total: total, faults: faults, redacted: redacted,
                          earliest: earliest, latest: latest, bucketWidth: bucketWidth)
    }
}

/// Runs `/usr/bin/log` and feeds its ndjson output, line by line, to the parser. Single-use: make one reader per query
/// (or live tail). `cancel()` may be called from any thread; it terminates the running `log` process and is final.
public final class LogReader: @unchecked Sendable {
    /// Only errors and faults: the full log is far too large (tens of thousands of lines per minute) and mostly noise.
    public static let predicate = "messageType == error OR messageType == fault"
    /// A single line longer than this (no newline in sight) is dropped, so a malformed stream can't grow the buffer.
    static let maxLineBytes = 1 << 20

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    public enum Outcome: Sendable, Equatable {
        case finished
        case cancelled
        /// Stopped at the entry cap; the summary covers the newest part of the window only.
        case capped
        case failed(String)
    }

    /// Runs `log` with `args`, calling `onEntry` for each parsed entry. `onEntry` returns false to stop early.
    /// Blocks the calling thread until `log` exits, is cancelled, or is stopped.
    @discardableResult
    func run(_ args: [String], levels: Set<LogEntry.Level> = LogParser.errorLevels, onEntry: (LogEntry) -> Bool) -> Outcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log"); p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        lock.lock()
        if cancelled { lock.unlock(); return .cancelled }
        process = p
        lock.unlock()
        defer { lock.lock(); process = nil; lock.unlock() }
        do { try p.run() } catch { return .failed("couldn't run /usr/bin/log: \(error.localizedDescription)") }
        // stderr is drained concurrently so a chatty `log` can't block on a full pipe while we read stdout.
        let errData = LockedData()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { errData.set(err.fileHandleForReading.readDataToEndOfFile()); errDone.signal() }
        var buffer = Data()
        var stopped = false
        let h = out.fileHandleForReading
        while true {
            let chunk = h.availableData   // blocks until data arrives; empty means EOF (also after terminate)
            if chunk.isEmpty { break }
            if stopped { continue }       // keep draining until exit so `log` isn't left blocked on a write
            buffer.append(chunk)
            var start = buffer.startIndex
            while let nl = buffer[start...].firstIndex(of: 0x0A) {
                if let e = LogParser.parse(Data(buffer[start..<nl]), levels: levels), !onEntry(e) { stopped = true; p.terminate(); break }
                start = buffer.index(after: nl)
            }
            buffer.removeSubrange(buffer.startIndex..<start)
            if buffer.count > Self.maxLineBytes { buffer.removeAll() }
        }
        p.waitUntilExit(); errDone.wait()
        if isCancelled { return .cancelled }
        if stopped { return .capped }
        if p.terminationStatus != 0 {
            let msg = String(decoding: errData.get().prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(msg.isEmpty ? "log exited with status \(p.terminationStatus)" : msg)
        }
        return .finished
    }

    /// Reads errors and faults from the last `window` seconds into `agg`. Long windows are split into chunks read
    /// newest-first, so progress can be reported and, if `maxTotal` entries are reached, what was read is the most
    /// recent part. `progress` is called after each chunk with the fraction done.
    public func show(window: TimeInterval, now: Date = Date(), into agg: LogAggregator, maxTotal: Int = 1_000_000,
                     progress: (Double) -> Void) -> Outcome {
        let chunk: TimeInterval = window <= 300 ? window : window <= 3600 ? 900 : 3600
        let n = max(1, Int((window / chunk).rounded(.up)))
        let end0 = now.timeIntervalSince1970.rounded(.up)
        for k in 0..<n {
            let end = end0 - Double(k) * chunk, start = max(end - chunk, end0 - window)
            // `--start/--end` take "@unixtime". Both ends are inclusive, so entries on a boundary are kept only in
            // the chunk where they fall in [start, end).
            let r = run(["show", "--style", "ndjson", "--no-backtrace", "--start", "@\(Int(start))", "--end", "@\(Int(end))",
                         "--predicate", Self.predicate]) { e in
                let t = e.time.timeIntervalSince1970
                if t >= start && t < end { agg.add(e) }
                return agg.total < maxTotal
            }
            progress(Double(k + 1) / Double(n))
            if r != .finished { return r }
        }
        return .finished
    }

    /// Follows the log live (`log stream`), calling `onEntry` for each entry until `cancel()`. Blocks.
    public func stream(onEntry: (LogEntry) -> Void) -> Outcome {
        run(["stream", "--style", "ndjson", "--no-backtrace", "--predicate", Self.predicate]) { onEntry($0); return true }
    }
}

/// Data shared between the stderr reader and `run`.
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock(); private var d = Data()
    func set(_ x: Data) { lock.lock(); d = x; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return d }
}
