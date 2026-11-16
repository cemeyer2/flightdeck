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
    @Published private(set) var frames: [Snapshot?] = Array(repeating: nil, count: Engine.historyLength)
    @Published var paused = false { didSet { if !paused { pushGap() } } }
    @AppStorage("interval") var interval: Double = 1.0 { didSet { restartTimer() } }
    @AppStorage("includeSelf") var includeSelf = true

    // Flight Recorder
    @Published private(set) var mode: Mode = .live
    @Published private(set) var recording = false
    @Published private(set) var recorded: [Snapshot] = []
    @Published var trace: FlightdeckCore.Trace?
    @Published var replayIndex = 0 { didSet { if mode == .replay { applyReplay() } } }
    @Published var playing = false
    @Published var lastError: String?

    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "flightdeck.sampler", qos: .utility)
    private var timer: Timer?
    private var playTimer: Timer?
    private var inFlight = false

    init() {
        queue.async { [sampler] in _ = sampler.sample() }   // prime deltas
        restartTimer()
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
        queue.async { [sampler] in
            sampler.processes.includeSelf = includeSelf
            let s = sampler.sample()
            Task { @MainActor in self.ingest(s) }
        }
    }

    private func ingest(_ s: Snapshot) {
        inFlight = false
        if recording { recorded.append(FlightdeckCore.Trace.trimmed(s)) }
        DockIconController.shared.ingest(s, recording: recording)
        guard mode == .live else { return }
        current = s
        var light = s; light.processes = Array(s.processes.sorted { $0.cpu > $1.cpu }.prefix(12))
        frames.removeFirst(); frames.append(light)
    }

    private func pushGap() {
        DockIconController.shared.gap()
        if mode == .live { frames.removeFirst(); frames.append(nil) }
    }

    func sampleNow() { let p = paused; paused = false; tick(); paused = p }

    // MARK: series helpers
    func series(_ f: (Snapshot) -> Double?) -> [Double?] { frames.map { $0.flatMap(f) } }

    // MARK: Flight Recorder
    func startRecording() { recorded = []; recording = true }
    func stopRecording() { recording = false; saveRecording() }

    func saveRecording() {
        guard !recorded.isEmpty else { return }
        let t = FlightdeckCore.Trace(host: Host.current().localizedName ?? "Mac", model: Sysctl.string("hw.model") ?? "",
                                interval: interval, frames: recorded)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: FlightdeckCore.Trace.fileExtension) ?? .data]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "Recording \(df.string(from: Date())).\(FlightdeckCore.Trace.fileExtension)"
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

    private func load(_ t: FlightdeckCore.Trace) {
        guard !t.frames.isEmpty else { lastError = "Trace is empty"; return }
        trace = t; mode = .replay
        let start = UserDefaults.standard.integer(forKey: "replayIndex")   // debug/automation hook
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
    }
}
