import Foundation
// The Camera & Mic history: every session for the last 90 days plus the set of apps ever seen using each kind of
// device (for "first use"), as one small JSON file, ~/Library/Application Support/Flightdeck/camera-mic.json. It stays
// on this Mac: nothing here is sent anywhere, and it holds no audio or video, only device, app and times.
//
// Size: a busy day of calls is a few dozen sessions (~300 bytes each), so 90 days is well under a megabyte and a
// whole-file rewrite is cheaper than a database. Writes are coalesced (at most one a second) on a background queue
// and atomic, so a crash leaves the previous version.
//
// Threading: internally locked. CameraMicWatch writes from its queue; views and the MCP tool read from anywhere.

public final class CameraMicStore: @unchecked Sendable {
    public static let retentionDays = 90
    public static let fileName = "camera-mic.json"

    struct File: Codable {
        var version = 1
        var sessions: [SensorSession]
        /// "kind|appKey" → when that app was first seen using that kind of device.
        var known: [String: Date]
    }

    /// nil = in memory only (demo mode, tests): nothing is read or written.
    public let url: URL?
    /// Reads the file but never writes it (the standalone MCP server reading the app's history).
    private let readOnly: Bool
    private let lock = NSLock()
    private let io = DispatchQueue(label: "flightdeck.cameramic.store", qos: .utility)
    // Guarded by `lock`.
    private var sessions: [SensorSession] = []   // oldest first
    private var known: [String: Date] = [:]
    private var savePending = false
    /// Bumped on every change, so views can tell whether to re-read.
    public private(set) var revision = 0

    public init(dir: URL?, now: Date = Date(), readOnly: Bool = false) {
        url = dir?.appendingPathComponent(Self.fileName); self.readOnly = readOnly
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        guard let f = try? dec.decode(File.self, from: data) else { return }   // unreadable: start over rather than guess
        known = f.known
        // A session still open in the file was cut short by a crash or power loss: it ran at least until it was last
        // confirmed, and how much longer is unknown.
        sessions = f.sessions.map { s in
            guard s.end == nil else { return s }
            var s = s; s.end = s.lastSeen; s.endObserved = false; return s
        }.sorted { $0.start < $1.start }
        // Expired sessions are dropped in memory only; loading never writes (the next change saves the pruned list).
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        sessions.removeAll { ($0.end ?? .distantFuture) < cutoff }
    }

    /// In-memory store holding the given sessions (demo mode, previews, tests).
    public init(preview: [SensorSession], known: [String: Date] = [:]) {
        url = nil; readOnly = true; sessions = preview.sorted { $0.start < $1.start }; self.known = known
    }

    /// Sessions that overlap [since, now], oldest first (all of them for nil).
    public func sessions(since: Date? = nil) -> [SensorSession] {
        lock.lock(); defer { lock.unlock() }
        guard let since else { return sessions }
        return sessions.filter { ($0.end ?? .distantFuture) >= since }
    }

    public var knownKeys: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(known.keys) }
    /// When each app was first seen using each kind of device ("kind|appKey").
    public var firstSeen: [String: Date] { lock.lock(); defer { lock.unlock() }; return known }

    /// Inserts or replaces sessions by id, and remembers newly seen apps.
    public func upsert(_ changed: [SensorSession], known keys: Set<String>, now: Date = Date()) {
        guard !changed.isEmpty || !keys.isSubset(of: Set(knownKeys)) else { return }
        lock.lock()
        for s in changed {
            if let i = sessions.lastIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        }
        sessions.sort { $0.start < $1.start }
        for k in keys where known[k] == nil { known[k] = now }
        revision += 1
        lock.unlock()
        scheduleSave()
    }

    /// Drops sessions that ended more than `retentionDays` ago. The known-apps list is kept (it holds only bundle IDs
    /// and a date) so an app last seen 100 days ago isn't announced as new; Clear History removes it too.
    public func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        lock.lock()
        let before = sessions.count
        sessions.removeAll { ($0.end ?? .distantFuture) < cutoff }
        let changed = sessions.count != before
        if changed { revision += 1 }
        lock.unlock()
        if changed { scheduleSave() }
    }

    /// Deletes every session and the known-apps list (Clear History). Every app is "new" again afterwards.
    public func clear() {
        lock.lock(); sessions = []; known = [:]; revision += 1; lock.unlock()
        scheduleSave()
    }

    /// Writes now (at quit), waiting for any queued write first.
    public func flush() {
        io.sync {}
        lock.lock(); let data = encodeLocked(); savePending = false; lock.unlock()
        write(data)
    }

    private func scheduleSave() {
        guard url != nil, !readOnly else { return }
        lock.lock(); defer { lock.unlock() }
        guard !savePending else { return }
        savePending = true
        io.asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock(); let data = encodeLocked(); savePending = false; lock.unlock()
            write(data)
        }
    }

    /// Caller holds `lock`.
    private func encodeLocked() -> Data? {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        return try? enc.encode(File(sessions: sessions, known: known))
    }

    private func write(_ data: Data?) {
        guard let url, !readOnly, let data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
