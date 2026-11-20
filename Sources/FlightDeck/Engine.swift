// The app's central model object. Engine drives the sampling timer, owns the Sampler and the analysis pipeline
// (Analyzer, IncidentLog, RuleEngine, evidence capture), feeds the black box, Dock tile and alerts, and publishes the
// state every SwiftUI view reads. It also implements replay: loading a trace swaps `frames`/`current` for recorded data.
//
// Threading: Engine itself is @MainActor. Sampling and analysis run on the serial `queue` ("flightdeck.sampler");
// the black box writes on `blackBoxQueue`, and stack sampling for evidence runs on `evidenceQueue`.
import SwiftUI
import FlightDeckCore
import UniformTypeIdentifiers

/// Whether views show live data or a loaded trace. Live sampling continues during replay (see `liveSnapshot`).
enum Mode: Equatable { case live, replay }

/// Owns sampling, history, and the Flight Recorder. Views read `frames` (history, `nil` = gap)
/// and `current`; in replay mode both come from the loaded trace, so every view replays for free.
@MainActor
final class Engine: ObservableObject {
    /// Number of samples kept for graphs (120 = 2 minutes at the default 1 s interval).
    static let historyLength = 120

    /// The snapshot views display: the latest live sample, or in replay mode the frame at `replayIndex`.
    @Published private(set) var current: Snapshot?
    /// Always the latest live sample, even while replaying (menu bar, Dock, alerts).
    @Published private(set) var liveSnapshot: Snapshot?
    /// Graph history, oldest first, always `historyLength` long. `nil` entries are gaps (sampling was paused, or a hole
    /// in a replayed recording); graphs draw them as breaks rather than interpolating across. Processes are trimmed to the top 12
    /// by CPU to keep the array light; use `current` for the full list.
    @Published private(set) var frames: [Snapshot?] = Array(repeating: nil, count: Engine.historyLength)
    /// Pausing closes every open incident (we can't tell how long they lasted while unobserved); resuming pushes a
    /// gap so graphs show the unobserved stretch as a break.
    @Published var paused = false { didSet { if !paused { pushGap() } else { queue.async { [incidentLog] in incidentLog.closeAll(at: Date()) } } } }
    /// Sample interval in seconds while a window is visible.
    @AppStorage("interval") var interval: Double = 1.0 { didSet { restartTimer() } }
    /// Whether FlightDeck's own process is included in the process list.
    @AppStorage("includeSelf") var includeSelf = true
    /// Sample interval while no FlightDeck window is visible (menu bar / background only).
    @AppStorage("backgroundInterval") var backgroundInterval: Double = 2.0
    /// When the last sample was started; used by `tick()` to throttle to `backgroundInterval` while hidden.
    private var lastTick = Date.distantPast
    /// Whether samples are written to the always-on black box recorder.
    @AppStorage("blackBoxEnabled") var blackBoxEnabled = true
    /// Per-app CPU threshold (% of one core) above which the Analyzer reports a sustained CPU hog. Forwarded to the
    /// sampling queue on change.
    @AppStorage("appCPUThreshold") var appCPUThreshold = 80.0 { didSet { applyThresholds() } }
    /// Opt-in: pings the router and `netProbeHost` every 10 s. Off by default (privacy).
    @AppStorage("netProbeEnabled") var netProbeEnabled = false { didSet { applyProbe() } }
    @AppStorage("netProbeHost") var netProbeHost = "1.1.1.1" { didSet { applyProbe() } }

    // Flight Recorder: user-started recordings (`recorded`) and replay of a loaded `trace`.
    // Flight Recorder
    @Published private(set) var mode: Mode = .live
    @Published private(set) var recording = false
    /// Frames captured since `startRecording()`, trimmed with `Trace.trimmed` to keep memory down.
    @Published private(set) var recorded: [Snapshot] = []
    @Published var trace: FlightDeckCore.Trace?
    /// Position in `trace.frames` being shown. Every change rebuilds `frames`, `current` and `replayFindings`.
    @Published var replayIndex = 0 { didSet { if mode == .replay { applyReplay() } } }
    @Published var playing = false
    /// User-facing error message (shown as an alert by the main window); set from the main actor only.
    @Published var lastError: String?

    // Analysis: findings (live, or recomputed for the replayed moment) and the incident log.
    // `liveFindings` and `incidents` are copies of state that lives on the sampling queue, republished after each sample.
    // Analysis: findings (live, or recomputed for the replayed moment) and the incident log
    @Published private(set) var liveFindings: [Finding] = []
    @Published private(set) var replayFindings: [Finding] = []
    @Published private(set) var incidents: [Incident] = []
    /// Days until the startup disk fills at the current trend (nil = no clear shrinking trend).
    @Published private(set) var diskFullDays: Double?
    /// Findings for the current mode: live analyzer findings plus diagnostic-report findings, or in replay the findings
    /// recomputed for the replayed moment (diagnostic reports aren't part of a trace).
    var findings: [Finding] { mode == .live ? liveFindings + reportFindings + sleepFindings : replayFindings }
    /// Live findings the user hasn't muted: these drive the caution lights (menu bar, Dock lamp).
    var unmutedLiveFindings: [Finding] { (liveFindings + reportFindings + sleepFindings).filter { !Alerts.shared.isMuted($0) } }
    /// Findings about the last sleep (many dark wakes, battery drain), from the power log after each wake.
    @Published private(set) var sleepFindings: [Finding] = []

    /// Reads the power log off the main thread and refreshes `sleepFindings`.
    private func refreshSleepFindings() {
        Task {
            let r = await Task.detached(priority: .utility) { SleepLog.read(days: 1) }.value
            sleepFindings = r.map { SleepLog.findings($0) } ?? []
            if let r { dailyLog.note(sleep: r) }   // hours asleep per day, from the log already read
        }
    }
    /// macOS diagnostic reports from the last 7 days (rescanned every 5 minutes).
    @Published private(set) var reports: [DiagnosticReport] = []
    /// Findings derived from recent diagnostic reports (crashes, hangs, etc.).
    @Published private(set) var reportFindings: [Finding] = []

    // Rules: user automations evaluated on every sample. The main-actor array is the source of truth and is persisted to
    // UserDefaults on every change; a copy is pushed to the queue-confined RuleEngine.
    // Rules: user automations evaluated on every sample.
    @Published var rules: [Rule] = RuleEngine.load(UserDefaults.standard.data(forKey: "rules")) {
        didSet {
            guard !headless else { return }   // a headless (benchmark/demo) engine never persists anything
            UserDefaults.standard.set(RuleEngine.save(rules), forKey: "rules"); let r = rules; queue.async { [ruleEngine] in ruleEngine.rules = r }
        }
    }
    /// One line in the rule activity log: what fired and what the action did.
    /// One automatic action, as shown in the Rules view and kept on disk (last 200).
    struct RuleLogEntry: Identifiable, Codable { var id: UUID; var time: Date; var rule: String; var action: String; var subject: String; var result: String }
    /// Most recent rule actions first, capped at 100.
    @Published private(set) var ruleLog: [RuleLogEntry] = []
    /// Set to a Destination raw value (optionally "Performance:<tab>") to navigate there.
    @Published var navigationRequest: String?

    /// Reads all the system counters. Its delta state means it must only be used on `queue`.
    private let sampler = Sampler()
    /// Serial sampling queue: sampling, analysis, incident tracking and rule evaluation all happen here.
    private let queue = DispatchQueue(label: "flightdeck.sampler", qos: .utility)
    private var timer: Timer?
    private var playTimer: Timer?
    /// True from the moment a sample is dispatched until its results are ingested on the main actor; a slow sample
    /// causes ticks to be skipped rather than piling up work on the queue.
    private var inFlight = false

    // Black box: always-on rolling recorder, written off the sampling queue on its own background-priority queue.
    // Black box: always-on rolling recorder, written off the sampling queue.
    let blackBox = BlackBox(dir: BlackBox.defaultDirectory)
    /// Recent history of every process (for the inspector).
    /// Thread-safe (internally locked): recorded on `queue`, read from views.
    let processHistory = ProcessHistory()
    /// Launches and exits seen between samples (Launches view, respawn finding). Thread-safe like processHistory:
    /// fed on `queue`, read from views. O(n) per sample.
    let launchLog = LaunchLog()
    let blackBoxQueue = DispatchQueue(label: "flightdeck.blackbox", qos: .background)
    // Confined to `queue`. They are `nonisolated` so the sampling closures can use them without hopping to the main actor;
    // `nonisolated(unsafe)` marks vars whose safety comes from that confinement rather than from the compiler.
    // Confined to `queue`.
    nonisolated private let analyzer = Analyzer()
    nonisolated private let ruleEngine = RuleEngine()
    nonisolated private let incidentLog = IncidentLog(url: IncidentLog.defaultURL)
    /// Last `incidentLog.revision` published to `incidents`, so the log is only copied to the main actor when it changed.
    nonisolated(unsafe) private var incidentRevision = -1
    nonisolated(unsafe) private var lastIncidentSave = Date()
    // Evidence capture (confined to `queue`): one capture at a time, at most one per finding every 10 minutes.
    nonisolated(unsafe) private var evidenceBusy = false
    nonisolated(unsafe) private var lastEvidence: [String: Date] = [:]
    /// Stack sampling takes several seconds, so it runs on its own queue to avoid stalling sampling.
    private let evidenceQueue = DispatchQueue(label: "flightdeck.evidence", qos: .utility)

    /// `headless`: no timers, no black box, no Dock tile; frames are fed with `feed(_:)` (UI benchmark).
    let headless: Bool
    /// 90-day daily rollups, per-app baselines and battery sessions (Trends view). Internally locked: ingested on
    /// `queue`, read by views on demand. In-memory only (never written) for a headless engine.
    nonisolated let dailyLog: DailyLog
    /// The current charge session's curve and the peak system draw (Performance › Energy › Charging). In memory only.
    nonisolated let chargeCurve = ChargeCurve()
    /// Per-sensor history, throttling, fan health and temperature alerts (Performance › Thermals). Internally locked:
    /// ingested on `queue`, read by views. Demo data is catalogued with the generic Apple-silicon table, so demo
    /// sensor names never depend on this Mac's chip.
    nonisolated let thermal: ThermalWatch

    init(headless: Bool = false, chip: ChipFamily? = nil) {
        self.headless = headless
        thermal = ThermalWatch(chip: chip ?? (Demo.isEnabled ? .appleSilicon : .current))
        dailyLog = DailyLog(dir: headless ? nil : DailyLog.defaultDirectory)
        if headless { rules = []; return }   // never show the user's saved rules, rule log or incidents in a headless engine
        ruleLog = Engine.loadRuleLog()
        applyTemperatureAlerts()   // after the headless return: a headless engine never uses the user's alert settings
        sampler.destinations = DestinationService.tracker; DestinationService.start()   // per-app destinations (nil in demo mode)
        // The first sample only establishes baselines for delta-based counters (CPU ticks, bytes); its result is discarded.
        queue.async { [sampler] in _ = sampler.sample() }   // prime deltas
        restartTimer()
        // Housekeeping off the main thread: prune old black-box segments and evidence files, then seed the Analyzer's
        // baselines with the last 24 h of coarse black-box history so "unusual for this Mac" findings work right after launch.
        blackBoxQueue.async { [blackBox, queue, analyzer] in
            blackBox.prune(); EvidenceStore.prune()
            let history = blackBox.trace(.coarse, from: Date().addingTimeInterval(-86_400))?.frames ?? []
            queue.async { analyzer.seed(history: history) }
        }
        // Safe to read here: nothing has touched incidentLog on `queue` yet (it only loaded from disk in its initializer).
        incidents = incidentLog.incidents
        // Diagnostic reports: rescan every 5 minutes on a detached task (reading many report files is slow).
        Task { [weak self] in
            while !Task.isCancelled {
                let r = await Task.detached(priority: .utility) { DiagnosticReports.scan(since: Date().addingTimeInterval(-7 * 86_400)) }.value
                self?.reports = r; self?.reportFindings = DiagnosticReports.findings(r)
                self?.dailyLog.note(reports: r, incidents: self?.incidents ?? [])   // per-day crash/hang/incident counts
                try? await Task.sleep(for: .seconds(300))
            }
        }
        applyThresholds()
        applyProbe()
        MetricsEndpoint.shared.configure(engine: self)   // Prometheus endpoint, if turned on in Settings
        MCPEndpoint.shared.configure(engine: self)       // MCP server for AI assistants, if turned on in Settings
        CameraMicService.start()   // camera & microphone listeners (event-driven; nothing in demo mode)
        let r = rules; queue.async { [ruleEngine] in ruleEngine.rules = r }
        startVisibilityTracking()
        // Sleep findings: at launch, after every wake, and every 30 minutes (so they expire 12 h after waking).
        refreshSleepFindings()
        RestartsModel.launchCheck()   // once, ~30 s after launch: unexpected shutdowns and panics since the last check
        ChangeService.start()   // What Changed: an inventory ~90 s after launch, then every 15 minutes (nothing in demo mode)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // give powerd a moment to write the wake to the log
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MainActor.assumeIsolated { self?.refreshSleepFindings() } }
        }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshSleepFindings() } }
        // On quit, flush the black box and close/save the incident log synchronously so nothing buffered is lost.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [blackBox, blackBoxQueue, queue, incidentLog, dailyLog] _ in
            blackBoxQueue.sync { blackBox.flush() }
            queue.sync { incidentLog.closeAll(at: Date()); incidentLog.save() }
            dailyLog.flush()
        }
        // Anything a Suspend rule stopped is resumed when FlightDeck quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeSuspended(all: true) }
        }
    }

    /// Runs on the main actor, called from `tick()` for each firing returned by the RuleEngine.
    /// Carries out a rule's action. Signals are identity-checked (a recycled PID is never hit); every action is announced
    /// in a notification, the persistent rule log and the Flight Log.
    private func execute(_ f: RuleFiring) {
        let r = f.rule
        let what = f.targets.count > 1 ? "\(f.subject) (\(f.targets.count) processes)" : f.subject
        let measured = "\(r.metric.rawValue) \(String(format: "%.1f", f.value)) for \(r.effectiveMinutes.formatted()) min"
        var result: String
        // Sends `sig` to every target. `ProcessSampler.send` checks PID + start time first, so a recycled PID is refused
        // and counted as failed rather than signalled.
        func signal(_ sig: Int32, _ verb: String) -> String {
            var ok = 0, failed = 0
            for id in f.targets { do { try ProcessSampler.send(sig, to: id); ok += 1 } catch { failed += 1 } }
            return failed == 0 ? "\(verb) \(what)" : "\(verb) \(ok) of \(f.targets.count) processes of \(f.subject) (\(failed) not permitted or gone)"
        }
        // App rules quit through the app itself (NSRunningApplication), like the Dock's Quit: the app gets to ask about
        // unsaved work and close its helpers. Plain processes (and apps that aren't running as an app) get signals.
        let app: NSRunningApplication? = r.target == .app
            ? NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: f.subjectID).standardizedFileURL.path }
            : nil
        let entryID = UUID()
        switch r.action {
        case .notify: result = "Notified"
        case .lowerPriority:
            var ok = 0
            // Same identity check for renice. Only lowering priority (nice 10) is attempted, which needs no privileges for
            // processes the user owns; failures are simply not counted.
            for id in f.targets where ProcessSampler.identity(of: id.pid) == id { if (try? ProcessInspector.setNice(pid: id.pid, 10)) != nil { ok += 1 } }
            result = "Lowered the priority of \(ok) of \(f.targets.count) processes"
        case .suspend:
            result = signal(SIGSTOP, "Suspended")
            // Never leave an app frozen: resume after the rule's time, and on quit (see `resumeAllSuspended`).
            let until = Date().addingTimeInterval(max(r.resumeAfterMinutes, 0.5) * 60)
            suspended += f.targets.map { ($0, until) }
            result += ", resuming in \(max(r.resumeAfterMinutes, 0.5).formatted()) min"
        case .quit:
            if let app { result = app.terminate() ? "Asked \(f.subject) to quit" : "\(f.subject) declined to quit" } else { result = signal(SIGTERM, "Quit") }
        case .forceQuit:
            if let app { result = app.forceTerminate() ? "Force quit \(f.subject)" : "Couldn't force quit \(f.subject)" } else { result = signal(SIGKILL, "Force quit") }
        case .command:
            result = "Running the command…"
            runRuleCommand(r, f, entryID: entryID)
        }
        Alerts.shared.post(title: "Rule “\(r.name)”", body: "\(what): \(measured). \(result).")
        record(RuleLogEntry(id: entryID, time: f.time, rule: r.name, action: r.action.rawValue, subject: f.subject, result: result))
        // Also an (instant) incident in the Flight Log, so automatic actions sit on the same timeline as problems.
        let inc = Incident(id: UUID(), key: "rule:\(r.id)", severity: r.action.isDestructive ? .caution : .info, icon: "bolt.badge.automatic",
                           title: "Rule “\(r.name)”: \(result)", detail: "\(what): \(measured)", destination: "Rules", start: f.time, end: f.time)
        queue.async { [incidentLog] in incidentLog.record(inc) }
    }

    /// Runs a rule's shell command off the main thread with FD_* environment variables, stops it after 60 s, and stores
    /// the start of its output in the rule log.
    private func runRuleCommand(_ r: Rule, _ f: RuleFiring, entryID: UUID) {
        let command = r.command
        var env = ProcessInfo.processInfo.environment
        env["FD_RULE"] = r.name; env["FD_SUBJECT"] = f.subject; env["FD_METRIC"] = r.metric.rawValue
        env["FD_VALUE"] = String(format: "%.2f", f.value); env["FD_PIDS"] = f.targets.map { "\($0.pid)" }.joined(separator: " ")
        Task.detached(priority: .utility) { [weak self] in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", command]; p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            var outcome: String
            do {
                try p.run()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()   // returns when the command (or the kill) ends
                p.waitUntilExit(); killer.cancel()
                let out = String(decoding: data.prefix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                outcome = p.terminationReason == .uncaughtSignal ? "Command stopped after 60 s" : "Command exited \(p.terminationStatus)"
                if !out.isEmpty { outcome += ": " + out }
            } catch { outcome = "Command failed to start: \(error.localizedDescription)" }
            let final = outcome, owner = self   // capture once, outside the concurrent closure
            await MainActor.run { owner?.updateLog(entryID, result: final) }
        }
    }

    // MARK: Rule log (persisted) and suspended processes

    /// Processes a Suspend rule stopped, and when to resume them.
    private var suspended: [(ProcessIdentity, Date)] = []

    /// Resumes suspended processes whose time is up (called every sample) or all of them (`all`, at quit).
    private func resumeSuspended(all: Bool = false) {
        let now = Date()
        for (id, until) in suspended where all || until <= now { try? ProcessSampler.send(SIGCONT, to: id) }
        suspended.removeAll { all || $0.1 <= now }
    }

    static var ruleLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Flightdeck/rule-actions.json")
    }

    private func record(_ e: RuleLogEntry) {
        ruleLog.insert(e, at: 0)
        if ruleLog.count > 200 { ruleLog.removeLast(ruleLog.count - 200) }
        saveRuleLog()
    }

    private func updateLog(_ id: UUID, result: String) {
        guard let i = ruleLog.firstIndex(where: { $0.id == id }) else { return }
        ruleLog[i].result = result
        saveRuleLog()
    }

    private func saveRuleLog() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        guard let d = try? enc.encode(ruleLog) else { return }
        try? FileManager.default.createDirectory(at: Self.ruleLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: Self.ruleLogURL, options: .atomic)
    }

    static func loadRuleLog() -> [RuleLogEntry] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? Data(contentsOf: ruleLogURL)).flatMap { try? dec.decode([RuleLogEntry].self, from: $0) } ?? []
    }

    /// `fresh` are incidents IncidentLog just logged (findings that lasted past its `minDuration`). Only hangs, CPU and
    /// GPU hogs get evidence. At most one capture runs at a time, and each finding key is captured at most once per
    /// 10 minutes. The capture runs on `evidenceQueue`; its result is attached to the incident back on `queue`.
    /// Disabled by the `autoEvidence` default. Set FD_DEBUG_EVIDENCE in the environment to log decisions.
    /// On the sampling queue: when a hang or a sustained CPU/GPU hog is first logged, sample its call stacks.
    nonisolated private func captureEvidence(for fresh: [Incident], findings: [Finding], snapshot s: Snapshot) {
        let debug = ProcessInfo.processInfo.environment["FD_DEBUG_EVIDENCE"] != nil
        if debug && !fresh.isEmpty { NSLog("FDEV fresh=%@ busy=%d", fresh.map(\.key).joined(separator: ","), evidenceBusy ? 1 : 0) }
        guard UserDefaults.standard.object(forKey: "autoEvidence") as? Bool ?? true, !evidenceBusy else { return }
        for inc in fresh where ["hang:", "cpu:", "gpu:"].contains(where: { inc.key.hasPrefix($0) }) {
            if let last = lastEvidence[inc.key], s.time.timeIntervalSince(last) < 600 { continue }
            // Never sample ourselves; and skip if the process has already gone.
            guard let pid = findings.first(where: { $0.id == inc.key })?.pids?.first, pid != getpid(),
                  let p = s.processes.first(where: { $0.pid == pid }) else { continue }
            evidenceBusy = true; lastEvidence[inc.key] = s.time
            let id = inc.id, name = p.name
            evidenceQueue.async { [queue, incidentLog] in
                let r = EvidenceStore.capture(pid: pid, name: name, incident: id)
                if debug { NSLog("FDEV captured pid=%d ok=%d", pid, r == nil ? 0 : 1) }
                queue.async {
                    if let (url, summary) = r { incidentLog.attach(evidence: url.path, summary: summary, to: id) }
                    self.evidenceBusy = false
                }
            }
            // One capture per sample: anything else that's fresh will be considered on a later sample, if still eligible.
            break
        }
    }

    /// Restarts the optional latency probe (router + internet host) with the current settings; blank host means 1.1.1.1.
    private func applyProbe() {
        let p = sampler.probe
        p.stop()
        p.internetHost = netProbeHost.trimmingCharacters(in: .whitespaces).isEmpty ? "1.1.1.1" : netProbeHost
        if netProbeEnabled { p.start() }
    }

    /// Pushes the user's thresholds to the Analyzer on the sampling queue.
    /// Pushes Settings › Alerts › Temperature alerts to the ThermalWatch (called at launch and when they change).
    func applyTemperatureAlerts() {
        thermal.setRules(TemperatureAlertRule.load(UserDefaults.standard.data(forKey: TemperatureAlertRule.defaultsKey)))
    }

    private func applyThresholds() {
        let cpu = appCPUThreshold
        queue.async { [analyzer] in analyzer.thresholds.appCPU = cpu }
    }

    /// Maps a CPU index to performance/efficiency core kind (for per-core graphs).
    /// Demo mode reads the kind from the synthetic snapshot instead, so the core layout isn't this Mac's.
    var cpuKind: (Int) -> CoreKind {
        if Demo.isEnabled { let cores = current?.cpu.cores ?? []; return { $0 < cores.count ? cores[$0].kind : .unknown } }
        return { [sampler] in sampler.cpu.kind(of: $0) }
    }
    /// The processor name shown in panel headers; generic in demo mode so screenshots don't reveal this Mac's chip.
    static var chipName: String? { Demo.isEnabled ? "Apple silicon" : Sysctl.string("machdep.cpu.brand_string") }

    /// The timer always fires at `interval`; when no window is visible `tick()` skips ticks to approximate
    /// `backgroundInterval`. 10% tolerance lets macOS coalesce wakeups for lower energy use.
    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = interval * 0.1
    }

    /// One sampling cycle. Main actor -> `queue` (sample, analyse, log incidents, evaluate rules, capture evidence)
    /// -> main actor (publish findings, alerts, rule actions, incidents, then `ingest`).
    private func tick() {
        guard !paused, !inFlight else { return }
        // Hidden: only sample once `backgroundInterval` has elapsed. The quarter-interval slack stops timer jitter from
        // making us skip an extra tick.
        if !uiVisible, Date().timeIntervalSince(lastTick) < max(backgroundInterval, interval) - interval * 0.25 { return }
        lastTick = Date()
        inFlight = true
        let includeSelf = self.includeSelf
        let visible = uiVisible
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        resumeSuspended()
        queue.async { [sampler, analyzer, incidentLog, ruleEngine, dailyLog] in
            sampler.processes.includeSelf = includeSelf
            sampler.networkInterval = visible ? 0 : 5   // per-process network every 5 s while no window is visible
            sampler.background = !visible
            let s = sampler.sample()
            self.processHistory.record(s.processes)
            self.launchLog.ingest(s.processes, at: s.time)
            // Respawn loops and baseline findings ("3× its usual memory") join the Analyzer's, so they reach the banner,
            // alerts and the Flight Log the same way.
            let found = analyzer.ingest(s) + dailyLog.ingest(s) + self.launchLog.findings(now: s.time) + self.thermal.ingest(s)
                + CameraMicService.findings(now: s.time)   // opt-in camera & mic alerts
                + DestinationService.findings(now: s.time)   // opt-in "new destination" alerts
                + RestartWatch.shared.findings(now: s.time)   // one-shot: unexpected shutdown or panic since last launch
                + ChangeWatch.shared.findings(now: s.time)   // notable changes: unsigned launch agent, new extension or profile…
            self.chargeCurve.ingest(s)
            ruleEngine.frontmostPID = front
            let firings = ruleEngine.evaluate(s)
            let fullDays = analyzer.daysUntilFull()
            let fresh = incidentLog.update(found, at: s.time)
            self.captureEvidence(for: fresh, findings: found, snapshot: s)
            // Persist the incident log at most once a minute (and on quit).
            if s.time.timeIntervalSince(self.lastIncidentSave) > 60 { incidentLog.save(); self.lastIncidentSave = s.time }
            let log: [Incident]? = incidentLog.revision != self.incidentRevision ? incidentLog.incidents : nil
            self.incidentRevision = incidentLog.revision
            Task { @MainActor in
                // publish only real changes (each publish re-evaluates every observing view)
                if found.map(\.signature) != self.liveFindings.map(\.signature) { self.liveFindings = found }
                if fullDays.map({ ($0 * 10).rounded() }) != self.diskFullDays.map({ ($0 * 10).rounded() }) { self.diskFullDays = fullDays }
                Alerts.shared.evaluate(found + self.reportFindings + self.sleepFindings, now: s.time)
                firings.forEach { self.execute($0) }
                if let log { self.incidents = log }
                self.ingest(s)
            }
        }
    }

    /// Used by UIBench (no timers): bypasses the queue, analysis and visibility staging entirely.
    /// Demo mode only: timeline buckets and a sleep history to show instead of reading the black box / power log.
    @Published var demoTimeline: (buckets: [TimelineBucket], range: (Date, Date))?
    /// Demo mode only: marks to show on the timeline instead of reading the marks file.
    @Published var demoMarks: [Mark]?
    @Published var demoSleep: SleepReport?

    /// Headless only: show the given state (for demo screenshots). Nothing is persisted.
    func demoInject(incidents: [Incident], reports: [DiagnosticReport], rules: [Rule], ruleLog: [RuleLogEntry]) {
        guard headless else { return }
        self.incidents = incidents; self.reports = reports; self.rules = rules; self.ruleLog = ruleLog
    }

    /// Headless: push a snapshot (with its findings) as if it had just been sampled.
    func feed(_ s: Snapshot, findings: [Finding]) {
        processHistory.record(s.processes)
        launchLog.ingest(s.processes, at: s.time)
        chargeCurve.ingest(s)
        liveFindings = findings + thermal.ingest(s); liveSnapshot = s; current = s
        var light = s; light.processes = Array(s.processes.sorted { $0.cpu > $1.cpu }.prefix(12))
        frames.removeFirst(); frames.append(light)
    }

    // MARK: Visibility
    /// Whether any FlightDeck window (main, inspector, compare, menu bar panel) is on screen. While none is,
    /// sampling, the black box and alerts continue at full rate, but view-facing state is staged instead of
    /// published, so SwiftUI isn't re-evaluating views nobody can see.
    private(set) var uiVisible = true
    private var hiddenFrames: [Snapshot?]?
    private var hiddenCurrent: Snapshot?
    private var lastHiddenLivePublish = Date.distantPast
    /// Registers window/app notifications that can change visibility. Called once from `init`.

    func startVisibilityTracking() {
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
                                          NSApplication.didHideNotification, NSApplication.didUnhideNotification]
        for n in names {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                // re-check a moment later: e.g. willClose fires while the window is still on screen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self?.updateVisibility() } }
            }
        }
    }

    /// Recomputes `uiVisible`. On hide, the current live history is copied into the staging vars; on show, staged
    /// history is published in one go. Set FD_DEBUG_VISIBILITY to log each window's state.
    private func updateVisibility() {
        let visible = !NSApp.isHidden && NSApp.windows.contains { w in
            w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
                && !String(describing: type(of: w)).contains("StatusBar")   // the menu bar item itself is always "visible"
        }
        if ProcessInfo.processInfo.environment["FD_DEBUG_VISIBILITY"] != nil {
            NSLog("FDVIS visible=%d %@", visible ? 1 : 0, NSApp.windows.map { "\(type(of: $0)) v=\($0.isVisible) m=\($0.isMiniaturized) o=\($0.occlusionState.contains(.visible))" }.joined(separator: "; "))
        }
        guard visible != uiVisible else { return }
        uiVisible = visible
        if visible {   // catch up in one publish, so graphs have no hole
            // …but only in live mode: a replay started while hidden owns `frames`/`current` and must not be overwritten.
            if mode == .live {
                if let f = hiddenFrames { frames = f }
                if let c = hiddenCurrent { current = c }
            }
            hiddenFrames = nil; hiddenCurrent = nil
        } else if mode == .live {
            hiddenFrames = frames; hiddenCurrent = current
        }
    }

    /// Main actor, at the end of each tick: record, black box, Dock tile, then publish (or stage, if hidden).
    private func ingest(_ s: Snapshot) {
        inFlight = false
        if recording { recorded.append(FlightDeckCore.Trace.trimmed(s)) }
        if blackBoxEnabled { let iv = interval; blackBoxQueue.async { [blackBox] in blackBox.append(s, interval: iv) } }
        DockIconController.shared.ingest(s, recording: recording, caution: unmutedLiveFindings.map(\.severity.rawValue).max() ?? 0)
        var light = s; light.processes = Array(s.processes.sorted { $0.cpu > $1.cpu }.prefix(12))
        if !uiVisible {
            // menu bar strip still updates, just less often
            // In replay, live samples only reach `liveSnapshot`; `frames`/`current` belong to the trace.
            if s.time.timeIntervalSince(lastHiddenLivePublish) >= 5 { liveSnapshot = s; lastHiddenLivePublish = s.time }
            guard mode == .live else { return }
            markGapIfNeeded(s.time)
            appendFrame(light); hiddenCurrent = s
            return
        }
        liveSnapshot = s
        guard mode == .live else { return }
        markGapIfNeeded(s.time)
        current = s
        appendFrame(light)
    }

    /// Time of the last live frame added to graph history, to detect sleep and other stalls.
    private var lastFrameTime: Date?

    /// The Mac slept (or sampling stalled): break the line instead of joining across hours of missing data.
    /// The threshold allows for the slower background interval.
    private func markGapIfNeeded(_ t: Date) {
        defer { lastFrameTime = t }
        guard let last = lastFrameTime, t.timeIntervalSince(last) > max(interval, backgroundInterval) * 2.5 + 1 else { return }
        appendFrame(nil)
    }

    /// Appends to whichever live history is current: the staged one while no window is visible, else the published one.
    private func appendFrame(_ f: Snapshot?) {
        if !uiVisible {
            if hiddenFrames == nil { hiddenFrames = frames }
            hiddenFrames!.removeFirst(); hiddenFrames!.append(f)
        } else {
            frames.removeFirst(); frames.append(f)
        }
    }

    /// Inserts a gap marker (after a pause) into graph history, per-process history and the Dock tile graph.
    private func pushGap() {
        processHistory.gap()
        DockIconController.shared.gap()
        if mode == .live { appendFrame(nil) }   // staged history too, so a pause while hidden still shows as a gap
    }


    // MARK: series helpers
    /// One value per frame of `frames`; `nil` where the frame is a gap or the metric is unavailable.
    func series(_ f: (Snapshot) -> Double?) -> [Double?] { frames.map { $0.flatMap(f) } }

    /// Per-second rate of a cumulative counter between consecutive frames (nil across gaps or resets).
    /// A decrease (counter reset, e.g. an interface coming back up) yields nil, not a negative rate. Element 0 is always nil.
    func rateSeries(_ f: (Snapshot) -> Double?) -> [Double?] {
        var out: [Double?] = [nil]
        for i in 1..<max(frames.count, 1) {
            guard let a = frames[i - 1], let b = frames[i], let x = f(a), let y = f(b), y >= x else { out.append(nil); continue }
            let dt = b.time.timeIntervalSince(a.time)
            out.append(dt > 0 ? (y - x) / dt : nil)
        }
        return out
    }

    // MARK: Flight Recorder
    /// Starts a fresh user recording (in memory until saved).
    func startRecording() { recorded = []; recording = true }
    /// Stops recording and immediately offers to save it.
    func stopRecording() { recording = false; saveRecording() }

    func saveRecording() {
        guard !recorded.isEmpty else { return }
        save(FlightDeckCore.Trace(host: Demo.isEnabled ? "Demo Mac" : Host.current().localizedName ?? "Mac", model: Demo.isEnabled ? "" : Sysctl.string("hw.model") ?? "",
                                  interval: interval, frames: recorded), prefix: "Recording")
    }

    // MARK: Black box
    /// Saves the last `minutes` of the black box (full resolution up to an hour, 10 s resolution beyond).
    /// Shows a save panel (modal, main actor).
    func saveBlackBox(minutes: Int) {
        Task {
            guard let t = await blackBoxTrace(minutes: minutes) else { return }
            save(t, prefix: "Black Box \(minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m")")
        }
    }

    /// Loads the last `minutes` of the black box into replay, positioned at the most recent frame.
    func replayBlackBox(minutes: Int) {
        Task { if let t = await blackBoxTrace(minutes: minutes) { load(t, startAtEnd: true) } }
    }

    /// Reads (and decompresses) black-box segments on the black box's own queue, never the main thread, so loading 24 h
    /// doesn't freeze the UI; the queue also means pending writes are included.
    func readBlackBox(_ tier: BlackBox.Tier, from: Date, to: Date = Date()) async -> FlightDeckCore.Trace? {
        await withCheckedContinuation { c in
            blackBoxQueue.async { [blackBox] in c.resume(returning: blackBox.trace(tier, from: from, to: to)) }
        }
    }

    /// The fine tier is used when it covers the whole range. Returns nil and sets `lastError` when there's nothing to show.
    private func blackBoxTrace(minutes: Int) async -> FlightDeckCore.Trace? {
        let from = Date().addingTimeInterval(-Double(minutes) * 60)
        let tier: BlackBox.Tier = Double(minutes) * 60 <= blackBox.config.fineRetention ? .fine : .coarse
        let t = await readBlackBox(tier, from: from)
        if t == nil { lastError = blackBoxEnabled ? "The black box has no data for the last \(minutes) minutes yet." : "The black box is turned off (Settings)." }
        return t
    }

    /// Replays the black box around a moment (e.g. an incident), with 2 minutes of context either side.
    /// Positions replay at `start`.
    func replayBlackBox(from start: Date, to end: Date) {
        let from = start.addingTimeInterval(-120), to = end.addingTimeInterval(120)
        let tier: BlackBox.Tier = Date().timeIntervalSince(from) <= blackBox.config.fineRetention ? .fine : .coarse
        Task {
            guard let t = await readBlackBox(tier, from: from, to: to) else {
                lastError = "The black box no longer has data for that time (it keeps 1 hour in full detail and 24 hours in 10 s steps)."
                return
            }
            load(t, startAt: start)
        }
    }

    /// Clears the persisted incident log on the queue and the published copy immediately.
    func clearIncidents() { queue.async { [incidentLog] in incidentLog.clear() } ; incidents = [] }

    func clearBlackBox() { blackBoxQueue.async { [blackBox] in blackBox.clear() } }

    /// Asks where to save a trace (modal save panel), naming it "<prefix> <date>".
    private func save(_ t: FlightDeckCore.Trace, prefix: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: FlightDeckCore.Trace.fileExtension) ?? .data]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "\(prefix) \(df.string(from: Date())).\(FlightDeckCore.Trace.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            do { try t.write(to: url); NSDocumentController.shared.noteNewRecentDocumentURL(url) }
            catch { lastError = error.localizedDescription }
        }
    }

    /// Open panel for `.flightlog` traces (and the legacy `.mltrace` extension from before the rename).
    func openTrace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ([FlightDeckCore.Trace.fileExtension] + FlightDeckCore.Trace.legacyFileExtensions)
            .compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        do { load(try FlightDeckCore.Trace.read(from: url)) } catch { lastError = "Could not open trace: \(error.localizedDescription)" }
    }

    /// Stops the current recording and replays it without saving first.
    func replayRecorded() {
        guard !recorded.isEmpty else { return }
        recording = false
        load(FlightDeckCore.Trace(host: Host.current().localizedName ?? "", model: "", interval: interval, frames: recorded))
    }

    /// Enters replay mode with `t`. Start position: the end (`startAtEnd`), the first frame at or after `startAt`, or the
    /// `replayIndex` user default (for automation/screenshots, 0 by default).
    private func load(_ t: FlightDeckCore.Trace, startAtEnd: Bool = false, startAt: Date? = nil) {
        guard !t.frames.isEmpty else { lastError = "Trace is empty"; return }
        playing = false; playTimer?.invalidate()
        trace = t; mode = .replay
        analyzeReplay(t)
        let start = startAtEnd ? t.frames.count - 1
            : startAt.map { d in t.frames.firstIndex { $0.time >= d } ?? 0 }
            ?? UserDefaults.standard.integer(forKey: "replayIndex")   // debug/automation hook
        // `mode` is already .replay here, so assigning replayIndex runs applyReplay through its didSet.
        replayIndex = min(max(start, 0), t.frames.count - 1)
    }

    /// Back to live. History is cleared (not restored), so graphs start filling again from the next sample.
    func exitReplay() {
        playing = false; playTimer?.invalidate(); trace = nil; mode = .live
        frames = Array(repeating: nil, count: Self.historyLength); current = nil
    }

    /// Plays the trace at twice its recorded speed; wraps to the start if already at the end, stops at the last frame.
    func togglePlay() {
        playing.toggle(); playTimer?.invalidate()
        guard playing, let t = trace else { return }
        if replayIndex >= t.frames.count - 1 { replayIndex = 0 }
        playTimer = Timer.scheduledTimer(withTimeInterval: max(t.interval, 0.1) / 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let t = self.trace else { return }
                if self.replayIndex < t.frames.count - 1 { self.replayIndex += 1 } else { self.togglePlay() }
            }
        }
    }

    /// Rebuilds `frames` as the `historyLength` frames ending at `replayIndex`, inserting `nil` wherever the recording has a
    /// hole longer than 2.5 intervals (so a gap in the trace looks like a gap in live graphs).
    private func applyReplay() {
        guard let t = trace, !t.frames.isEmpty else { return }
        let idx = min(max(replayIndex, 0), t.frames.count - 1)
        let start = max(0, idx - Self.historyLength + 1)
        var window: [Snapshot?] = []
        var prev: Date?
        for f in t.frames[start...idx] {
            if let prev, f.time.timeIntervalSince(prev) > t.interval * 2.5 { window.append(nil) }   // recorded gap
            window.append(f); prev = f.time
        }
        window = Array(window.suffix(Self.historyLength))
        frames = Array(repeating: nil, count: Self.historyLength - window.count) + window
        current = t.frames[idx]
        // Findings as they were at this moment: a lookup into the per-frame analysis done once in the background.
        replayFindings = replayTimeline.flatMap { idx < $0.count ? $0[idx] : nil } ?? []
    }

    // MARK: Replay analysis
    /// Findings for every frame of the loaded trace (nil while the background pass runs).
    private var replayTimeline: [[Finding]]?
    /// True while the loaded trace is being analysed (the replay bar can say so).
    @Published private(set) var replayAnalyzing = false
    /// Bumped on every load, so a slow pass for a previous trace can't overwrite the current one.
    private var replayGeneration = 0

    /// Runs the Analyzer over the whole trace once, off the main actor, recording what it found at each frame. Scrubbing
    /// is then a lookup instead of re-analysing hundreds of frames per step. The trace is its own baseline (if it covers
    /// ≥ 30 minutes), so "unusual for this Mac" findings also appear in replay.
    private func analyzeReplay(_ t: FlightDeckCore.Trace) {
        replayGeneration += 1
        let gen = replayGeneration, frames = t.frames
        replayTimeline = nil; replayAnalyzing = true; replayFindings = []
        Task {
            let timeline = await Task.detached(priority: .userInitiated) { () -> [[Finding]] in
                let a = Analyzer(); a.seed(history: frames)
                return frames.map { a.ingest($0) }
            }.value
            guard gen == self.replayGeneration else { return }
            self.replayTimeline = timeline; self.replayAnalyzing = false
            if self.mode == .replay { self.applyReplay() }
        }
    }
}
