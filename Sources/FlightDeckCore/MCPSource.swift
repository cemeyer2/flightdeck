import Foundation
// Where the MCP tools get their data. Two implementations:
//   • the running app (EngineMCPSource in the app target): the Engine's live snapshot, sustained findings, the
//     Flight Log, the black box and the Trends log, exactly as the windows show them;
//   • `StandaloneMCPSource` (here), used by `FlightDeck --mcp` when the app's MCP server isn't reachable: it samples
//     on demand and reads the app's files from disk (incident log, black box, daily log, macOS reports), read-only.
// Tests use a third, synthetic one.

public protocol MCPDataSource: AnyObject, Sendable {
    /// True for the standalone CLI source; tool output then says that findings are instantaneous and history is only
    /// what the app recorded while it was running.
    var standalone: Bool { get }
    /// The latest sample, or nil if none could be taken.
    func snapshot() async -> Snapshot?
    /// What's wrong right now (worst first is not required; tools sort).
    func findings() async -> [Finding]
    /// The Flight Log (7 days), oldest first.
    func incidents() async -> [Incident]
    /// macOS crash, hang and resource-limit reports since `since`, newest first.
    func reports(since: Date) async -> [DiagnosticReport]
    /// Black-box frames in [from, to] from one tier, or nil if there are none.
    func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace?
    /// How far back each black-box tier reaches.
    var blackBoxConfig: BlackBox.Config { get }
    /// The Trends history (daily rollups), or nil when it isn't available.
    func dailyHistory() async -> DailyLog.History?
    /// The Checkup list (runs the checks; takes a few seconds).
    func checkup() async -> [CheckResult]
    /// Session thermal state (per-sensor statistics, throttling, fan health), or nil when there is none (standalone).
    func thermal() async -> (status: ThermalStatus, history: SensorHistory)?
    /// Camera & Mic: the live state (nil if it isn't being watched) and the session history, or nil if unavailable.
    func cameraMic() async -> (live: CameraMicLive?, store: CameraMicStore)?
}

extension MCPDataSource {
    /// Sources without a session (the standalone CLI, tests) have no thermal history; `temperatures` then reports the
    /// latest snapshot only.
    public func thermal() async -> (status: ThermalStatus, history: SensorHistory)? { nil }
    /// Sources without the app's watch (tests) have no camera and microphone data.
    public func cameraMic() async -> (live: CameraMicLive?, store: CameraMicStore)? { nil }
    /// Checkup with the swap trend taken from the black box's coarse tier, as the Checkup view does.
    public func runCheckup() async -> [CheckResult] {
        let trace = await blackBox(.coarse, from: Date().addingTimeInterval(-86_400), to: Date())
        let swap: [(Date, Double)] = (trace?.frames ?? []).compactMap { f in f.memory.swapUsed.value.map { (f.time, $0) } }
        return await Task.detached(priority: .userInitiated) { Checkup.run(swapHistory: swap) }.value
    }
}

/// The data source for `FlightDeck --mcp` without the app. Nothing runs between requests: the first request that
/// needs a sample primes the delta-based counters and waits a second (as `--snapshot` does); later requests take a
/// fresh sample unless the last one is under a second old. Each sample also goes through an Analyzer, so findings are
/// those visible from the samples this process took (sustained-for-minutes findings need the app). Files written by
/// the app are only read, never written.
public final class StandaloneMCPSource: MCPDataSource, @unchecked Sendable {
    public let standalone = true
    // Sampler and Analyzer are not thread-safe; both are only touched on `queue`.
    private let queue = DispatchQueue(label: "flightdeck.mcp.standalone", qos: .userInitiated)
    private let sampler = Sampler()
    private let analyzer = Analyzer()
    private var primed: Date?
    private var last: (Snapshot, [Finding])?
    private let box: BlackBox
    private let incidentURL: URL
    private let dailyDir: URL

    public init(blackBoxDir: URL = BlackBox.defaultDirectory, incidentURL: URL = IncidentLog.defaultURL, dailyDir: URL = DailyLog.defaultDirectory) {
        box = BlackBox(dir: blackBoxDir); self.incidentURL = incidentURL; self.dailyDir = dailyDir
    }

    public var blackBoxConfig: BlackBox.Config { box.config }

    /// A sample and the findings for it; see the type comment for the timing.
    private func current() async -> (Snapshot, [Finding]) {
        await withCheckedContinuation { c in
            queue.async { [self] in
                if let last, Date().timeIntervalSince(last.0.time) < 1 { c.resume(returning: last); return }
                if primed == nil { _ = sampler.sample(); primed = Date(); Thread.sleep(forTimeInterval: 1) }
                let s = sampler.sample()
                let f = analyzer.ingest(s)
                last = (s, f)
                c.resume(returning: (s, f))
            }
        }
    }

    public func snapshot() async -> Snapshot? { await current().0 }

    public func findings() async -> [Finding] {
        let f = await current().1
        // Reports are read on demand here; the app rescans them every 5 minutes.
        let r = await reports(since: Date().addingTimeInterval(-7 * 86_400))
        return f + DiagnosticReports.findings(r)
    }

    public func incidents() async -> [Incident] {
        // A fresh read-only IncidentLog: its initializer loads the file and `save` is never called.
        IncidentLog(url: incidentURL).incidents
    }

    public func reports(since: Date) async -> [DiagnosticReport] {
        await Task.detached(priority: .userInitiated) { DiagnosticReports.scan(since: since) }.value
    }

    public func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace? {
        let box = self.box
        return await Task.detached(priority: .userInitiated) { box.trace(tier, from: from, to: to) }.value
    }

    public func dailyHistory() async -> DailyLog.History? {
        // Loading only reads the saved days; nothing is ingested, so `flush` (the only writer) has nothing to write.
        let dir = dailyDir
        return await Task.detached(priority: .userInitiated) { DailyLog(dir: dir).history() }.value
    }

    public func checkup() async -> [CheckResult] { await runCheckup() }

    /// The app's Camera & Mic history, read-only, and which devices are in use right now (one reading of the device
    /// state; no listeners, and without the app's indicator log stream, so the current app isn't named).
    public func cameraMic() async -> (live: CameraMicLive?, store: CameraMicStore)? {
        let dir = dailyDir
        return await Task.detached(priority: .userInitiated) {
            (CameraMicWatch.reading(), CameraMicStore(dir: dir, readOnly: true))
        }.value
    }
}
