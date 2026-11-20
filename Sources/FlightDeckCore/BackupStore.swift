import Foundation

// Backups, part 5: what FlightDeck learned about Time Machine, saved in
// ~/Library/Application Support/Flightdeck/Backups/backups.json. The unified log keeps backupd's run messages a day
// or two and Time Machine thins its own list of backups (daily ones become weekly after a month), so the run events,
// every completed-backup date seen and the destinations' free space are kept here for 90 days.

public final class BackupStore: @unchecked Sendable {
    public static let retention: TimeInterval = 90 * 86_400
    /// A free-space point is saved when it changes, at most this often.
    static let spaceInterval: TimeInterval = 3 * 3600

    struct File: Codable {
        var events: [BackupLogEvent] = []
        /// Destination ID → completed backup dates seen in the plist.
        var successes: [String: [Date]] = [:]
        var space: [String: [BackupSpacePoint]] = [:]
        /// When the unified log was last read up to.
        var logScannedTo: Date?
        /// The first log scan: failures before it are unknown.
        var watchingSince: Date?
    }

    /// nil = in memory only (tests, demo, renders).
    public let url: URL?
    /// Loads the file but never writes it (MCP tool, off-screen renders).
    public let readOnly: Bool
    private let lock = NSLock()
    private var file = File()

    public static var defaultDirectory: URL { DailyLog.defaultDirectory.appendingPathComponent("Backups") }

    public init(dir: URL?, readOnly: Bool = false) {
        url = dir?.appendingPathComponent("backups.json"); self.readOnly = readOnly
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        if let url, let d = try? Data(contentsOf: url), let f = try? dec.decode(File.self, from: d) { file = f }
    }

    private func locked<T>(_ f: (inout File) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(&file) }

    public var events: [BackupLogEvent] { locked { $0.events } }
    public var logScannedTo: Date? { locked { $0.logScannedTo } }
    public var watchingSince: Date? { locked { $0.watchingSince } }
    public func successes(_ id: String) -> [Date] { locked { $0.successes[id] ?? [] } }
    public var allSuccesses: [Date] { locked { $0.successes.values.flatMap { $0 } } }
    public func space(_ id: String) -> [BackupSpacePoint] { locked { $0.space[id] ?? [] } }

    /// Adds log events read up to `scannedTo`, skipping ones already saved (scans overlap by a few minutes).
    public func add(events new: [BackupLogEvent], scannedTo: Date) {
        locked { f in
            var seen = Set(f.events.map { "\($0.kind.rawValue)|\(Int($0.time.timeIntervalSince1970 * 10))" })
            for e in new where seen.insert("\(e.kind.rawValue)|\(Int(e.time.timeIntervalSince1970 * 10))").inserted { f.events.append(e) }
            f.events.sort { $0.time < $1.time }
            f.logScannedTo = max(f.logScannedTo ?? scannedTo, scannedTo)
            if f.watchingSince == nil { f.watchingSince = new.first?.time.addingTimeInterval(-60) ?? scannedTo }
        }
    }

    /// Merges what the plist says now: its completed backup dates and the destinations' space.
    public func note(prefs: TimeMachinePrefs, at now: Date) {
        locked { f in
            for d in prefs.destinations {
                f.successes[d.id] = Array(Set((f.successes[d.id] ?? []) + d.snapshots)).sorted()
                guard let avail = d.bytesAvailable else { continue }
                var pts = f.space[d.id] ?? []
                if let last = pts.last, last.available == avail || now.timeIntervalSince(last.time) < Self.spaceInterval {
                    if last.available != avail { pts[pts.count - 1] = BackupSpacePoint(time: now, available: avail, used: d.bytesUsed) }
                } else {
                    pts.append(BackupSpacePoint(time: now, available: avail, used: d.bytesUsed))
                }
                f.space[d.id] = pts
            }
        }
    }

    /// Drops what's older than 90 days, then writes the file atomically.
    public func save(now: Date = Date()) {
        let f: File = locked { f in
            let cut = now.addingTimeInterval(-Self.retention)
            f.events.removeAll { $0.time < cut }
            for k in f.successes.keys { f.successes[k]?.removeAll { $0 < cut } }
            for k in f.space.keys { f.space[k]?.removeAll { $0.time < cut } }
            return f
        }
        guard let url, !readOnly else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(f) { try? d.write(to: url, options: .atomic) }
    }
}
