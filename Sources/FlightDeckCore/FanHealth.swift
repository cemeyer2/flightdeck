import Foundation
// Fan health: per-fan speed against its target, minimum and maximum, and three diagnostics that need a sustained
// condition so a fan spinning up or down (which takes a few seconds) isn't reported:
//   • stalled: 0 RPM while the SMC asks for a speed and the Mac is hot (a stuck or unplugged fan);
//   • lagging: well below its target for a minute (a worn bearing or a blocked fan);
//   • disagreeing: two fans asked for similar speeds but running far apart.
// Fanless Macs (an empty fan list) are reported as such; an unknown fan list (nil) as unknown, never as "no fans".

public enum FanIssue: String, Sendable, Equatable, Codable {
    case stalled, lagging, disagree
    public var text: String {
        switch self {
        case .stalled: "Not spinning although the system asks for it"
        case .lagging: "Not reaching its target speed"
        case .disagree: "Running far from the other fan"
        }
    }
}

/// One fan's health at the latest sample.
public struct FanStatus: Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var rpm: Double
    public var targetRPM: Double?
    public var minRPM: Double?
    public var maxRPM: Double?
    /// rpm as a percentage of maxRPM (nil without a maximum).
    public var percentOfMax: Double?
    public var issues: [FanIssue]
    public init(index: Int, rpm: Double, targetRPM: Double?, minRPM: Double?, maxRPM: Double?, percentOfMax: Double?, issues: [FanIssue]) {
        self.index = index; self.rpm = rpm; self.targetRPM = targetRPM; self.minRPM = minRPM; self.maxRPM = maxRPM
        self.percentOfMax = percentOfMax; self.issues = issues
    }
}

/// Sustained-condition tracking for fans. Not thread-safe: owned by ThermalWatch, which locks around it.
public final class FanHealthMonitor {
    /// How long each condition must hold before it's reported.
    static let stalledAfter: TimeInterval = 20, laggingAfter: TimeInterval = 60, disagreeAfter: TimeInterval = 60
    /// A stalled fan only matters when something is warm enough that it should be cooling.
    static let hotCelsius = 70.0
    /// Below target by more than this fraction and this many RPM counts as lagging.
    static let lagFraction = 0.25, lagRPM = 300.0
    /// Fans differing by more than this fraction of the faster one disagree (when their targets are within `targetSpread`).
    static let disagreeFraction = 0.4, targetSpread = 0.15

    /// When each (fan, issue) condition began.
    private var since: [String: Date] = [:]
    private var last: Date?
    public private(set) var statuses: [FanStatus] = []
    /// nil = unknown, true = this Mac reported no fans.
    public private(set) var fanless: Bool?

    public init() {}

    /// Folds in one sample. `hottest` is the hottest non-reference sensor in °C (nil if unknown).
    @discardableResult
    public func ingest(fans: [FanReading]?, hottest: Double?, at t: Date) -> [FanStatus] {
        // A gap (sleep) breaks every sustained condition.
        if let last, t.timeIntervalSince(last) > 120 { since = [:] }
        last = t
        guard let fans else { fanless = nil; statuses = []; since = [:]; return [] }
        fanless = fans.isEmpty
        var active = Set<String>()
        func held(_ key: String, _ cond: Bool, _ after: TimeInterval) -> Bool {
            guard cond else { return false }
            active.insert(key)
            let start = since[key] ?? t
            since[key] = start
            return t.timeIntervalSince(start) >= after
        }
        let disagreeing = Self.disagree(fans)
        statuses = fans.map { f in
            var issues: [FanIssue] = []
            let target = f.targetRPM ?? 0
            if held("\(f.index):stalled", f.rpm < 1 && target > 0 && (hottest ?? 0) >= Self.hotCelsius, Self.stalledAfter) { issues.append(.stalled) }
            else if held("\(f.index):lagging", f.rpm >= 1 && target > 0 && f.rpm < target * (1 - Self.lagFraction) && target - f.rpm > Self.lagRPM,
                         Self.laggingAfter) { issues.append(.lagging) }
            if held("\(f.index):disagree", disagreeing.contains(f.index), Self.disagreeAfter) { issues.append(.disagree) }
            return FanStatus(index: f.index, rpm: f.rpm, targetRPM: f.targetRPM, minRPM: f.minRPM, maxRPM: f.maxRPM,
                             percentOfMax: f.maxRPM.flatMap { $0 > 0 ? f.rpm / $0 * 100 : nil }, issues: issues)
        }
        since = since.filter { active.contains($0.key) }
        return statuses
    }

    /// Indices of fans that disagree right now: both spinning, targets similar (or unknown), speeds far apart.
    /// Only the slower fan of a pair is flagged, since it is the likelier culprit.
    static func disagree(_ fans: [FanReading]) -> Set<Int> {
        guard fans.count >= 2, let fast = fans.max(by: { $0.rpm < $1.rpm }), fast.rpm > 500 else { return [] }
        var out = Set<Int>()
        for f in fans where f.index != fast.index {
            if let a = f.targetRPM, let b = fast.targetRPM, max(a, b) > 0, abs(a - b) / max(a, b) > targetSpread { continue }
            if (fast.rpm - f.rpm) / fast.rpm > disagreeFraction { out.insert(f.index) }
        }
        return out
    }

    /// Findings for current issues: a stalled fan is a warning, the others cautions.
    public func findings(at t: Date) -> [Finding] {
        statuses.flatMap { s in
            s.issues.map { issue -> Finding in
                let sev: Finding.Severity = issue == .stalled ? .warning : .caution
                let target = s.targetRPM.map { " (target \(FanExplainer.group($0)) rpm)" } ?? ""
                let title: String, detail: String
                switch issue {
                case .stalled:
                    title = "Fan \(s.index + 1) isn't spinning while the Mac is hot"
                    detail = "It reads 0 rpm\(target). A stuck or disconnected fan can't cool the Mac; have it checked if this persists."
                case .lagging:
                    title = "Fan \(s.index + 1) can't reach its target speed"
                    detail = "It runs at \(FanExplainer.group(s.rpm)) rpm\(target). Dust or a failing bearing can hold a fan back."
                case .disagree:
                    title = "Fan \(s.index + 1) runs much slower than the other fan"
                    detail = "It runs at \(FanExplainer.group(s.rpm)) rpm\(target) while asked for a similar speed as the other fan."
                }
                let key = "\(s.index):\(issue.rawValue)"
                return Finding(id: "fan:\(key)", severity: sev, icon: "fan", title: title, detail: detail,
                               since: since[key] ?? t, destination: "Performance:Thermals")
            }
        }
    }
}
