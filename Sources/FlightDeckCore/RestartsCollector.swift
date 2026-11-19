import Foundation

// Ties the Restarts & Crashes sources together: reads them, asks the unified log for causes it doesn't have yet,
// classifies every boot, measures the current boot's login, and saves what it learned in BootStore. Run when the page
// is shown, on Refresh, and once at launch for the findings; never on a timer.

/// Everything the page, the MCP tools and the findings need.
public struct RestartsReport: Sendable {
    public var events: [BootEvent] = []
    public var panics: [PanicReport] = []
    /// App hangs and spins from macOS's diagnostic reports ("the app froze"), newest first.
    public var hangs: [DiagnosticReport] = []
    public var hibernateWakes: [PowerLogEvent] = []
    /// The current boot's timing (nil in demo/tests when not given).
    public var current: BootTiming?
    /// Saved boots, newest first (timing history for the trend).
    public var history: [BootRecord] = []
    /// How far back each source reaches, for the "what's unknown and why" notes.
    public var oldestBoot: Date?
    public var shutdownLogSince: Date?
    public var unifiedLogSince: Date?
    public var powerLogSince: Date?
    /// Lifetime counters of the internal SSD, if readable: (power cycles, unsafe shutdowns).
    public var ssd: (cycles: UInt64, unsafe: UInt64)?
    public init() {}

    public var unexpectedCount: Int { events.filter(\.previous.isUnexpected).count }

    /// Plain-English notes on what the sources can't tell, built from how far back each reaches.
    public var limits: [String] {
        var n: [String] = []
        func d(_ x: Date) -> String { x.formatted(date: .abbreviated, time: .omitted) }
        if let b = oldestBoot { n.append("Boots: macOS's login records (wtmp) start on \(d(b)), usually the last macOS install or major update.") }
        else { n.append("Boots: macOS's login records (wtmp) couldn't be read.") }
        if let s = shutdownLogSince { n.append("Clean or not: logd's shutdown log has orderly-shutdown markers back to \(d(s)); earlier sessions are \"not recorded\" unless FlightDeck saved them.") }
        else { n.append("Clean or not: logd's shutdown log isn't readable, so a missing shutdown record can't be told from an unexpected one.") }
        if let u = unifiedLogSince {
            n.append("Shutdown cause codes: the unified log's oldest entry is from \(d(u)); boot messages usually expire sooner, as the log rotates by size. FlightDeck saves each cause it finds, so the history grows while it runs.")
        } else { n.append("Shutdown cause codes: the unified log keeps only days; FlightDeck saves each cause it finds.") }
        if let p = powerLogSince { n.append("Power log (shutdown, restart, hibernation): back to \(d(p)).") }
        n.append("Login timing: launch times of loginwindow, Dock, Finder and login items, to the second. They are measured for the current boot only (earlier processes are gone); older boots show what FlightDeck saved, plus boot-to-login from wtmp.")
        return n
    }
}

public enum RestartsCollector {
    /// Most boots asked about per run; each query takes about a second.
    public static let maxQueries = 10

    /// - Parameters:
    ///   - queryLog: `.none` (MCP: saved causes only), `.current` (launch check: the current boot), `.recent`
    ///     (the page: every boot in the last 30 days not asked about before, newest first, up to `maxQueries`).
    ///   - blackBox: frames covering the first minutes after login, for "busiest after login".
    /// Blocking; call off the main thread.
    public enum LogQueries: Sendable { case none, current, recent }
    public static func collect(store: BootStore, queryLog: LogQueries, blackBox: (@Sendable (Date, Date) -> [Snapshot])? = nil,
                               now: Date = Date()) -> RestartsReport {
        var r = RestartsReport()
        var causes = store.records.compactMap(\.cause)
        var src = BootSourcesReader.read(panicsSince: now.addingTimeInterval(-BootStore.retention), causes: causes)
        let currentBoot = Sysctl.timeval("kern.boottime")
        // Saved boots join wtmp's, so a boot recorded before wtmp was reset still shows.
        src.boots += store.records.map(\.boot)
        var events = BootHistory.classify(src)

        // Unified-log queries for boots without a saved cause.
        let targets: [Date]
        switch queryLog {
        case .none: targets = []
        case .current: targets = currentBoot.map { [$0] } ?? []
        case .recent: targets = events.map(\.boot).filter { now.timeIntervalSince($0) < 30 * 86_400 }
        }
        var asked = 0
        for b in targets where asked < maxQueries && !(store.record(for: b)?.causeQueried ?? false) {
            asked += 1
            let found = ShutdownCauseLog.query(boot: b)
            store.update(b) { $0.causeQueried = true; if let found { $0.cause = found } }
            if let found { causes.append(found) }
        }
        if asked > 0 { src.causes = causes; events = BootHistory.classify(src) }

        // A saved verdict replaces "not recorded" once its sources expire; fresh verdicts are saved.
        for i in events.indices {
            let e = events[i]
            if e.previous.kind == .unknown, let saved = store.record(for: e.boot)?.verdict, saved.kind != .unknown { events[i].previous = saved }
            else if e.previous.kind != .unknown { store.update(e.boot) { $0.verdict = e.previous } }
        }
        r.events = events.filter { now.timeIntervalSince($0.boot) <= BootStore.retention }
        r.panics = src.panics
        r.hibernateWakes = src.power.filter { $0.kind == .hibernateWake }
        r.powerLogSince = src.powerLogSince
        r.oldestBoot = events.last?.boot
        r.shutdownLogSince = src.logdFlushes.min()
        if queryLog == .recent { r.unifiedLogSince = ShutdownCauseLog.oldestEntry() }
        r.hangs = DiagnosticReports.scan(since: now.addingTimeInterval(-30 * 86_400)).filter { $0.kind == .hang }
        if let d = DriveHealthReader.read().first { r.ssd = (d.powerCycles, d.unsafeShutdowns) }

        // The current boot's timing: measured now, merged with what was saved earlier in this boot (a Dock restarted
        // since login would otherwise lose the desktop time).
        if let b = currentBoot {
            let login = r.events.first(where: { abs($0.boot.timeIntervalSince(b)) < 60 })?.login
            let procs = ProcessSampler().sample().map(BootProcess.init)
            let (agents, daemons) = BootTimer.launchPrograms()
            var t = BootTimer.compute(boot: b, login: login, processes: procs, uid: getuid(), agents: agents, daemons: daemons)
            let saved = store.record(for: b)?.timing
            if let login, let frames = blackBox?(login, login.addingTimeInterval(BootTimer.busyWindow)), let busy = BootTimer.busiest(frames: frames, login: login) {
                t.busiest = busy; t.busiestSource = .blackBox
            } else if saved?.busiestSource == .blackBox {
                t.busiest = saved!.busiest; t.busiestSource = .blackBox
            } else if let login, now.timeIntervalSince(login) < 3600 {
                // CPU time since start says something about login only while the login was recent; after hours or
                // days it measures the whole session, so it isn't shown then (the panel says it wasn't measured).
                t.busiest = Array(t.items.filter { ($0.cpuSeconds ?? 0) > 0 }.sorted { ($0.cpuSeconds ?? 0) > ($1.cpuSeconds ?? 0) }.prefix(8))
                t.busiestSource = t.busiest.isEmpty ? nil : .sinceStart
            }
            if let saved {
                t.loginWindow = t.loginWindow ?? saved.loginWindow; t.desktop = t.desktop ?? saved.desktop
                if t.items.isEmpty { t.items = saved.items; t.itemsDone = saved.itemsDone }
            }
            r.current = t
            store.update(b) { $0.timing = t }
        }
        store.save(now: now)
        r.history = store.records
        return r
    }

    /// The launch check: collects with one log query (the current boot), then returns the restart findings not yet
    /// announced since the last check, and remembers them. On the first run only the last 24 hours count, so an old
    /// history doesn't become a burst of findings.
    public static func launchCheck(store: BootStore, now: Date = Date()) -> [Finding] {
        let r = collect(store: store, queryLog: .current, now: now)
        let since = store.lastCheck ?? now.addingTimeInterval(-86_400)
        let (f, keys) = RestartFindings.evaluate(events: r.events, panics: r.panics, announced: store.announced, since: since)
        store.markAnnounced(keys, checked: now)
        store.save(now: now)
        return f
    }
}
