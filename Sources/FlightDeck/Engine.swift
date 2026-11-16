import SwiftUI
import FlightDeckCore
import UniformTypeIdentifiers

enum Mode: Equatable { case live, replay }

/// Owns sampling, history, and the Flight Recorder. Views read `frames` (history, `nil` = gap)
/// and `current`; in replay mode both come from the loaded trace, so every view replays for free.
@MainActor
final class Engine: ObservableObject {
    static let historyLength = 120

    @Published private(set) var current: Snapshot?
    /// Always the latest live sample, even while replaying (menu bar, Dock, alerts).
    @Published private(set) var liveSnapshot: Snapshot?
    @Published private(set) var frames: [Snapshot?] = Array(repeating: nil, count: Engine.historyLength)
    @Published var paused = false { didSet { if !paused { pushGap() } else { queue.async { [incidentLog] in incidentLog.closeAll(at: Date()) } } } }
    @AppStorage("interval") var interval: Double = 1.0 { didSet { restartTimer() } }
    @AppStorage("includeSelf") var includeSelf = true
    /// Sample interval while no FlightDeck window is visible (menu bar / background only).
    @AppStorage("backgroundInterval") var backgroundInterval: Double = 2.0
    private var lastTick = Date.distantPast
    @AppStorage("blackBoxEnabled") var blackBoxEnabled = true
    @AppStorage("appCPUThreshold") var appCPUThreshold = 80.0 { didSet { applyThresholds() } }
    /// Opt-in: pings the router and `netProbeHost` every 10 s. Off by default (privacy).
    @AppStorage("netProbeEnabled") var netProbeEnabled = false { didSet { applyProbe() } }
    @AppStorage("netProbeHost") var netProbeHost = "1.1.1.1" { didSet { applyProbe() } }

    // Flight Recorder
    @Published private(set) var mode: Mode = .live
    @Published private(set) var recording = false
    @Published private(set) var recorded: [Snapshot] = []
    @Published var trace: FlightDeckCore.Trace?
    @Published var replayIndex = 0 { didSet { if mode == .replay { applyReplay() } } }
    @Published var playing = false
    @Published var lastError: String?

    // Analysis: findings (live, or recomputed for the replayed moment) and the incident log
    @Published private(set) var liveFindings: [Finding] = []
    @Published private(set) var replayFindings: [Finding] = []
    @Published private(set) var incidents: [Incident] = []
    /// Days until the startup disk fills at the current trend (nil = no clear shrinking trend).
    @Published private(set) var diskFullDays: Double?
    var findings: [Finding] { mode == .live ? liveFindings + reportFindings : replayFindings }
    /// macOS diagnostic reports from the last 7 days (rescanned every 5 minutes).
    @Published private(set) var reports: [DiagnosticReport] = []
    @Published private(set) var reportFindings: [Finding] = []

    // Rules: user automations evaluated on every sample.
    @Published var rules: [Rule] = RuleEngine.load(UserDefaults.standard.data(forKey: "rules")) {
        didSet { UserDefaults.standard.set(RuleEngine.save(rules), forKey: "rules"); let r = rules; queue.async { [ruleEngine] in ruleEngine.rules = r } }
    }
    struct RuleLogEntry: Identifiable { let id = UUID(); var firing: RuleFiring; var result: String }
    @Published private(set) var ruleLog: [RuleLogEntry] = []
    /// Set to a Destination raw value (optionally "Performance:<tab>") to navigate there.
    @Published var navigationRequest: String?
    /// Called on the main actor for each incident once it has lasted long enough to log.
    var onNewIncident: ((Incident) -> Void)?

    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "flightdeck.sampler", qos: .utility)
    private var timer: Timer?
    private var playTimer: Timer?
    private var inFlight = false

    // Black box: always-on rolling recorder, written off the sampling queue.
    let blackBox = BlackBox(dir: BlackBox.defaultDirectory)
    /// Recent history of every process (for the inspector).
    let processHistory = ProcessHistory()
    private let blackBoxQueue = DispatchQueue(label: "flightdeck.blackbox", qos: .background)
    // Confined to `queue`.
    nonisolated private let analyzer = Analyzer()
    nonisolated private let ruleEngine = RuleEngine()
    nonisolated private let incidentLog = IncidentLog(url: IncidentLog.defaultURL)
    nonisolated(unsafe) private var incidentRevision = -1
    nonisolated(unsafe) private var lastIncidentSave = Date()
    // Evidence capture (confined to `queue`): one capture at a time, at most one per finding every 10 minutes.
    nonisolated(unsafe) private var evidenceBusy = false
    nonisolated(unsafe) private var lastEvidence: [String: Date] = [:]
    private let evidenceQueue = DispatchQueue(label: "flightdeck.evidence", qos: .utility)

    /// `headless`: no timers, no black box, no Dock tile; frames are fed with `feed(_:)` (UI benchmark).
    let headless: Bool

    init(headless: Bool = false) {
        self.headless = headless
        if headless { return }
        queue.async { [sampler] in _ = sampler.sample() }   // prime deltas
        restartTimer()
        blackBoxQueue.async { [blackBox, queue, analyzer] in
            blackBox.prune(); EvidenceStore.prune()
            let history = blackBox.trace(.coarse, from: Date().addingTimeInterval(-86_400))?.frames ?? []
            queue.async { analyzer.seed(history: history) }
        }
        incidents = incidentLog.incidents
        Task { [weak self] in
            while !Task.isCancelled {
                let r = await Task.detached(priority: .utility) { DiagnosticReports.scan(since: Date().addingTimeInterval(-7 * 86_400)) }.value
                self?.reports = r; self?.reportFindings = DiagnosticReports.findings(r)
                try? await Task.sleep(for: .seconds(300))
            }
        }
        applyThresholds()
        applyProbe()
        let r = rules; queue.async { [ruleEngine] in ruleEngine.rules = r }
        startVisibilityTracking()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [blackBox, blackBoxQueue, queue, incidentLog] _ in
            blackBoxQueue.sync { blackBox.flush() }
            queue.sync { incidentLog.closeAll(at: Date()); incidentLog.save() }
        }
    }

    /// Carries out a rule's action. Signals are identity-checked (a recycled PID is never hit); every action is announced.
    private func execute(_ f: RuleFiring) {
        let r = f.rule
        let what = f.targets.count > 1 ? "\(f.subject) (\(f.targets.count) processes)" : f.subject
        let measured = "\(r.metric.rawValue) \(String(format: "%.1f", f.value)) for \(r.minutes.formatted()) min"
        var result: String
        func signal(_ sig: Int32, _ verb: String) -> String {
            var ok = 0, failed = 0
            for id in f.targets { do { try ProcessSampler.send(sig, to: id); ok += 1 } catch { failed += 1 } }
            return failed == 0 ? "\(verb) \(what)" : "\(verb) \(ok) of \(f.targets.count) processes of \(f.subject) (\(failed) not permitted or gone)"
        }
        switch r.action {
        case .notify: result = "Notified"
        case .lowerPriority:
            var ok = 0
            for id in f.targets where ProcessSampler.identity(of: id.pid) == id { if (try? ProcessInspector.setNice(pid: id.pid, 10)) != nil { ok += 1 } }
            result = "Lowered the priority of \(ok) of \(f.targets.count) processes"
        case .suspend: result = signal(SIGSTOP, "Suspended")
        case .quit: result = signal(SIGTERM, "Quit")
        case .forceQuit: result = signal(SIGKILL, "Force quit")
        case .command:
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", r.command]
            var env = ProcessInfo.processInfo.environment
            env["FD_RULE"] = r.name; env["FD_SUBJECT"] = f.subject; env["FD_METRIC"] = r.metric.rawValue
            env["FD_VALUE"] = String(format: "%.2f", f.value); env["FD_PIDS"] = f.targets.map { "\($0.pid)" }.joined(separator: " ")
            p.environment = env
            do { try p.run(); result = "Ran the command (pid \(p.processIdentifier))" } catch { result = "Command failed: \(error.localizedDescription)" }
        }
        Alerts.shared.post(title: "Rule “\(r.name)”", body: "\(what): \(measured). \(result).")
        ruleLog.insert(RuleLogEntry(firing: f, result: result), at: 0)
        if ruleLog.count > 100 { ruleLog.removeLast(ruleLog.count - 100) }
    }

    /// On the sampling queue: when a hang or a sustained CPU/GPU hog is first logged, sample its call stacks.
    nonisolated private func captureEvidence(for fresh: [Incident], findings: [Finding], snapshot s: Snapshot) {
        let debug = ProcessInfo.processInfo.environment["FD_DEBUG_EVIDENCE"] != nil
        if debug && !fresh.isEmpty { NSLog("FDEV fresh=%@ busy=%d", fresh.map(\.key).joined(separator: ","), evidenceBusy ? 1 : 0) }
        guard UserDefaults.standard.object(forKey: "autoEvidence") as? Bool ?? true, !evidenceBusy else { return }
        for inc in fresh where ["hang:", "cpu:", "gpu:"].contains(where: { inc.key.hasPrefix($0) }) {
            if let last = lastEvidence[inc.key], s.time.timeIntervalSince(last) < 600 { continue }
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
            break
        }
    }

    private func applyProbe() {
        let p = sampler.probe
        p.stop()
        p.internetHost = netProbeHost.trimmingCharacters(in: .whitespaces).isEmpty ? "1.1.1.1" : netProbeHost
        if netProbeEnabled { p.start() }
    }

    private func applyThresholds() {
        let cpu = appCPUThreshold
        queue.async { [analyzer] in analyzer.thresholds.appCPU = cpu }
    }

    var cpuKind: (Int) -> CoreKind { { [sampler] in sampler.cpu.kind(of: $0) } }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = interval * 0.1
    }

    private func tick() {
        guard !paused, !inFlight else { return }
        if !uiVisible, Date().timeIntervalSince(lastTick) < max(backgroundInterval, interval) - interval * 0.25 { return }
        lastTick = Date()
        inFlight = true
        let includeSelf = self.includeSelf
        queue.async { [sampler, analyzer, incidentLog, ruleEngine] in
            sampler.processes.includeSelf = includeSelf
            let s = sampler.sample()
            self.processHistory.record(s.processes)
            let found = analyzer.ingest(s)
            let firings = ruleEngine.evaluate(s)
            let fullDays = analyzer.daysUntilFull()
            let fresh = incidentLog.update(found, at: s.time)
            self.captureEvidence(for: fresh, findings: found, snapshot: s)
            if s.time.timeIntervalSince(self.lastIncidentSave) > 60 { incidentLog.save(); self.lastIncidentSave = s.time }
            let log: [Incident]? = incidentLog.revision != self.incidentRevision ? incidentLog.incidents : nil
            self.incidentRevision = incidentLog.revision
            Task { @MainActor in
                // publish only real changes (each publish re-evaluates every observing view)
                if found.map(\.signature) != self.liveFindings.map(\.signature) { self.liveFindings = found }
                if fullDays.map({ ($0 * 10).rounded() }) != self.diskFullDays.map({ ($0 * 10).rounded() }) { self.diskFullDays = fullDays }
                Alerts.shared.evaluate(found + self.reportFindings, now: s.time)
                firings.forEach { self.execute($0) }
                if let log { self.incidents = log }
                fresh.forEach { self.onNewIncident?($0) }
                self.ingest(s)
            }
        }
    }

    /// Headless: push a snapshot (with its findings) as if it had just been sampled.
    func feed(_ s: Snapshot, findings: [Finding]) {
        processHistory.record(s.processes)
        liveFindings = findings; liveSnapshot = s; current = s
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
            if let f = hiddenFrames { frames = f }
            if let c = hiddenCurrent { current = c }
            hiddenFrames = nil; hiddenCurrent = nil
        } else if mode == .live {
            hiddenFrames = frames; hiddenCurrent = current
        }
    }

    private func ingest(_ s: Snapshot) {
        inFlight = false
        if recording { recorded.append(FlightDeckCore.Trace.trimmed(s)) }
        if blackBoxEnabled { let iv = interval; blackBoxQueue.async { [blackBox] in blackBox.append(s, interval: iv) } }
        DockIconController.shared.ingest(s, recording: recording, caution: liveFindings.map(\.severity.rawValue).max() ?? 0)
        var light = s; light.processes = Array(s.processes.sorted { $0.cpu > $1.cpu }.prefix(12))
        if !uiVisible {
            // menu bar strip still updates, just less often
            if s.time.timeIntervalSince(lastHiddenLivePublish) >= 5 { liveSnapshot = s; lastHiddenLivePublish = s.time }
            guard mode == .live else { return }
            if hiddenFrames == nil { hiddenFrames = frames }
            hiddenFrames!.removeFirst(); hiddenFrames!.append(light); hiddenCurrent = s
            return
        }
        liveSnapshot = s
        guard mode == .live else { return }
        current = s
        frames.removeFirst(); frames.append(light)
    }

    private func pushGap() {
        processHistory.gap()
        DockIconController.shared.gap()
        if mode == .live { frames.removeFirst(); frames.append(nil) }
    }

    func sampleNow() { let p = paused; paused = false; tick(); paused = p }

    // MARK: series helpers
    func series(_ f: (Snapshot) -> Double?) -> [Double?] { frames.map { $0.flatMap(f) } }

    /// Per-second rate of a cumulative counter between consecutive frames (nil across gaps or resets).
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
    func startRecording() { recorded = []; recording = true }
    func stopRecording() { recording = false; saveRecording() }

    func saveRecording() {
        guard !recorded.isEmpty else { return }
        save(FlightDeckCore.Trace(host: Host.current().localizedName ?? "Mac", model: Sysctl.string("hw.model") ?? "",
                                  interval: interval, frames: recorded), prefix: "Recording")
    }

    // MARK: Black box
    /// Saves the last `minutes` of the black box (full resolution up to an hour, 10 s resolution beyond).
    func saveBlackBox(minutes: Int) {
        guard let t = blackBoxTrace(minutes: minutes) else { return }
        save(t, prefix: "Black Box \(minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m")")
    }

    func replayBlackBox(minutes: Int) {
        guard let t = blackBoxTrace(minutes: minutes) else { return }
        load(t, startAtEnd: true)
    }

    private func blackBoxTrace(minutes: Int) -> FlightDeckCore.Trace? {
        let from = Date().addingTimeInterval(-Double(minutes) * 60)
        let tier: BlackBox.Tier = Double(minutes) * 60 <= blackBox.config.fineRetention ? .fine : .coarse
        let t = blackBoxQueue.sync { blackBox.trace(tier, from: from) }
        if t == nil { lastError = blackBoxEnabled ? "The black box has no data for the last \(minutes) minutes yet." : "The black box is turned off (Settings)." }
        return t
    }

    /// Replays the black box around a moment (e.g. an incident), with some context either side.
    func replayBlackBox(from start: Date, to end: Date) {
        let from = start.addingTimeInterval(-120), to = end.addingTimeInterval(120)
        let tier: BlackBox.Tier = Date().timeIntervalSince(from) <= blackBox.config.fineRetention ? .fine : .coarse
        guard let t = blackBoxQueue.sync(execute: { blackBox.trace(tier, from: from, to: to) }) else {
            lastError = "The black box no longer has data for that time (it keeps 1 hour in full detail and 24 hours in 10 s steps)."
            return
        }
        load(t, startAt: start)
    }

    func clearIncidents() { queue.async { [incidentLog] in incidentLog.clear() } ; incidents = [] }

    func clearBlackBox() { blackBoxQueue.async { [blackBox] in blackBox.clear() } }

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

    func openTrace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ([FlightDeckCore.Trace.fileExtension] + FlightDeckCore.Trace.legacyFileExtensions)
            .compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        do { load(try FlightDeckCore.Trace.read(from: url)) } catch { lastError = "Could not open trace: \(error.localizedDescription)" }
    }

    func replayRecorded() {
        guard !recorded.isEmpty else { return }
        recording = false
        load(FlightDeckCore.Trace(host: Host.current().localizedName ?? "", model: "", interval: interval, frames: recorded))
    }

    private func load(_ t: FlightDeckCore.Trace, startAtEnd: Bool = false, startAt: Date? = nil) {
        guard !t.frames.isEmpty else { lastError = "Trace is empty"; return }
        playing = false; playTimer?.invalidate()
        trace = t; mode = .replay
        let start = startAtEnd ? t.frames.count - 1
            : startAt.map { d in t.frames.firstIndex { $0.time >= d } ?? 0 }
            ?? UserDefaults.standard.integer(forKey: "replayIndex")   // debug/automation hook
        replayIndex = min(max(start, 0), t.frames.count - 1); applyReplay()
    }

    func exitReplay() {
        playing = false; playTimer?.invalidate(); trace = nil; mode = .live
        frames = Array(repeating: nil, count: Self.historyLength); current = nil
    }

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
        // Recompute findings as they would have looked at this moment.
        let a = Analyzer()
        for f in t.frames[max(0, idx - 900)...idx] { a.ingest(f) }
        replayFindings = a.findings
    }
}
