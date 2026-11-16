import SwiftUI
import FlightdeckCore
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
    @AppStorage("blackBoxEnabled") var blackBoxEnabled = true
    @AppStorage("appCPUThreshold") var appCPUThreshold = 80.0 { didSet { applyThresholds() } }
    /// Opt-in: pings the router and `netProbeHost` every 10 s. Off by default (privacy).
    @AppStorage("netProbeEnabled") var netProbeEnabled = false { didSet { applyProbe() } }
    @AppStorage("netProbeHost") var netProbeHost = "1.1.1.1" { didSet { applyProbe() } }

    // Flight Recorder
    @Published private(set) var mode: Mode = .live
    @Published private(set) var recording = false
    @Published private(set) var recorded: [Snapshot] = []
    @Published var trace: FlightdeckCore.Trace?
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
    nonisolated private let incidentLog = IncidentLog(url: IncidentLog.defaultURL)
    nonisolated(unsafe) private var incidentRevision = -1
    nonisolated(unsafe) private var lastIncidentSave = Date()

    /// `headless`: no timers, no black box, no Dock tile; frames are fed with `feed(_:)` (UI benchmark).
    let headless: Bool

    init(headless: Bool = false) {
        self.headless = headless
        if headless { return }
        queue.async { [sampler] in _ = sampler.sample() }   // prime deltas
        restartTimer()
        blackBoxQueue.async { [blackBox, queue, analyzer] in
            blackBox.prune()
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
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [blackBox, blackBoxQueue, queue, incidentLog] _ in
            blackBoxQueue.sync { blackBox.flush() }
            queue.sync { incidentLog.closeAll(at: Date()); incidentLog.save() }
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
        inFlight = true
        let includeSelf = self.includeSelf
        queue.async { [sampler, analyzer, incidentLog] in
            sampler.processes.includeSelf = includeSelf
            let s = sampler.sample()
            self.processHistory.record(s.processes)
            let found = analyzer.ingest(s)
            let fullDays = analyzer.daysUntilFull()
            let fresh = incidentLog.update(found, at: s.time)
            if s.time.timeIntervalSince(self.lastIncidentSave) > 60 { incidentLog.save(); self.lastIncidentSave = s.time }
            let log: [Incident]? = incidentLog.revision != self.incidentRevision ? incidentLog.incidents : nil
            self.incidentRevision = incidentLog.revision
            Task { @MainActor in
                self.liveFindings = found
                self.diskFullDays = fullDays
                Alerts.shared.evaluate(found + self.reportFindings, now: s.time)
                if let log { self.incidents = log }
                fresh.forEach { self.onNewIncident?($0) }
                self.ingest(s)
            }
        }
    }

    /// Headless: push a snapshot (with its findings) as if it had just been sampled.
    func feed(_ s: Snapshot, findings: [Finding]) {
        liveFindings = findings; liveSnapshot = s; current = s
        var light = s; light.processes = Array(s.processes.sorted { $0.cpu > $1.cpu }.prefix(12))
        frames.removeFirst(); frames.append(light)
    }

    private func ingest(_ s: Snapshot) {
        inFlight = false
        liveSnapshot = s
        if recording { recorded.append(FlightdeckCore.Trace.trimmed(s)) }
        if blackBoxEnabled { let iv = interval; blackBoxQueue.async { [blackBox] in blackBox.append(s, interval: iv) } }
        DockIconController.shared.ingest(s, recording: recording, caution: liveFindings.map(\.severity.rawValue).max() ?? 0)
        guard mode == .live else { return }
        current = s
        var light = s; light.processes = Array(s.processes.sorted { $0.cpu > $1.cpu }.prefix(12))
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
        save(FlightdeckCore.Trace(host: Host.current().localizedName ?? "Mac", model: Sysctl.string("hw.model") ?? "",
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

    private func blackBoxTrace(minutes: Int) -> FlightdeckCore.Trace? {
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

    private func save(_ t: FlightdeckCore.Trace, prefix: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: FlightdeckCore.Trace.fileExtension) ?? .data]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "\(prefix) \(df.string(from: Date())).\(FlightdeckCore.Trace.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            do { try t.write(to: url); NSDocumentController.shared.noteNewRecentDocumentURL(url) }
            catch { lastError = error.localizedDescription }
        }
    }

    func openTrace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ([FlightdeckCore.Trace.fileExtension] + FlightdeckCore.Trace.legacyFileExtensions)
            .compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        do { load(try FlightdeckCore.Trace.read(from: url)) } catch { lastError = "Could not open trace: \(error.localizedDescription)" }
    }

    func replayRecorded() {
        guard !recorded.isEmpty else { return }
        recording = false
        load(FlightdeckCore.Trace(host: Host.current().localizedName ?? "", model: "", interval: interval, frames: recorded))
    }

    private func load(_ t: FlightdeckCore.Trace, startAtEnd: Bool = false, startAt: Date? = nil) {
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
