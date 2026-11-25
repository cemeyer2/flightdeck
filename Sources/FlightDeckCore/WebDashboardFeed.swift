import Foundation
// What the web dashboard is fed. It may serve no value that came from the privileged helper (see HelperRouting), and
// guessing afterwards which findings the helper's counters went into doesn't work: machine-wide findings name the
// biggest app, app groups add helper and app rows together, and the Analyzer's smoothing outlives the helper. So while
// the helper's values could be in the main findings, the dashboard gets findings and incidents of its own, computed
// only from the helper-free snapshot.

/// One sample as the dashboard may show it.
public struct WebDashboardData {
    /// `Snapshot.withoutHelperValues()`.
    public var snapshot: Snapshot
    /// Live findings from the sampling path (diagnostic-report and sleep findings are added by the caller).
    public var findings: [Finding]
    /// The newest 50 incidents, from the dashboard's own in-memory log.
    public var incidents: [Incident]
}

/// Decides, per sample, which findings and incidents the dashboard gets. Not thread-safe: the Engine confines it to its
/// sampling queue.
///
/// - Helper not contributing (and not recently): the main Analyzer's findings are already clean and are reused; no
///   extra analysis.
/// - Helper contributing, or within `holdDown` of its last value: a second Analyzer runs on the helper-free snapshot.
///   It starts fresh, unseeded (the black box holds helper values), so baseline findings and ones that need some
///   seconds of history appear a few samples later than in the app.
/// - Dashboard off: nothing is kept except when the helper last contributed (one scan of the process list per sample).
///
/// Incidents always come from the dashboard's own in-memory log, fed with whatever findings the dashboard got, so
/// they never include an incident recorded from helper values, in this session or loaded from disk. The cost is that
/// the dashboard's incident history starts when the dashboard (or the app) did, and has no rule-action incidents.
public final class WebDashboardFeed {
    /// How long the main Analyzer can still carry helper values after the last one: per-app CPU and GPU are smoothed
    /// over ~20 s, and the leak finding fits the last 30 minutes of per-app memory (a point exactly 30 minutes old
    /// still counts, hence the extra minute).
    public static let holdDown: TimeInterval = 1800 + 60
    /// The user's thresholds, forwarded to the dashboard's Analyzer.
    public var thresholds = Thresholds() { didSet { analyzer?.thresholds = thresholds } }
    /// Whether the dashboard's own Analyzer is running (for tests).
    public var isAnalyzing: Bool { analyzer != nil }
    private var analyzer: Analyzer?
    private var log = IncidentLog(url: nil)
    private var lastHelperValue: Date?
    private let ownUID: UInt32

    public init(ownUID: UInt32 = getuid()) { self.ownUID = ownUID }

    /// Call once per sample, after the main analysis. `analyzed` is the main Analyzer's result for `s`; `others` are the
    /// findings from sources that never use helper values (launches, thermals, backups, the dashboard's change
    /// findings…). Per-app baseline findings (DailyLog) are never passed: their "usual" figures come from saved,
    /// helper-inclusive history. nil while the dashboard is off.
    public func ingest(_ s: Snapshot, enabled: Bool, analyzed: [Finding], others: [Finding]) -> WebDashboardData? {
        if s.processes.contains(where: { $0.source == .helper }) { lastHelperValue = s.time }
        guard enabled else { analyzer = nil; log = IncidentLog(url: nil); return nil }
        let clean = s.withoutHelperValues(ownUID: ownUID)
        let findings: [Finding]
        if let last = lastHelperValue, s.time.timeIntervalSince(last) < Self.holdDown {
            let a = analyzer ?? { let a = Analyzer(); a.thresholds = thresholds; return a }()
            analyzer = a
            findings = a.ingest(clean) + others
        } else {
            analyzer = nil
            findings = analyzed + others
        }
        log.update(findings, at: s.time)
        return WebDashboardData(snapshot: clean, findings: findings, incidents: Array(log.incidents.suffix(50)))
    }

    /// Sampling paused: ends every ongoing dashboard incident, as the main log does.
    public func closeAll(at now: Date) { log.closeAll(at: now) }
    /// The user cleared the incident log.
    public func clearIncidents() { log.clear() }
}

/// Confined to one queue by its owner.
extension WebDashboardFeed: @unchecked Sendable {}
