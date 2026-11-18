// State behind the Internet destination: the speed-test history (persisted next to the daily log), the run in
// progress, the opt-in schedule, and the network path's cost flags. One shared instance, attached to the Engine by
// ContentView at launch so the schedule can run while FlightDeck runs, whether or not the page is open.
// In demo mode the history is invented (DemoInternet.swift) and networkQuality is never started.
import SwiftUI
import Network
import FlightDeckCore

@MainActor
final class InternetModel: ObservableObject {
    static let shared = InternetModel()

    @Published private(set) var history: [SpeedTestResult] = []
    /// When the running test started (drives the progress bar); nil while idle.
    @Published private(set) var runningSince: Date?
    @Published private(set) var lastError: String?
    /// Why the last due scheduled test didn't run ("on battery at 15%"); nil once one runs.
    @Published private(set) var scheduleNote: String?
    /// NWPath facts: a hotspot/cellular/metered interface, Low Data Mode, and whether there's a usable path.
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false
    @Published private(set) var online = true

    private weak var engine: Engine?
    private var run: SpeedTestRun?
    private var lastAttempt: Date?
    private var monitor: NWPathMonitor?
    private var timer: Timer?
    private var attached = false
    /// nil = nothing is persisted (demo, headless renders).
    private var historyURL: URL?
    let demo: Bool

    /// Typical length of a run, for the progress bar (networkQuality prints nothing until it finishes).
    static let typicalSeconds = 18.0

    init() { demo = Demo.isEnabled }

    /// Preview / off-screen render with fixed history; never persisted, never runs anything.
    /// `demo: false` shows this Mac's live link panel (UIBench's real render); the history is still the given one.
    init(preview: [SpeedTestResult], demo: Bool = true) { self.demo = demo; history = preview; attached = true }

    var running: Bool { runningSince != nil }
    var latest: SpeedTestResult? { history.last }
    var scheduleHours: Int { UserDefaults.standard.integer(forKey: SpeedTestSchedule.defaultsKey) }

    /// Called once from ContentView.onAppear. Loads history, starts watching the network path (cheap: a callback when
    /// the path changes) and checks the schedule once a minute.
    func attach(_ e: Engine) {
        engine = e
        guard !attached else { return }
        attached = true
        if demo { history = Demo.speedTests(); return }
        guard !e.headless else { return }
        let url = SpeedTestHistory.url(in: DailyLog.defaultDirectory)
        historyURL = url
        history = SpeedTestHistory.load(from: url)
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let exp = path.isExpensive, con = path.isConstrained, ok = path.status == .satisfied
            Task { @MainActor in self?.isExpensive = exp; self?.isConstrained = con; self?.online = ok }
        }
        m.start(queue: DispatchQueue(label: "flightdeck.internet.path", qos: .utility))
        monitor = m
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedule() }
        }
    }

    /// The schedule's verdict right now, for the Settings and page captions.
    func decision(now: Date = Date()) -> SpeedTestSchedule.Decision {
        let power = SpeedTestSchedule.powerState()
        let last = [lastAttempt, history.last?.time].compactMap { $0 }.max()
        return SpeedTestSchedule.decide(.init(now: now, intervalHours: scheduleHours, lastRun: last, onBattery: power.onBattery,
                                              batteryPercent: power.percent, isExpensive: isExpensive, isConstrained: isConstrained,
                                              online: online, demo: demo, running: running))
    }

    private func checkSchedule() {
        switch decision() {
        case .run: scheduleNote = nil; start(scheduled: true)
        case .skip(let why): scheduleNote = "Scheduled test skipped: \(why)"
        case .notDue, .off: break
        }
    }

    /// Starts a test (button or schedule). Refused in demo mode and while one runs.
    func start(scheduled: Bool = false) {
        guard !demo, !running, let e = engine, !e.headless else { return }
        lastError = nil; lastAttempt = Date(); runningSince = Date()
        // Context is captured before the test loads the link: idle Wi-Fi and ping figures.
        let ctx = SpeedTestContext(wifi: e.liveSnapshot?.wifi ?? WiFiInfo.current(), latency: e.liveSnapshot?.latency)
        let r = SpeedTestRun(); run = r
        r.start(context: ctx, scheduled: scheduled) { [weak self] result in
            Task { @MainActor in self?.finish(result) }
        }
    }

    func cancel() { run?.cancel() }

    private func finish(_ result: Result<SpeedTestResult, SpeedTestError>) {
        runningSince = nil; run = nil
        switch result {
        case .success(let r):
            history = SpeedTestHistory.appending(r, to: history)
            if let url = historyURL {
                let h = history
                DispatchQueue.global(qos: .utility).async { SpeedTestHistory.save(h, to: url) }
            }
        case .failure(.cancelled): break
        case .failure(let e): lastError = e.description
        }
    }

    /// Results from the last `days` days (oldest first).
    func results(days: Int, now: Date = Date()) -> [SpeedTestResult] {
        let from = now.addingTimeInterval(-Double(days) * 86_400)
        return history.filter { $0.time >= from }
    }
}
