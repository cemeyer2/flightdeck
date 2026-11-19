import Foundation
// Destinations, part 5: the accumulator. Sampler hands it the per-flow deltas from each nettop run it already makes
// (on its nettop queue, after `ProcessNetworkSampler.sample()`), together with the latest process list, and it folds
// them into today's rows: per app and remote IP, bytes in and out, connections, first and last seen, ports.
//
// Cost: O(active flows) per nettop run. Idle flows aren't even passed in; each active one costs one parse of its flow
// text and one dictionary update. PIDs map to apps through a cache, rebuilt from the process list (O(processes)) only
// when a flow's PID is missing from it. Memory is bounded: at most `maxPerApp` IPs per app per day (the rest fold into
// that app's "other destinations" row), and closed days live on disk, not here.
//
// What's missed (inherited from nettop snapshots): bytes a connection moves after the last snapshot before it closes,
// and connections that open and close entirely between two snapshots (one second apart while a window is open, five
// while none is). Unconnected UDP sockets (e.g. mDNSResponder's DNS traffic) have no remote address and aren't attributed.
//
// Threading: internally locked. `ingest` runs on the Sampler's nettop queue, names arrive on the namer's queue, and
// views and the MCP server read `today()`/`known()` from anywhere.

public final class DestinationTracker: @unchecked Sendable {
    public struct Config: Sendable {
        /// Most remote IPs kept per app per day before the rest fold into one "other destinations" row.
        public var maxPerApp = 300
        /// Seconds between writes of the open day.
        public var flushInterval: TimeInterval = 300
        public init() {}
    }

    /// One first contact between an established app and a destination it hadn't contacted in 30 days.
    public struct NewContact: Sendable, Hashable {
        public var app: String, appName: String
        public var dest: String
        public var scope: AddressScope
        public var at: Date
    }

    public let config: Config
    public let store: DestinationStore?
    public let namer: HostNamer?
    private let calendar: Calendar
    private let lock = NSLock()
    // All below guarded by `lock`.
    private var day: DestinationDay
    private var dayEnds: Date
    /// Today's rows by (app, ip), and how many each app has (for the cap).
    private var rows: [RowKey: DestinationRow] = [:]
    private var perApp: [String: Int] = [:]
    /// IP → rows waiting for a name.
    private var awaiting: [String: Set<RowKey>] = [:]
    private var knownDests: KnownDestinations
    private var contacts: [NewContact] = []
    private var pidApps: [Int32: (key: String, name: String)] = [:]
    private var lastFlush: Date?
    private var lookups = true
    /// Bumped on every change views care about, so they can skip re-reading.
    public private(set) var revision = 0
    /// Whether new rows may be named by reverse DNS (Settings). Off: rows stay "not looked up" and group by IP.
    public var lookupsEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return lookups }
        set { lock.lock(); lookups = newValue; lock.unlock() }
    }

    struct RowKey: Hashable { var app: String; var ip: String }

    /// `store` nil keeps everything in memory (tests, headless renders); `namer` nil means no lookups.
    public init(store: DestinationStore?, namer: HostNamer?, config: Config = Config(), calendar: Calendar = .current, now: Date = Date()) {
        self.store = store; self.namer = namer; self.config = config; self.calendar = calendar
        let start = calendar.startOfDay(for: now)
        dayEnds = calendar.date(byAdding: .day, value: 1, to: start)!
        day = store?.load(day: start) ?? DestinationDay(start: start)
        knownDests = store?.loadKnown() ?? KnownDestinations()
        for r in day.rows { rows[RowKey(app: r.app, ip: r.ip)] = r; perApp[r.app, default: 0] += 1 }
        knownDests.prune(before: now.addingTimeInterval(-Double(DestinationStore.retentionDays) * 86_400))
        namer?.onName = { [weak self] ip, name in self?.named(ip, name) }
    }

    // MARK: Ingest

    /// Folds one nettop run in. `procs` is the latest process list (for PID → app).
    public func ingest(_ flows: [ProcessNetworkSampler.FlowDelta], procs: [ProcessSample], now: Date) {
        guard !flows.isEmpty else { return }
        lock.lock()
        if now >= dayEnds || now < day.start { rollOver(to: now) }
        var ask: [String] = []
        var changed = false, rebuilt = false
        for f in flows {
            guard let ep = FlowEndpoint.parse(f.flow), let scope = AddressScope.of(ep.ip) else { continue }
            let app = appFor(f.pid, procs, &rebuilt)
            var key = RowKey(app: app.key, ip: ep.ip)
            if rows[key] == nil && perApp[app.key, default: 0] >= config.maxPerApp {
                key.ip = DestinationRow.otherIP; day.overflowed += 1
            }
            var r = rows[key] ?? newRow(key, app.name, scope, now, &ask, lookups: lookups)
            r.bytesIn += f.bytesIn; r.bytesOut += f.bytesOut
            if f.opened { r.connections += 1 }
            r.last = max(r.last, now)
            if let sp = ep.servicePort { r.addPort(sp.port, inbound: sp.inbound, proto: ep.proto) }
            rows[key] = r
            changed = true
        }
        if changed {
            day.firstCounted = day.firstCounted ?? now; day.lastCounted = now; revision += 1
        }
        let flush = store != nil && (lastFlush.map { now.timeIntervalSince($0) >= config.flushInterval } ?? true)
        if flush { lastFlush = now }
        let snapshot = flush ? currentDayLocked() : nil
        let known = flush ? knownDests : nil
        lock.unlock()
        for ip in ask { namer?.request(ip) }
        if let snapshot, let known { store?.save(snapshot, known: known) }
    }

    /// A new row for today. It takes a cached name at once; otherwise it waits for a lookup (or, for addresses never
    /// looked up, is final as "not looked up") and its destination is noted as known once its name is settled.
    private func newRow(_ key: RowKey, _ appName: String, _ scope: AddressScope, _ now: Date, _ ask: inout [String], lookups: Bool) -> DestinationRow {
        var r = DestinationRow(app: key.app, appName: appName, ip: key.ip, scope: scope, first: now, last: now)
        perApp[key.app, default: 0] += 1
        if key.ip == DestinationRow.otherIP { return r }
        if lookups && scope.lookUp, let namer {
            if let cached = namer.cached(key.ip) {
                r.host = cached; r.nameSource = cached == nil ? .none : .reverseDNS
            } else {
                awaiting[key.ip, default: []].insert(key); ask.append(key.ip)
                return r   // noted once named
            }
        }
        note(r)
        return r
    }

    /// Records the row's destination in the known list; a first contact by an established app becomes a NewContact.
    private func note(_ r: DestinationRow) {
        let dest = r.destinationKey
        if knownDests.note(app: r.app, name: r.appName, dest: dest, at: r.first) {
            contacts.append(NewContact(app: r.app, appName: r.appName, dest: dest, scope: r.scope, at: r.first))
            if contacts.count > 500 { contacts.removeFirst(contacts.count - 500) }
        }
    }

    /// A lookup finished: name every row waiting for this IP and settle their destinations.
    private func named(_ ip: String, _ name: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let keys = awaiting.removeValue(forKey: ip) else { return }
        for k in keys {
            guard var r = rows[k] else { continue }
            r.host = name; r.nameSource = name == nil ? .none : .reverseDNS
            rows[k] = r
            note(r)
        }
        revision += 1
    }

    /// PID → app, through a cache rebuilt from the process list when a PID isn't in it. A PID absent from the list
    /// too (it exited between the process sample and nettop's, or is too new to be listed) is attributed to "PID n",
    /// never guessed. The rebuild happens at most once per nettop run (`rebuilt`), so a run full of unlisted PIDs
    /// still costs O(processes) once.
    private func appFor(_ pid: Int32, _ procs: [ProcessSample], _ rebuilt: inout Bool) -> (key: String, name: String) {
        if let a = pidApps[pid] { return a }
        guard !rebuilt else { return ("proc:PID \(pid)", "PID \(pid)") }
        rebuilt = true
        let keys = AppUsage.groupKeys(procs)
        pidApps = Dictionary(zip(procs, keys).map { ($0.0.pid, ($0.1.key, $0.1.name)) }, uniquingKeysWith: { a, _ in a })
        if let a = pidApps[pid] { return a }
        return ("proc:PID \(pid)", "PID \(pid)")
    }

    /// The PID now belongs to another process: drop its cached app (Sampler calls this when it sees a PID reused).
    public func forget(pid: Int32) { lock.lock(); pidApps[pid] = nil; lock.unlock() }

    // MARK: Days

    /// Closes the open day (written to disk, known destinations pruned) and starts the one containing `t`.
    private func rollOver(to t: Date) {
        let closed = currentDayLocked()
        if !closed.rows.isEmpty { store?.save(closed, known: knownDests) }
        let start = calendar.startOfDay(for: t)
        dayEnds = calendar.date(byAdding: .day, value: 1, to: start)!
        day = store?.load(day: start) ?? DestinationDay(start: start)
        rows = [:]; perApp = [:]; awaiting = [:]
        for r in day.rows { rows[RowKey(app: r.app, ip: r.ip)] = r; perApp[r.app, default: 0] += 1 }
        knownDests.prune(before: t.addingTimeInterval(-Double(DestinationStore.retentionDays) * 86_400))
        store?.prune(now: t)
        revision += 1
    }

    private func currentDayLocked() -> DestinationDay {
        var d = day
        d.rows = rows.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.ip < $1.ip }
        return d
    }

    /// The open day as it stands.
    public func today() -> DestinationDay { lock.lock(); defer { lock.unlock() }; return currentDayLocked() }
    public func known() -> KnownDestinations { lock.lock(); defer { lock.unlock() }; return knownDests }
    /// First contacts since `since`, oldest first.
    public func newContacts(since: Date) -> [NewContact] {
        lock.lock(); defer { lock.unlock() }
        return contacts.filter { $0.at >= since }
    }

    /// Writes the open day now (at quit), synchronously.
    public func flush() {
        lock.lock(); let d = currentDayLocked(), k = knownDests; lock.unlock()
        store?.save(d, known: k, sync: true)
    }

    /// Forgets everything recorded: today's rows, the known list and the saved days.
    public func clear() {
        lock.lock()
        rows = [:]; perApp = [:]; awaiting = [:]; contacts = []; knownDests = KnownDestinations()
        day = DestinationDay(start: day.start); revision += 1
        lock.unlock()
        store?.clear()
    }
}
