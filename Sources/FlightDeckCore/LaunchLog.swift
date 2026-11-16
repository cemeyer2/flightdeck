import Foundation

// Process launch/exit log behind the "Launches" destination and the respawn-loop finding. The Engine already gets the
// full process list every sample; LaunchLog diffs consecutive lists by identity (PID + start time) to see what started
// and what went away. It only knows what sampling saw: a process that starts and exits between two samples (under one
// sample interval, usually 1 s) is never seen, so counts are lower bounds and short-lived tools are under-reported.

/// One launch or exit seen between two samples.
public struct LaunchEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case launch = "Launched", exit = "Exited" }
    /// Unique per event: the same identity has at most one launch and one exit.
    public var id: String { "\(kind == .launch ? "L" : "X")\(identity.pid)-\(identity.startTime)" }
    public var kind: Kind
    public var identity: ProcessIdentity
    public var name: String
    /// Executable path; "" when the kernel didn't reveal it (other users' processes).
    public var path: String
    public var ppid: Int32
    /// Parent's name if the parent was in the same sample, else nil (unknown, not "none").
    public var parentName: String?
    public var user: String
    public var uid: UInt32
    /// Launch: when the process started (from the kernel, exact). Exit: when the exit was noticed (the first sample
    /// without it), so the real exit happened between `lastSeen` and `time`.
    public var time: Date
    /// Exit only: the last sample that still listed the process.
    public var lastSeen: Date?
    /// Exit only: start to `time`, so at most one sample interval longer than the real lifetime.
    public var lifetime: TimeInterval?
    /// Grouping key for "the same program": the executable path, or the name when the path is hidden.
    public var executable: String { path.isEmpty ? "name:\(name)" : path }
    public var startDate: Date { Date(timeIntervalSince1970: Double(identity.startTime) / 1e6) }
}

/// Launches of one executable within a time window ("launched N times in the last 10 min").
public struct LaunchGroup: Sendable, Hashable, Identifiable {
    public var id: String { executable }
    public var executable: String
    public var name: String
    public var path: String
    public var launches: Int
    public var exits: Int
    public var lastLaunch: Date?
    /// PIDs of the launches, newest first (capped at 20 for display).
    public var pids: [Int32]
    /// Users that ran it in the window (normally one).
    public var users: [String]
}

/// Ring buffer of the last `capacity` launch/exit events, fed with every sample's process list.
/// Thread-safe (internally locked): `ingest` runs on the Engine's sampling queue, views read `events` / `groups`.
public final class LaunchLog: @unchecked Sendable {
    public let capacity: Int
    /// Respawn finding: more than `respawnLimit` launches of one executable within `respawnWindow` seconds.
    public var respawnLimit = 20
    public var respawnWindow: TimeInterval = 300
    /// Confirms a process that vanished from a sample really exited. Missing from one list isn't proof (a query can
    /// fail transiently), so before an exit is recorded the PID's current identity is re-read; only a different start
    /// time or no process counts. Injectable for tests.
    var isAlive: (ProcessIdentity) -> Bool = { ProcessSampler.identity(of: $0.pid) == $0 }

    private let lock = NSLock()
    /// Events oldest first. Trimmed in batches (see `append`) so the buffer is amortised O(1) per event.
    private var buffer: [LaunchEvent] = []
    /// The previous sample's processes and an index into them by identity. Keeping the array costs nothing extra: it is
    /// the snapshot's own (copy-on-write) array.
    private var prev: [ProcessSample] = []
    private var prevIndex: [ProcessIdentity: Int] = [:]
    private var prevTime: Date?
    /// Executables currently over the respawn limit, with when the condition began (the finding's stable `since`).
    private var respawning: [String: Date] = [:]
    /// Bumped whenever events are added, so readers can cache derived lists.
    public private(set) var revision = 0

    public init(capacity: Int = 2000) { self.capacity = capacity }

    /// Diffs `procs` against the previous sample. O(n) in the number of processes: one dictionary build plus two
    /// passes of set membership on ProcessIdentity. The first call only establishes the baseline (everything already
    /// running is not a launch). Processes with an unknown start time (0) are ignored: their identity isn't stable.
    /// A newly seen identity counts as a launch only if it started after the previous sample (minus 1 s of slack for
    /// timestamp rounding); one that started earlier was merely unreadable before and is tracked silently.
    public func ingest(_ procs: [ProcessSample], at now: Date) {
        lock.lock(); defer { lock.unlock() }
        var index: [ProcessIdentity: Int] = [:]
        index.reserveCapacity(procs.count)
        for (i, p) in procs.enumerated() { index[p.identity] = i }
        guard let since = prevTime else { prev = procs; prevIndex = index; prevTime = now; return }

        var fresh: [LaunchEvent] = []
        var current = procs
        // Exits: in the previous list, not in this one, and confirmed gone.
        for p in prev where index[p.identity] == nil && p.identity.startTime > 0 {
            if isAlive(p.identity) {
                // Still running, just missing from this sample: carry it forward so it is checked again next time.
                index[p.identity] = current.count; current.append(p)
                continue
            }
            fresh.append(LaunchEvent(kind: .exit, identity: p.identity, name: p.name, path: p.path, ppid: p.ppid, parentName: nil,
                                     user: p.user, uid: p.uid, time: now, lastSeen: since, lifetime: max(now.timeIntervalSince(p.startDate), 0)))
        }
        // Launches: new identities that started since the previous sample. The pid → name map for parents is only
        // built when there is at least one launch.
        var names: [Int32: String]?
        let cutoff = since.addingTimeInterval(-1)
        for p in procs where prevIndex[p.identity] == nil && p.identity.startTime > 0 && p.startDate >= cutoff {
            if names == nil { names = Dictionary(procs.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a }) }
            fresh.append(LaunchEvent(kind: .launch, identity: p.identity, name: p.name, path: p.path, ppid: p.ppid,
                                     parentName: names?[p.ppid], user: p.user, uid: p.uid, time: p.startDate, lastSeen: nil, lifetime: nil))
        }
        prev = current; prevIndex = index; prevTime = now
        if !fresh.isEmpty {
            // Launch times are the processes' real start times, so keep the buffer ordered by time.
            fresh.sort { $0.time < $1.time }
            buffer += fresh
            if buffer.count > capacity + capacity / 10 { buffer.removeFirst(buffer.count - capacity) }
            revision += 1
        }
    }

    /// All buffered events, newest first.
    public var events: [LaunchEvent] { lock.lock(); defer { lock.unlock() }; return buffer.reversed() }

    /// Launches and exits per executable in the last `window` seconds, most launches first. Cost is proportional to the
    /// events in the window, found by walking back from the newest.
    public func groups(window: TimeInterval = 600, now: Date = Date()) -> [LaunchGroup] {
        lock.lock(); defer { lock.unlock() }
        return Self.groups(recent(window, now: now))
    }

    /// Events newer than `now - window`, newest first. Caller holds the lock.
    private func recent(_ window: TimeInterval, now: Date) -> ArraySlice<LaunchEvent> {
        let from = now.addingTimeInterval(-window)
        var i = buffer.endIndex
        while i > buffer.startIndex && buffer[i - 1].time >= from { i -= 1 }
        return buffer[i...]
    }

    /// Groups events by executable. Pure, for tests and for the view's filtered lists.
    public static func groups<S: Sequence>(_ events: S) -> [LaunchGroup] where S.Element == LaunchEvent {
        var out: [String: LaunchGroup] = [:]
        for e in events {
            var g = out[e.executable] ?? LaunchGroup(executable: e.executable, name: e.name, path: e.path, launches: 0, exits: 0,
                                                     lastLaunch: nil, pids: [], users: [])
            if e.kind == .launch {
                g.launches += 1
                if g.lastLaunch.map({ e.time > $0 }) ?? true { g.lastLaunch = e.time }
                g.pids.append(e.identity.pid)
            } else { g.exits += 1 }
            if !g.users.contains(e.user) { g.users.append(e.user) }
            out[e.executable] = g
        }
        return out.values.map { var g = $0; g.pids = Array(g.pids.sorted(by: >).prefix(20)); return g }
            .sorted { ($0.launches, $0.exits, $1.name) > ($1.launches, $1.exits, $0.name) }
    }

    /// Respawn-loop findings: an executable launched more than `respawnLimit` times in the last `respawnWindow`
    /// seconds. Called once per sample by the Engine (cost: the events in the window). `since` stays fixed while the
    /// condition holds, so the incident log sees one continuous incident.
    public func findings(now: Date) -> [Finding] {
        lock.lock(); defer { lock.unlock() }
        let hot = Self.groups(recent(respawnWindow, now: now)).filter { $0.launches > respawnLimit }
        var still: [String: Date] = [:]
        let out = hot.map { g -> Finding in
            let since = respawning[g.executable] ?? now
            still[g.executable] = since
            let minutes = Int((respawnWindow / 60).rounded())
            return Finding(id: "respawn:\(g.executable)", severity: .caution, icon: "arrow.triangle.2.circlepath",
                           title: "\(g.name) launched \(g.launches) times in \(minutes) minutes",
                           detail: "Something keeps starting it again, often a crash loop or a launch agent that exits right away. "
                                + "Counts only launches that sampling saw, so the real number may be higher (Launches).",
                           since: since, destination: "Launches", pids: g.pids.first.map { [$0] })
        }
        respawning = still
        return out
    }
}
