import Foundation
// The long-term (90-day) history. `DailyLog` folds the snapshots the Engine already takes into one `DayRecord` per
// day, keeps the per-app baselines and the battery charge session, and persists all of it as JSON in
// ~/Library/Application Support/Flightdeck. It never samples anything itself.
//
// Cost: `ingest` does O(1) work per snapshot for the system statistics; the per-app pass (O(processes)) runs only every
// `appInterval` seconds. That is enough because app totals come from cumulative counters (CPU time, billed energy),
// whose difference is exact however rarely they are read. Files are written at most once a minute (and at quit) on a
// background queue; the closed days are only rewritten when a day closes or an event count changes.
//
// Threading: internally locked. The Engine calls `ingest` on its sampling queue; views call `history()` and
// `chargeStatus()` from the main actor; `note(...)` calls come from the main actor too.

public final class DailyLog: @unchecked Sendable {
    public struct Config: Sendable {
        public var retentionDays = 90
        /// Seconds between per-app passes.
        public var appInterval: TimeInterval = 10
        /// Seconds between writes of the open day.
        public var flushInterval: TimeInterval = 60
        /// Apps kept per closed day: the top `keepApps` by CPU time, plus the top 10 by energy and by peak memory.
        public var keepApps = 30
        /// Apps kept per day in the data-usage list (by bytes); the day's totals still cover every app.
        public var keepNetApps = 40
        /// A step between snapshots longer than this is a gap (sleep, pause, FlightDeck not running): nothing measured.
        public var gap: TimeInterval = 30
        public var baseline = AppBaseline.Rules()
        public init() {}
    }

    /// ~/Library/Application Support/Flightdeck (shared with the black box and incident log).
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Flightdeck")
    }

    public let config: Config
    /// nil = in-memory only (headless engines, tests). Nothing is ever written then.
    public let dir: URL?
    private let calendar: Calendar
    private let osVersion: String?, osBuild: String?
    private let lock = NSLock()
    private let io = DispatchQueue(label: "flightdeck.dailylog", qos: .utility)

    // All below guarded by `lock`.
    /// Closed days, oldest first.
    private var closed: [DayRecord] = []
    private var closedDirty = false
    /// The open day and its apps (a dictionary while accumulating; `today.apps` is filled on save/read).
    private var today: DayRecord?
    private var todayApps: [String: AppDay] = [:]
    private var todayEnds = Date.distantPast
    private var lastSample: Date?
    private var lastPass: Date?
    /// Cumulative counters per process at the previous pass (CPU seconds, energy joules).
    private var prevCPU: [ProcessIdentity: Double] = [:]
    private var prevEnergy: [ProcessIdentity: Double] = [:]
    /// Per-app data usage: byte counters per process at the previous pass, and the open day's sums (DataUsage.swift).
    private var netCounter = NetUsageCounter()
    private var todayNet = DataUsageTally()
    /// When this instance began watching. A process that started after this is counted from zero on first sight;
    /// one that was already running only sets its baseline (what it used earlier isn't known, or belongs to an earlier day).
    private var observingSince: Date?
    private var session: ChargeSession?
    private var lastSession: ChargeSession?
    /// Saved state not yet reconciled with the first live sample (resume the charge session or close it).
    private var pendingResume = false
    private var baselines: [String: AppBaseline] = [:]
    private var watch = BaselineWatch()
    private var lastFlush: Date?
    /// App versions read from bundles: path → (version, when read). Read on `io`, at most hourly per app.
    private var versions: [String: (String?, Date)] = [:]
    private var versionsInFlight = false

    public init(dir: URL?, config: Config = Config(), calendar: Calendar = .current,
                osVersion: String? = DailyLog.currentOSVersion, osBuild: String? = Sysctl.string("kern.osversion")) {
        self.dir = dir; self.config = config; self.calendar = calendar; self.osVersion = osVersion; self.osBuild = osBuild
        watch.rules = config.baseline
        load()
    }

    /// "26.1" or "15.6.1" (the marketing version; the build is kept separately).
    public static var currentOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    // MARK: Ingest

    /// Folds one snapshot in and returns the current baseline findings (rebuilt every app pass), so the caller can
    /// merge them with the Analyzer's.
    @discardableResult
    public func ingest(_ s: Snapshot) -> [Finding] {
        lock.lock(); defer { lock.unlock() }
        let t = s.time
        if observingSince == nil { observingSince = t }
        if today == nil || t >= todayEnds || t < today!.start { rollOver(to: t) }
        if pendingResume { resumeSession(s); pendingResume = false }
        // Seconds this snapshot stands for: the step from the previous one, unless that was a gap.
        let step = lastSample.map { t.timeIntervalSince($0) } ?? 0
        let dt = step > 0 && step <= config.gap ? step : 0
        if step > config.gap { watch.reset() }
        lastSample = t
        system(s, dt: dt)
        battery(s, dt: dt)
        if lastPass.map({ t.timeIntervalSince($0) >= config.appInterval || t < $0 }) ?? true { appPass(s) }
        if dir != nil, lastFlush.map({ t.timeIntervalSince($0) >= config.flushInterval || t < $0 }) ?? true {
            lastFlush = t; saveLocked()
        }
        return watch.findings
    }

    /// O(1) per snapshot: averages, maxima, histogram bin, energy integration.
    private func system(_ s: Snapshot, dt: Double) {
        guard var d = today else { return }
        var sums = d.sums ?? DaySums()
        d.observedSeconds += dt
        // The first snapshot after a gap still counts for maxima, and for averages with a nominal weight so a short
        // session isn't empty.
        let w = dt > 0 ? dt : 1
        if let c = s.cpu.total.value {
            sums.cpu += c * w; sums.cpuWeight += w
            sums.cpuHist[min(max(Int(c), 0), 99)] += w
        }
        if let p = s.memory.pressure.value {
            sums.pressure += p * w; sums.pressureWeight += w
            d.pressureMax = max(d.pressureMax ?? p, p)
        }
        if let sw = s.memory.swapUsed.value { d.swapMax = max(d.swapMax ?? sw, sw) }
        if let h = s.power.hottest.value { d.hottest = max(d.hottest ?? h, h) }
        d.worstThermalState = max(d.worstThermalState ?? s.power.thermalState, s.power.thermalState)
        // Energy only over real steps: across a gap we don't know what the Mac drew.
        if let watts = s.power.systemWatts.value, dt > 0 { sums.energy += watts * dt / 3600; sums.energySeen = true }
        if let b = s.power.battery {
            if let h = b.health { d.batteryHealth = h }
            if let c = b.cycleCount { d.cycleCount = c }
        }
        d.osVersion = osVersion; d.osBuild = osBuild
        d.sums = sums
        today = d
    }

    /// Opens, extends or closes the charge session.
    private func battery(_ s: Snapshot, dt: Double) {
        let onBattery = s.power.powerSource == "Battery"
        let pct = s.power.battery?.percent
        if onBattery {
            if session == nil {
                // A real unplug only if the previous snapshot was on AC; at launch it was already unplugged.
                session = ChargeSession(start: s.time, sawUnplug: lastSessionSawAC, percent: pct)
            }
            session!.lastTime = s.time
            if let pct { session!.lastPercent = pct; if session!.startPercent == nil { session!.startPercent = pct } }
            if let w = s.power.systemWatts.value, dt > 0 { session!.systemWh = (session!.systemWh ?? 0) + w * dt / 3600 }
            lastSessionSawAC = false
        } else {
            if var c = session { c.end = s.time; lastSession = c; session = nil }
            lastSessionSawAC = true
        }
    }
    /// Whether the previous snapshot was on AC power (so the next battery snapshot is a real unplug).
    private var lastSessionSawAC = false

    /// The saved session is resumed only if it plausibly continues: still on battery, saved recently, and the charge
    /// hasn't gone up (which would mean it was charged while FlightDeck wasn't running). Otherwise it's closed as is.
    private func resumeSession(_ s: Snapshot) {
        guard let c = session else { return }
        let pct = s.power.battery?.percent
        let plausible = s.power.powerSource == "Battery" && s.time.timeIntervalSince(c.lastTime) < 6 * 3600 && s.time >= c.lastTime
            && (pct.flatMap { p in c.lastPercent.map { p <= $0 + 1 } } ?? false)
        if !plausible {
            var done = c; done.end = c.lastTime; lastSession = done; session = nil
        }
    }

    /// Every `appInterval` s: per-app CPU time and energy from cumulative counters, footprint, running time; then the
    /// charge session's per-app energy and the baseline check.
    private func appPass(_ s: Snapshot) {
        let t = s.time
        let since = lastPass.map { t.timeIntervalSince($0) } ?? 0
        lastPass = t
        // Running time and the current-CPU figure need a normal step; a long one is a gap (sleep). Counter deltas are
        // still exact across it, so they are kept.
        let running = since > 0 && since <= max(config.appInterval * 6, 60) ? since : 0
        let onBattery = session != nil && s.power.powerSource == "Battery"
        let start = observingSince ?? t
        struct Now { var name: String; var icon: String; var cpu = 0.0; var energy = 0.0; var energySeen = false; var memory = 0.0; var pids: [(Int32, UInt64)] = [] }
        var now: [String: Now] = [:]
        var nextCPU: [ProcessIdentity: Double] = [:], nextEnergy: [ProcessIdentity: Double] = [:]
        nextCPU.reserveCapacity(s.processes.count)
        let keys = AppUsage.groupKeys(s.processes)
        for (p, k) in zip(s.processes, keys) {
            var a = now[k.key] ?? Now(name: k.name, icon: k.icon)
            let fresh = p.startDate >= start
            let pc = prevCPU[p.identity] ?? (fresh ? 0 : nil)
            if let pc, p.cpuTime >= pc { a.cpu += p.cpuTime - pc }
            nextCPU[p.identity] = p.cpuTime
            if let e = p.energyTotal {
                let pe = prevEnergy[p.identity] ?? (fresh ? 0 : nil)
                if let pe, e >= pe { a.energy += e - pe }
                a.energySeen = true
                nextEnergy[p.identity] = e
            } else if let w = p.energyWatts {
                // No cumulative counter: integrate the rate over the pass instead.
                a.energy += w * running; a.energySeen = true
            }
            a.memory += Double(p.memory)
            a.pids.append((p.pid, p.memory))
            now[k.key] = a
        }
        prevCPU = nextCPU; prevEnergy = nextEnergy
        // Data usage: byte deltas from nettop's cumulative counters (same O(processes) pass, every appInterval).
        if let d = netCounter.pass(s.processes, keys: keys) { todayNet.add(d, seconds: running, at: t) }
        var current: [String: (name: String, cpu: Double?, memory: Double, pids: [Int32])] = [:]
        for (id, a) in now {
            var d = todayApps[id] ?? AppDay(id: id, name: a.name)
            d.cpuSeconds += a.cpu
            if a.energySeen { d.energyWh = (d.energyWh ?? 0) + a.energy / 3600 }
            d.peakMemory = max(d.peakMemory, UInt64(a.memory))
            d.memorySeconds += a.memory * running; d.runningSeconds += running
            todayApps[id] = d
            if onBattery, a.energy > 0 {
                var e = session!.apps[id] ?? ChargeSession.App(name: a.name, icon: a.icon, wattHours: 0)
                e.wattHours += a.energy / 3600; session!.apps[id] = e
            }
            current[id] = (a.name, running > 0 ? a.cpu / running * 100 : nil, a.memory, a.pids.sorted { $0.1 > $1.1 }.map(\.0))
        }
        if running > 0 { watch.update(current, baselines: baselines, at: t) } else { watch.reset() }
    }

    // MARK: Days

    private func dayKey(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Closes the open day (if any) and opens the one containing `t`. A saved open day for the same date (FlightDeck
    /// relaunched) is simply continued.
    private func rollOver(to t: Date) {
        let start = calendar.startOfDay(for: t)
        if let d = today, d.start == start { todayEnds = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400); return }
        closeToday()
        // A record for this date may already exist among the closed ones (the clock went back); continue it.
        if let i = closed.firstIndex(where: { $0.start == start }) {
            today = closed.remove(at: i); today!.sums = today!.sums ?? DaySums()
            todayApps = Dictionary(today!.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            todayNet = DataUsageTally(today!.dataUsage)
            closedDirty = true
        } else {
            today = DayRecord(day: dayKey(t), start: start); today!.sums = DaySums(); todayApps = [:]
            todayNet = DataUsageTally()
        }
        todayEnds = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        // Retention: drop days older than `retentionDays`.
        let cutoff = calendar.date(byAdding: .day, value: -config.retentionDays, to: start) ?? start
        closed.removeAll { $0.start < cutoff }
        baselines = AppBaseline.build(from: closed, now: t, rules: config.baseline)
    }

    /// Finalizes the open day, trims its apps and moves it to `closed`.
    private func closeToday() {
        guard var d = today else { return }
        d.finalizeStats(); d.sums = nil
        d.apps = Self.trim(Array(todayApps.values), keep: config.keepApps)
        d.dataUsage = todayNet.day(keep: config.keepNetApps); todayNet = DataUsageTally()
        if d.observedSeconds > 0 || !d.apps.isEmpty || d.dataUsage != nil {
            closed.append(d); closed.sort { $0.start < $1.start }
        }
        closedDirty = true
        today = nil; todayApps = [:]
    }

    /// The top `keep` apps by CPU time, plus the top 10 by energy and by peak memory (so a light but power-hungry or
    /// memory-heavy app keeps its history), sorted by CPU time.
    static func trim(_ apps: [AppDay], keep: Int) -> [AppDay] {
        var ids = Set(apps.sorted { $0.cpuSeconds > $1.cpuSeconds }.prefix(keep).map(\.id))
        ids.formUnion(apps.filter { ($0.energyWh ?? 0) > 0 }.sorted { ($0.energyWh ?? 0) > ($1.energyWh ?? 0) }.prefix(10).map(\.id))
        ids.formUnion(apps.sorted { $0.peakMemory > $1.peakMemory }.prefix(10).map(\.id))
        return apps.filter { ids.contains($0.id) }.sorted { $0.cpuSeconds > $1.cpuSeconds }
    }

    /// Today as it stands, with averages computed and apps listed (all of them, unsorted dictionary → sorted array).
    private func todaySnapshot() -> DayRecord? {
        guard var d = today else { return nil }
        d.finalizeStats()
        d.apps = todayApps.values.sorted { $0.cpuSeconds > $1.cpuSeconds }
        d.dataUsage = todayNet.day(keep: .max)
        return d
    }

    // MARK: Persistence
    // Two files: daily-log.json (closed days; rewritten only when they change) and daily-today.json (the open day with
    // its running sums, and the battery sessions; small, rewritten every `flushInterval`).

    struct OpenState: Codable { var version = 1; var today: DayRecord?; var session: ChargeSession?; var lastSession: ChargeSession? }
    struct ClosedState: Codable { var version = 1; var days: [DayRecord] }
    var closedURL: URL? { dir?.appendingPathComponent("daily-log.json") }
    var openURL: URL? { dir?.appendingPathComponent("daily-today.json") }
    private static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }

    /// Reads both files (once, from init). Unreadable files are ignored: history starts afresh rather than failing.
    /// The saved open day is continued if it's still today (checked on the first `ingest`, which rolls it over otherwise).
    private func load() {
        guard let c = closedURL, let o = openURL else { return }
        if let d = try? Data(contentsOf: c), let st = try? Self.decoder().decode(ClosedState.self, from: d) { closed = st.days.sorted { $0.start < $1.start } }
        if let d = try? Data(contentsOf: o), let st = try? Self.decoder().decode(OpenState.self, from: d) {
            today = st.today
            if today != nil && today!.sums == nil { today!.sums = DaySums() }
            todayApps = Dictionary((st.today?.apps ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            todayNet = DataUsageTally(st.today?.dataUsage)
            session = st.session; lastSession = st.lastSession
            pendingResume = session != nil
        }
        // todayEnds stays distantPast, so the first ingest decides whether the saved day continues or closes.
        baselines = AppBaseline.build(from: closed, now: Date(), rules: config.baseline)
    }

    /// Encodes under the lock (small: one day plus sessions; the closed days only when changed) and returns the write,
    /// for the caller to run on `io`. Caller holds `lock`. (The write itself must not be waited for under the lock: a
    /// version read queued on `io` takes the lock, so `io.sync` while holding it could deadlock.)
    private func encodeLocked() -> (() -> Void)? {
        guard let cu = closedURL, let ou = openURL, let dir else { return nil }
        var t = todaySnapshot()
        // Keep the open day's full app list on disk: it is trimmed when the day closes, not before.
        t?.sums = today?.sums
        let open = try? Self.encoder().encode(OpenState(today: t, session: session, lastSession: lastSession))
        let closedData = closedDirty ? try? Self.encoder().encode(ClosedState(days: closed)) : nil
        closedDirty = false
        return {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let open { try? open.write(to: ou, options: .atomic) }
            if let closedData { try? closedData.write(to: cu, options: .atomic) }
        }
    }

    /// Periodic save from `ingest` (caller holds `lock`): write in the background, then refresh app versions.
    private func saveLocked() {
        guard let write = encodeLocked() else { return }
        io.async(execute: write)
        refreshVersionsLocked()
    }

    /// Reads CFBundleShortVersionString for today's app bundles whose version is unknown or over an hour old, on `io`.
    /// Info.plist is read directly rather than through `Bundle`, which caches and would miss an update made on disk.
    private func refreshVersionsLocked() {
        guard !versionsInFlight, let now = lastSample else { return }
        let due = todayApps.keys.filter { $0.hasSuffix(".app") && (versions[$0].map { now.timeIntervalSince($0.1) > 3600 } ?? true) }
        // Apply what's already known (an app first seen today after its version was read earlier).
        for (id, v) in versions where todayApps[id] != nil { todayApps[id]!.version = v.0 }
        guard !due.isEmpty else { return }
        versionsInFlight = true
        io.async { [weak self] in
            var read: [String: String?] = [:]
            for path in due {
                let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
                read[path] = plist?["CFBundleShortVersionString"] as? String
            }
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            for (path, v) in read {
                self.versions[path] = (v, now)
                if self.todayApps[path] != nil { self.todayApps[path]!.version = v }
            }
            self.versionsInFlight = false
        }
    }

    /// Writes everything now and waits for it (quit). A no-op without a directory.
    public func flush() {
        lock.lock(); let write = encodeLocked(); lock.unlock()
        if let write { io.sync(execute: write) }
    }

    // MARK: Reading (UI)

    /// Everything the Trends view needs, as a value copy. `days` is oldest first and ends with today (open, trimmed
    /// to the same apps a closed day would keep).
    public struct History: Sendable {
        public var days: [DayRecord]
        public var baselines: [String: AppBaseline]
        public var charge: ChargeStatus
        public var minBaselineDays: Int
        public init(days: [DayRecord], baselines: [String: AppBaseline], charge: ChargeStatus, minBaselineDays: Int) {
            self.days = days; self.baselines = baselines; self.charge = charge; self.minBaselineDays = minBaselineDays
        }
    }

    /// O(days × apps) copy; call on demand (view appearance, periodic refresh), not per sample.
    public func history() -> History {
        lock.lock(); defer { lock.unlock() }
        var days = closed
        if var t = todaySnapshot() { t.apps = Self.trim(t.apps, keep: config.keepApps); t.dataUsage = todayNet.day(keep: config.keepNetApps); t.sums = nil; days.append(t) }
        return History(days: days, baselines: baselines, charge: ChargeStatus(current: session, last: lastSession), minBaselineDays: config.baseline.minDays)
    }

    /// Just the battery sessions (cheap; the Energy panel polls it).
    public func chargeStatus() -> ChargeStatus {
        lock.lock(); defer { lock.unlock() }
        return ChargeStatus(current: session, last: lastSession)
    }

    /// The current baseline findings (what the last `ingest` returned).
    public var findings: [Finding] { lock.lock(); defer { lock.unlock() }; return watch.findings }

    // MARK: Events from elsewhere (main actor)

    /// Applies `f` to the record for `date`'s day (open or closed). Days FlightDeck never ran aren't created.
    private func withDay(_ date: Date, _ f: (inout DayRecord) -> Void) {
        let start = calendar.startOfDay(for: date)
        if today?.start == start { f(&today!); return }
        if let i = closed.firstIndex(where: { $0.start == start }) { f(&closed[i]); closedDirty = true }
    }

    /// Counts crash and hang reports, and incidents, per day. The sources only reach back 7 days, so counts only ever
    /// go up (max with what's stored): a day whose reports have since been deleted keeps its count.
    public func note(reports: [DiagnosticReport], incidents: [Incident]) {
        lock.lock(); defer { lock.unlock() }
        var byDay: [Date: (crashes: Int, hangs: Int, incidents: Int, c: [String: Int], h: [String: Int])] = [:]
        // Every day in the window is counted, so a day with no reports gets a real 0 (we looked) rather than nil.
        let now = lastSample ?? Date()
        for k in 0..<7 { if let d = calendar.date(byAdding: .day, value: -k, to: calendar.startOfDay(for: now)) { byDay[d] = (0, 0, 0, [:], [:]) } }
        for r in reports {
            let d = calendar.startOfDay(for: r.time)
            guard var e = byDay[d] else { continue }
            if r.kind == .crash { e.crashes += 1; e.c[r.process, default: 0] += 1 }
            if r.kind == .hang { e.hangs += 1; e.h[r.process, default: 0] += 1 }
            byDay[d] = e
        }
        for i in incidents where !i.key.hasPrefix("rule:") {
            let d = calendar.startOfDay(for: i.start)
            if var e = byDay[d] { e.incidents += 1; byDay[d] = e }
        }
        for (d, e) in byDay {
            withDay(d) { r in
                r.crashes = max(r.crashes ?? 0, e.crashes); r.hangs = max(r.hangs ?? 0, e.hangs); r.incidents = max(r.incidents ?? 0, e.incidents)
                r.crashesByProcess = (r.crashesByProcess ?? [:]).merging(e.c, uniquingKeysWith: max)
                r.hangsByProcess = (r.hangsByProcess ?? [:]).merging(e.h, uniquingKeysWith: max)
            }
        }
    }

    /// Hours asleep per day, from the power log the Engine already reads after each wake (sleeps are counted on the
    /// day they ended). Max with what's stored, since the log read covers only the last day or so.
    public func note(sleep report: SleepReport) {
        lock.lock(); defer { lock.unlock() }
        var byDay: [Date: Double] = [:]
        for s in report.sessions { byDay[calendar.startOfDay(for: s.end), default: 0] += Double(s.asleepSeconds) / 3600 }
        for (d, h) in byDay { withDay(d) { r in r.sleepHours = max(r.sleepHours ?? 0, h) } }
    }

    /// Demo mode / previews only: replaces the in-memory history. Refused for a persisted log.
    public func replaceForDemo(days: [DayRecord], charge: ChargeStatus) {
        guard dir == nil else { return }
        lock.lock(); defer { lock.unlock() }
        closed = days.sorted { $0.start < $1.start }; today = nil; todayApps = [:]; todayNet = DataUsageTally()
        session = charge.current; lastSession = charge.last
        baselines = AppBaseline.build(from: closed, now: closed.last.map { $0.start.addingTimeInterval(86_400) } ?? Date(), rules: config.baseline)
    }
}
