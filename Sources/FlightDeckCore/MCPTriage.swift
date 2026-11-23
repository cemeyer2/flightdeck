import Foundation
// `triage`: "what's wrong with this Mac right now?" in one call. Pure ranking over what the other tools already read
// (the latest sample, findings, Flight Log, macOS reports, boots), so it is testable on fixtures. Each problem has a
// score (severity first, then whether it is still happening and how recent), evidence with numbers, and the tool to
// call next with its arguments.

public struct TriageItem: Sendable, Equatable {
    public var score: Int
    public var severity: Finding.Severity
    public var subsystem: String
    public var title: String
    public var evidence: String
    public var since: Date?
    public var ongoing: Bool
    public var nextTool: String
    public var nextArgs: JSON
}

public struct TriageInput: Sendable {
    public var snapshot: Snapshot?
    public var findings: [Finding] = []
    public var incidents: [Incident] = []
    public var reports: [DiagnosticReport] = []
    public var boots: [BootEvent] = []
    public var now: Date
    public init(snapshot: Snapshot?, now: Date) { self.snapshot = snapshot; self.now = now }
}

public enum Triage {
    static func base(_ s: Finding.Severity) -> Int { switch s { case .warning: 80; case .caution: 50; case .info: 20 } }

    /// Subsystem and next tool for a finding, from its id.
    static func route(_ f: Finding) -> (String, String, JSON) {
        let pid = f.pids?.first.map { JSON.int(Int($0)) }
        let id = f.id
        func has(_ p: String...) -> Bool { p.contains { id.hasPrefix($0) } }
        if has("hang:") { return ("hang", "sample_stacks", ["pid": pid]) }
        if has("cpu", "usual-cpu", "wakeups:", "respawn:") { return ("cpu", pid == nil ? "list_processes" : "get_process", pid.map { ["pid": $0] } ?? ["sort": "cpu"]) }
        if has("gpu") { return ("gpu", "list_processes", ["sort": "gpu"]) }
        if has("mem", "swap", "leak:", "usual-mem") { return ("memory", "list_processes", ["sort": "memory", "by_app": true]) }
        if has("thermal", "cpu-throttled", "cpu-speed-limit", "fan:", "temp-alert:") { return ("thermal", "temperatures", .object([])) }
        if has("disk", "drive:") { return ("disk", "checkup", .object([])) }
        // No address or no packets: the Flight Log has the network state captured when it began.
        if has("net-noip:", "net-rx-stall:") { return ("network", "recent_incidents", ["hours": 24, "min_severity": "warning"]) }
        if has("net", "wifi") { return ("network", "wifi", .object([])) }
        if has("battery", "unusual-power", "sleep-", "awake:") { return ("power", "battery", .object([])) }
        if has("restart:") { return ("restarts", "restarts", .object([])) }
        if has("privacy:dest:") { return ("network", "network_destinations", .object([])) }
        if has("privacy:") { return ("privacy", "camera_mic", .object([])) }
        if has("change:") { return ("changes", "system_changes", ["notable_only": true, "days": 7]) }
        if has("backup") { return ("backups", "backups", .object([])) }
        if has("usb-slow:", "accessory-low:") { return ("peripherals", "peripherals", .object([])) }
        if has("display") { return ("displays", "displays", .object([])) }
        if has("fleet:") { return ("fleet", "fleet", .object([])) }
        return ("system", "get_status", .object([]))
    }

    public static func rank(_ x: TriageInput) -> [TriageItem] {
        var items: [TriageItem] = []
        let ids = Set(x.findings.map(\.id))
        func add(_ sev: Finding.Severity, _ sub: String, _ title: String, _ ev: String, since: Date? = nil, ongoing: Bool, bonus: Int = 0,
                 _ tool: String, _ args: JSON = .object([])) {
            let recent = since.map { x.now.timeIntervalSince($0) < 3600 ? 5 : 0 } ?? 0
            items.append(TriageItem(score: base(sev) + (ongoing ? 10 : 0) + recent + bonus, severity: sev, subsystem: sub, title: title,
                                    evidence: ev, since: since, ongoing: ongoing, nextTool: tool, nextArgs: args))
        }
        // Findings: what is true now. Report findings are replaced by the grouped report items below.
        for f in x.findings where !f.id.hasPrefix("report:") {
            let (sub, tool, args) = route(f)
            add(f.severity, sub, f.title, f.detail ?? "Detected by FlightDeck's analyzer.", since: f.since, ongoing: true, tool, args)
        }
        // Ongoing incidents the findings don't already cover (e.g. standalone, where findings are instantaneous).
        let day = x.now.addingTimeInterval(-86_400)
        for i in x.incidents where i.end == nil && !ids.contains(i.key) {
            add(i.severity, "flight log", i.title, "Ongoing for \(Int(x.now.timeIntervalSince(i.start) / 60)) min." + (i.detail.map { " \($0)" } ?? ""),
                since: i.start, ongoing: true, "recent_incidents", ["hours": 1])
        }
        let ended = x.incidents.filter { ($0.end.map { $0 >= day } ?? false) && $0.severity >= .caution }
        if let worst = ended.max(by: { $0.severity != $1.severity ? $0.severity < $1.severity : $0.start < $1.start }) {
            add(.info, "flight log", "\(ended.count) problem\(ended.count == 1 ? "" : "s") in the Flight Log in the last 24 h",
                "Worst: \(worst.title) at \(worst.start.formatted(date: .omitted, time: .shortened)), lasting \(Int(worst.duration / 60)) min.",
                since: worst.start, ongoing: false, bonus: min(ended.count, 10), "recent_incidents", ["hours": 24, "min_severity": "caution"])
        }
        // Crashes, hangs, memory kills and panics in the last 24 h, by process and kind.
        let hurt = x.reports.filter { $0.time >= day && $0.kind.severity >= .caution }
        let groups = Dictionary(grouping: hurt) { "\($0.kind.rawValue)|\($0.process)" }
        for (_, g) in groups {
            let r = g.max { $0.time < $1.time }!
            let sev: Finding.Severity = r.kind == .panic || g.count >= 3 ? .warning : .caution
            let what = r.kind == .panic ? "Kernel panic" : "\(r.process): \(r.kind.rawValue.lowercased())"
            add(sev, "crashes", g.count > 1 ? "\(what) ×\(g.count) in 24 h" : "\(what) in the last 24 h",
                "Latest at \(r.time.formatted(date: .omitted, time: .shortened))" + (r.summary.map { ": \($0)" } ?? "") + ".",
                since: r.time, ongoing: false, bonus: min(g.count, 10), r.kind == .panic ? "panics" : "diagnostic_reports",
                r.kind == .panic ? ["days": 7] : ["process": .str(r.process), "hours": 24])
        }
        // Sessions that ended badly in the last 7 days.
        let badBoots = x.boots.filter { $0.previous.isUnexpected && x.now.timeIntervalSince($0.boot) < 7 * 86_400 }
        if let latest = badBoots.max(by: { $0.boot < $1.boot }) {
            add(latest.previous.kind == .panic ? .warning : .caution, "restarts",
                "\(badBoots.count) unexpected restart\(badBoots.count == 1 ? "" : "s") in 7 days",
                "Latest before the boot at \(latest.boot.formatted(date: .abbreviated, time: .shortened)): \(latest.previous.title).",
                since: latest.boot, ongoing: false, "restarts", ["days": 7])
        }
        if let s = x.snapshot { items += metricItems(s, ids: ids, now: x.now) }
        return items.sorted { $0.score != $1.score ? $0.score > $1.score : ($0.since ?? .distantPast) > ($1.since ?? .distantPast) }
    }

    /// Checks on the latest sample for conditions the analyzer reports only after they last (standalone has no history),
    /// skipped when a finding already covers them.
    static func metricItems(_ s: Snapshot, ids: Set<String>, now: Date) -> [TriageItem] {
        var out: [TriageItem] = []
        func item(_ sev: Finding.Severity, _ sub: String, _ title: String, _ ev: String, _ tool: String, _ args: JSON = .object([])) {
            out.append(TriageItem(score: base(sev) + 5, severity: sev, subsystem: sub, title: title, evidence: ev, since: s.time,
                                  ongoing: true, nextTool: tool, nextArgs: args))
        }
        if let p = s.memory.pressure.value, p >= 80, !ids.contains("mem-pressure") {
            item(p >= 90 ? .warning : .caution, "memory", String(format: "Memory pressure is %.0f%%", p),
                 "Swap used: \(s.memory.swapUsed.value.map { Fmt.bytes($0) } ?? "unavailable").", "list_processes", ["sort": "memory", "by_app": true])
        }
        if s.power.thermalState >= 2, !ids.contains("thermal") {
            item(.warning, "thermal", "The Mac is being slowed down for heat (thermal state \(MCPFormat.thermalStates[min(s.power.thermalState, 3)]))",
                 "Hottest sensor: \(s.power.hottest.value.map { String(format: "%.0f °C", $0) } ?? "unavailable").", "temperatures")
        }
        if let v = Analyzer.startupVolume(s), v.capacity > 0, !ids.contains("disk-low") {
            let free = Double(v.available), frac = free / Double(v.capacity)
            if free < 10e9 || frac < 0.05 {
                item(free < 5e9 ? .warning : .caution, "disk", "Startup disk is almost full (\(Fmt.storage(v.available)) free)",
                     String(format: "%.0f%% of %@ free.", frac * 100, Fmt.storage(v.capacity)), "checkup")
            }
        }
        if let b = s.power.battery, !b.isCharging, s.power.powerSource != "AC Power", b.percent <= 15 {
            item(b.percent <= 5 ? .warning : .caution, "power", String(format: "Battery is at %.0f%% and not charging", b.percent),
                 "Drawing \(s.power.systemWatts.value.map { String(format: "%.1f W", $0) } ?? "an unmeasured amount").", "battery")
        }
        return out
    }
}
