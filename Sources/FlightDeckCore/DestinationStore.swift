import Foundation
// Destinations, part 6: on disk. ~/Library/Application Support/Flightdeck/Destinations/ holds one JSON file per day
// ("2026-11-19.json", a `DestinationDay`) and `known.json` (which destinations each app contacted in the last 30
// days, for "new destination"). Files older than `retentionDays` are deleted at launch and when a day closes.
//
// One file per day keeps writes small: the open day is rewritten every few minutes (a few hundred rows, tens of KB),
// and a closed day is never rewritten. Reads of a range load each day's file once and keep closed days cached,
// since they can't change. Nothing here leaves the Mac.
//
// Threading: internally locked; writes go to a background queue (or are synchronous at quit).

public final class DestinationStore: @unchecked Sendable {
    public static let retentionDays = 30
    public static var defaultDirectory: URL { DailyLog.defaultDirectory.appendingPathComponent("Destinations") }

    public let dir: URL?
    /// Read-only stores (the standalone MCP server, UIBench) never write or delete.
    public let readOnly: Bool
    private let calendar: Calendar
    private let io = DispatchQueue(label: "flightdeck.destinations.io", qos: .utility)
    private let lock = NSLock()
    /// Closed days already read, by file name. Guarded by `lock`.
    private var cache: [String: DestinationDay] = [:]
    /// In-memory days (dir == nil: tests, demo, previews).
    private var memory: [String: DestinationDay] = [:]
    private var memoryKnown = KnownDestinations()

    /// `dir` nil keeps days in memory only.
    public init(dir: URL?, readOnly: Bool = false, calendar: Calendar = .current) {
        self.dir = dir; self.readOnly = readOnly; self.calendar = calendar
        if let dir, !readOnly { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    /// An in-memory store holding `days` (demo mode, previews).
    public convenience init(preview days: [DestinationDay], known: KnownDestinations, calendar: Calendar = .current) {
        self.init(dir: nil, readOnly: false, calendar: calendar)
        for d in days { memory[name(d.start)] = d }
        memoryKnown = known
    }

    /// "2026-11-19": the local calendar day, independent of the user's date format.
    func name(_ dayStart: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: dayStart)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private func url(_ name: String) -> URL? { dir?.appendingPathComponent(name + ".json") }
    private var knownURL: URL? { dir?.appendingPathComponent("known.json") }

    // MARK: Reading

    /// The saved day starting at `start`, or nil if none was recorded.
    public func load(day start: Date) -> DestinationDay? {
        let n = name(start)
        lock.lock(); defer { lock.unlock() }
        if dir == nil { return memory[n] }
        if let c = cache[n] { return c }
        guard let u = url(n), let data = try? Data(contentsOf: u), let d = try? JSONDecoder().decode(DestinationDay.self, from: data) else { return nil }
        if calendar.date(byAdding: .day, value: 1, to: start)! <= Date() { cache[n] = d }   // closed days can't change
        return d
    }

    /// Saved days from the one containing `from` through the one containing `to`, oldest first (missing days left out).
    public func days(from: Date, to: Date) -> [DestinationDay] {
        var out: [DestinationDay] = []
        var d = calendar.startOfDay(for: from)
        while d <= to {
            if let x = load(day: d) { out.append(x) }
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }

    public func loadKnown() -> KnownDestinations? {
        lock.lock(); defer { lock.unlock() }
        if dir == nil { return memoryKnown }
        guard let u = knownURL, let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(KnownDestinations.self, from: data)
    }

    // MARK: Writing

    /// Writes a day and the known list (on the background queue unless `sync`). The cached copy is replaced.
    public func save(_ day: DestinationDay, known: KnownDestinations, sync: Bool = false) {
        guard !readOnly else { return }
        let n = name(day.start)
        lock.lock()
        if dir == nil { memory[n] = day; memoryKnown = known; lock.unlock(); return }
        cache[n] = nil
        lock.unlock()
        let write = { [self] in
            let enc = JSONEncoder()
            if let u = url(n), let data = try? enc.encode(day) { try? data.write(to: u, options: .atomic) }
            if let u = knownURL, let data = try? enc.encode(known) { try? data.write(to: u, options: .atomic) }
        }
        if sync { io.sync(execute: write) } else { io.async(execute: write) }
    }

    /// Deletes day files older than the retention period (today and the 29 days before it are kept).
    public func prune(now: Date = Date()) {
        guard !readOnly, let dir else { return }
        let cutoff = name(calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: calendar.startOfDay(for: now))!)
        io.async { [self] in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            // Day files sort by name in date order, so a string comparison finds the old ones.
            for f in files where f.hasSuffix(".json") && f != "known.json" && String(f.dropLast(5)) < cutoff {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
            lock.lock(); cache = cache.filter { $0.key >= cutoff }; lock.unlock()
        }
    }

    /// Deletes every saved day and the known list.
    public func clear() {
        lock.lock(); cache = [:]; memory = [:]; memoryKnown = KnownDestinations(); lock.unlock()
        guard !readOnly, let dir else { return }
        io.sync { try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    /// Waits for queued writes (tests).
    func waitForWrites() { io.sync {} }
}
