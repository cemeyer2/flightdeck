import Foundation
// Events pushed to MCP clients (resource subscriptions, `subscriptions/listen`, Claude Code channels) and matched by
// `wait_for_event`. An event is found by comparing two readings of what the server already serves (Flight Log,
// findings, macOS reports, thermal state, battery): `MCPEventDetector` is that pure diff; MCPEventHub runs it, and
// only while someone listens.

/// One thing that happened, with enough to act on without another call, and the resource to read for more.
public struct MCPEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case incidentOpened = "incident_opened", incidentClosed = "incident_closed", finding
        case report, thermal, batteryLow = "battery_low"
    }
    /// Sequence number, increasing within one server process (0 until the hub assigns it).
    public var seq: Int = 0
    public var kind: Kind
    public var severity: Finding.Severity
    public var title: String
    public var detail: String?
    /// The app or process concerned, when there is one.
    public var app: String?
    public var pid: Int32?
    /// When the condition began (incident/finding start, report time, time of the change).
    public var since: Date
    /// The condition's stable key (incident/finding id, report path), so a client can tell repeats apart.
    public var key: String
    public init(kind: Kind, severity: Finding.Severity, title: String, detail: String? = nil, app: String? = nil, pid: Int32? = nil,
                since: Date, key: String) {
        self.kind = kind; self.severity = severity; self.title = title; self.detail = detail; self.app = app; self.pid = pid
        self.since = since; self.key = key
    }

    /// The resource whose content this event changes.
    public var uri: String {
        switch kind {
        case .incidentOpened, .incidentClosed: MCPResources.incidents
        case .finding: MCPResources.findings
        case .report: MCPResources.reports
        case .thermal, .batteryLow: MCPResources.status
        }
    }
    /// The tool that tells more.
    public var nextTool: String {
        switch kind {
        case .incidentOpened, .incidentClosed: "recent_incidents"
        case .finding: pid != nil ? "get_process" : "get_status"
        case .report: "diagnostic_reports"
        case .thermal: "temperatures"
        case .batteryLow: "battery"
        }
    }

    public var json: JSON {
        .object(dropping: [
            ("seq", .int(seq)), ("event", .str(kind.rawValue)), ("severity", MCPFormat.severity(severity)), ("title", .str(title)),
            ("detail", detail.map(JSON.str)), ("app", app.map(JSON.str)), ("pid", pid.map { .int(Int($0)) }),
            ("since", MCPFormat.time(since)), ("key", .str(key)), ("uri", .str(uri)), ("next_tool", .str(nextTool)),
        ])
    }

    /// Parses `json` back (the stdio proxy reads the app's events this way).
    public init?(json j: JSON) {
        guard let k = j["event"]?.string.flatMap(Kind.init(rawValue:)), let title = j["title"]?.string, let key = j["key"]?.string,
              let since = j["since"]?.string.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return nil }
        let sev: Finding.Severity = switch j["severity"]?.string { case "warning": .warning; case "caution": .caution; default: .info }
        self.init(kind: k, severity: sev, title: title, detail: j["detail"]?.string, app: j["app"]?.string,
                  pid: j["pid"]?.int.map(Int32.init), since: since, key: key)
        seq = j["seq"]?.int ?? 0
    }
}

/// What the detector compares between polls. Everything optional is "not known", so nothing is reported for it.
public struct MCPWatchState: Sendable {
    public var incidents: [Incident] = []
    public var findings: [Finding] = []
    public var reports: [DiagnosticReport] = []
    public var thermalState: Int?
    public var batteryPercent: Double?
    public var charging: Bool?
    /// pid → app name, to name the app behind a finding.
    public var appOf: [Int32: String] = [:]
    public init() {}
}

/// Diffs consecutive readings into events. The first reading only sets the baseline: a client that subscribes is told
/// about what happens from then on, not about everything already true (that is what the resources and triage are for).
public struct MCPEventDetector: Sendable {
    /// Battery at or below this, not charging, is "low"; reported once per discharge.
    public static let batteryLow = 20.0
    var last: MCPWatchState?
    var batteryWarned = false
    public init() {}

    public mutating func update(_ s: MCPWatchState, now: Date) -> [MCPEvent] {
        defer { last = s }
        guard let old = last else {
            batteryWarned = Self.isLow(s)
            return []
        }
        var out: [MCPEvent] = []
        let before = Dictionary(old.incidents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in s.incidents {
            let app = Self.app(fromKey: i.key, title: i.title)
            if let o = before[i.id] {
                if o.end == nil, let end = i.end {
                    out.append(MCPEvent(kind: .incidentClosed, severity: i.severity, title: "Ended: \(i.title)",
                                        detail: "Lasted \(Int(end.timeIntervalSince(i.start).rounded())) s." + (i.detail.map { " \($0)" } ?? ""),
                                        app: app, since: i.start, key: i.key))
                }
            } else {
                out.append(MCPEvent(kind: .incidentOpened, severity: i.severity, title: i.title, detail: i.detail, app: app,
                                    since: i.start, key: i.key))
            }
        }
        // Findings: new ids, or an existing one that got worse. Report-derived findings are covered by `report` events.
        let oldF = Dictionary(old.findings.map { ($0.id, $0.severity) }, uniquingKeysWith: max)
        for f in s.findings where !f.id.hasPrefix("report:") {
            if let sev = oldF[f.id], sev >= f.severity { continue }
            let pid = f.pids?.first
            out.append(MCPEvent(kind: .finding, severity: f.severity, title: f.title, detail: f.detail,
                                app: pid.flatMap { s.appOf[$0] }, pid: pid, since: f.since, key: f.id))
        }
        let oldR = Set(old.reports.map(\.path))
        for r in s.reports where !oldR.contains(r.path) && r.kind != .other {
            out.append(MCPEvent(kind: .report, severity: r.kind.severity, title: "\(r.kind.rawValue): \(r.process)", detail: r.summary,
                                app: r.process, since: r.time, key: r.path))
        }
        if let t = s.thermalState, let o = old.thermalState, t != o {
            let name = MCPFormat.thermalStates[min(max(t, 0), 3)]
            out.append(MCPEvent(kind: .thermal, severity: t >= 2 ? .warning : t == 1 ? .caution : .info,
                                title: "Thermal state is now \(name) (was \(MCPFormat.thermalStates[min(max(o, 0), 3)]))",
                                detail: t >= 2 ? "macOS is slowing the Mac down to cool it." : nil, since: now, key: "thermal"))
        }
        let low = Self.isLow(s)
        if low && !batteryWarned, let p = s.batteryPercent {
            out.append(MCPEvent(kind: .batteryLow, severity: p <= 10 ? .warning : .caution,
                                title: String(format: "Battery is low (%.0f%%) and not charging", p), since: now, key: "battery-low"))
        }
        if s.charging == true || (s.batteryPercent ?? 0) > Self.batteryLow + 5 { batteryWarned = false } else if low { batteryWarned = true }
        return out
    }

    static func isLow(_ s: MCPWatchState) -> Bool {
        guard let p = s.batteryPercent, s.charging == false else { return false }
        return p <= batteryLow
    }

    /// Incident keys don't carry a display name; the title starts with it for per-app incidents ("Xcode is using…").
    static func app(fromKey key: String, title: String) -> String? {
        let perApp = ["cpu:", "gpu:", "leak:", "wakeups:", "awake:", "hang:", "usual-cpu:", "usual-mem:"]
        guard perApp.contains(where: key.hasPrefix) else { return nil }
        for sep in [" is ", " wakes ", " keeps ", " has "] {
            if let r = title.range(of: sep) {
                let name = String(title[..<r.lowerBound])
                return name.range(of: " (").map { String(name[..<$0.lowerBound]) } ?? name
            }
        }
        return nil
    }
}
