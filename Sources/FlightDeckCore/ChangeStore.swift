import Foundation

// What Changed's saved state, in ~/Library/Application Support/Flightdeck/Changes/: inventory.json (the latest
// inventory, what the next check compares against) and changes.json (every change found, kept 90 days, plus when the
// baseline was taken and the last check). Also the check itself (read, compare, save) and the findings for notable
// changes, which reach the banner through ChangeWatch.

public final class ChangeStore: @unchecked Sendable {
    public static let retention: TimeInterval = 90 * 86_400
    struct Log: Codable { var baseline: Date?; var lastCheck: Date?; var events: [ChangeEvent] = [] }

    /// nil = in memory only (tests, demo, headless renders).
    public let dir: URL?
    /// Loads the files but never writes them (MCP tools, off-screen renders).
    public let readOnly: Bool
    private let lock = NSLock()
    /// Held for a whole check, so the timer and the page never run two at once.
    private let checking = NSLock()
    private var log = Log()
    private var inventory: Inventory?

    public static var defaultDirectory: URL { DailyLog.defaultDirectory.appendingPathComponent("Changes", isDirectory: true) }

    public init(dir: URL?, readOnly: Bool = false) {
        self.dir = dir; self.readOnly = readOnly
        guard let dir else { return }
        let dec = Self.decoder
        if let d = try? Data(contentsOf: dir.appendingPathComponent("changes.json")), let l = try? dec.decode(Log.self, from: d) { log = l }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("inventory.json")), let i = try? dec.decode(Inventory.self, from: d) { inventory = i }
    }

    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }

    public var latest: Inventory? { lock.lock(); defer { lock.unlock() }; return inventory }
    public var report: ChangesReport {
        lock.lock(); defer { lock.unlock() }
        return ChangesReport(events: log.events.sorted { $0.when > $1.when }, baseline: log.baseline, lastCheck: log.lastCheck, inventory: inventory)
    }

    /// Records `new` as the latest inventory and returns the changes since the previous one (none for the baseline).
    @discardableResult
    public func ingest(_ fresh: Inventory) -> [ChangeEvent] {
        lock.lock()
        let old = inventory
        let new = ChangeDiff.carryOver(old: old, new: fresh)
        let events = old.map { ChangeDiff.diff(old: $0, new: new) } ?? []
        inventory = new
        if log.baseline == nil { log.baseline = new.time }
        log.lastCheck = new.time
        log.events += events
        log.events.removeAll { new.time.timeIntervalSince($0.detected) > Self.retention }
        lock.unlock()
        return events
    }

    /// Reads this Mac, compares and saves. Returns nil if a check is already running. Blocking; call off the main thread.
    public func check(now: Date = Date(), helper: HelperSession? = nil) -> [ChangeEvent]? {
        guard checking.try() else { return nil }
        defer { checking.unlock() }
        let events = ingest(ChangeReaders.read(previous: latest, now: now, helper: helper))
        save()
        return events
    }

    public func save() {
        lock.lock(); let l = log, inv = inventory; lock.unlock()
        guard let dir, !readOnly else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(l) { try? d.write(to: dir.appendingPathComponent("changes.json"), options: .atomic) }
        if let inv, let d = try? enc.encode(inv) { try? d.write(to: dir.appendingPathComponent("inventory.json"), options: .atomic) }
    }
}

/// Findings for notable changes. One per change; more than three found in one check become a single finding so an
/// installer that drops several helpers at once doesn't fill the banner.
public enum ChangeFindings {
    public static let destination = "What Changed"
    public static let linger: TimeInterval = 12 * 3600

    public static func findings(_ events: [ChangeEvent]) -> [Finding] {
        let notable = events.filter(\.notable).sorted { $0.when > $1.when }
        guard !notable.isEmpty else { return [] }
        if notable.count > 3 {
            let names = notable.prefix(3).map(\.item.name).joined(separator: ", ")
            return [Finding(id: "change:batch:\(Int(notable[0].detected.timeIntervalSince1970))", severity: .caution, icon: "exclamationmark.shield",
                            title: "\(notable.count) notable changes to this Mac", detail: "Including \(names). Review them in What Changed.",
                            since: notable[0].detected, destination: destination)]
        }
        return notable.map { e in
            let weak = e.item.signature?.isWeak == true || e.reasons.contains { $0.hasPrefix("runs from a temporary") }
            return Finding(id: "change:\(e.id)", severity: weak ? .warning : .caution, icon: weak ? "exclamationmark.shield.fill" : "exclamationmark.shield",
                           title: e.summary, detail: e.reasons.joined(separator: "; ").capitalizedFirst, since: e.detected, destination: destination)
        }
    }

    /// The same, for the web dashboard, which may show nothing the helper read: changes to Mac-wide profiles and Login
    /// Items background records are left out (a user-readable computer-level profile has the same scope and is left
    /// out too).
    public static func dashboardFindings(_ events: [ChangeEvent]) -> [Finding] {
        findings(events.filter { e in
            !([e.item] + [e.previous].compactMap { $0 }).contains { ChangeReaders.isHelperProfile($0) || ChangeReaders.isBackgroundItem($0) }
        })
    }
}

/// Holds the session's change findings for the sampling loop (thread-safe); each drops out `linger` after it was raised.
/// The web dashboard's own set (`ChangeFindings.dashboardFindings`) is kept beside them.
public final class ChangeWatch: @unchecked Sendable {
    public static let shared = ChangeWatch()
    private let lock = NSLock()
    private var current: [(Finding, Date)] = [], dashboard: [(Finding, Date)] = []
    public func add(_ f: [Finding], dashboard d: [Finding], at now: Date = Date()) {
        lock.lock(); current += f.map { ($0, now) }; dashboard += d.map { ($0, now) }; lock.unlock()
    }
    public func findings(now: Date = Date()) -> [Finding] {
        lock.lock(); defer { lock.unlock() }
        current.removeAll { now.timeIntervalSince($0.1) > ChangeFindings.linger }
        return current.map(\.0)
    }
    public func dashboardFindings(now: Date = Date()) -> [Finding] {
        lock.lock(); defer { lock.unlock() }
        dashboard.removeAll { now.timeIntervalSince($0.1) > ChangeFindings.linger }
        return dashboard.map(\.0)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
