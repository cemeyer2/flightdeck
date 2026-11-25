import Foundation
// Web dashboard, part 5: the one JSON document browsers get (from /api/state and in every stream event). Built by a
// pure function from explicit inputs the app passes in, so what leaves the Mac is decided here and tested. Findings
// and incidents go through FleetRedaction (private kinds dropped, names, paths, addresses scrubbed); muted findings
// are left out, as in the app. Top apps carry only an app name and its CPU, memory and energy: no PID, path, user or
// arguments. Every reading is `{"value": x}` or `{"value": null, "reason": …}`, never a 0 for "not measured".
// Encoded with sorted snake_case keys on one line (no raw CR/LF, so a name can't forge an SSE event), at most 64 KB.

/// One sparkline point. `gap` marks a 30 s bucket with no sample, which the page never bridges.
public struct WebPoint: Codable, Equatable, Sendable {
    public var t: Date
    public var cpuPercent: Double?
    /// Memory used as % of installed.
    public var memoryPercent: Double?
    public var hottestC: Double?
    public var gap: Bool?
    public init(t: Date, cpuPercent: Double?, memoryPercent: Double?, hottestC: Double?, gap: Bool? = nil) {
        self.t = t; self.cpuPercent = cpuPercent; self.memoryPercent = memoryPercent; self.hottestC = hottestC; self.gap = gap
    }
    public init(_ s: Snapshot) {
        let m = s.memory
        self.init(t: s.time, cpuPercent: s.cpu.total.value,
                  memoryPercent: m.isMeasured && m.total > 0 ? Double(m.used) / Double(m.total) * 100 : nil, hottestC: s.power.hottest.value)
    }
    public static func gap(at t: Date) -> WebPoint { WebPoint(t: t, cpuPercent: nil, memoryPercent: nil, hottestC: nil, gap: true) }
}

public struct WebDashboardDocument: Codable, Equatable, Sendable {
    public struct Mac: Codable, Equatable, Sendable {
        public var name, model, macos, app: String
        public var uptimeS: Double?
    }
    public struct Light: Codable, Equatable, Sendable {
        public var key, label: String
        /// ok, info, caution or warning.
        public var level: String
    }
    public struct Item: Codable, Equatable, Sendable {
        public var kind, severity, title: String
        public var detail: String?
        public var since: Date
    }
    public struct IncidentItem: Codable, Equatable, Sendable {
        public var kind, severity, title: String
        public var start: Date
        public var end: Date?
    }
    public struct App: Codable, Equatable, Sendable {
        public var name: String
        public var cpuPercent: Double
        public var memoryBytes: Double
        public var energyWatts: Double?
        /// Processes rolled into the app.
        public var count: Int
    }
    public struct Readings: Codable, Equatable, Sendable {
        public var cpuPercent, memoryPressurePercent, memoryUsedBytes, memoryTotalBytes, swapBytes: FleetValue
        public var diskReadBytesPerS, diskWriteBytesPerS, diskFreeBytes: FleetValue
        public var netInBytesPerS, netOutBytesPerS: FleetValue
        public var systemWatts, hottestC: FleetValue
        /// nominal, fair, serious or critical.
        public var thermalState: String?
        public var gpuPercent, batteryPercent: FleetValue
        public var charging: Bool?
        /// The fastest fan.
        public var fanRpm: FleetValue

        static func missing(_ reason: String) -> Readings {
            let m = FleetValue.missing(reason)
            return Readings(cpuPercent: m, memoryPressurePercent: m, memoryUsedBytes: m, memoryTotalBytes: m, swapBytes: m,
                            diskReadBytesPerS: m, diskWriteBytesPerS: m, diskFreeBytes: m, netInBytesPerS: m, netOutBytesPerS: m,
                            systemWatts: m, hottestC: m, thermalState: nil, gpuPercent: m, batteryPercent: m, charging: nil, fanRpm: m)
        }

        /// FleetValue's own encoding leaves out a nil value; here `"value": null` is always written, so the page and
        /// scripts can tell "not measured" from "field unknown".
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            let values: [(CodingKeys, FleetValue)] = [
                (.cpuPercent, cpuPercent), (.memoryPressurePercent, memoryPressurePercent), (.memoryUsedBytes, memoryUsedBytes),
                (.memoryTotalBytes, memoryTotalBytes), (.swapBytes, swapBytes), (.diskReadBytesPerS, diskReadBytesPerS),
                (.diskWriteBytesPerS, diskWriteBytesPerS), (.diskFreeBytes, diskFreeBytes), (.netInBytesPerS, netInBytesPerS),
                (.netOutBytesPerS, netOutBytesPerS), (.systemWatts, systemWatts), (.hottestC, hottestC), (.gpuPercent, gpuPercent),
                (.batteryPercent, batteryPercent), (.fanRpm, fanRpm)]
            for (key, v) in values {
                var n = c.nestedContainer(keyedBy: ValueKeys.self, forKey: key)
                try n.encode(v.value, forKey: .value)
                try n.encodeIfPresent(v.reason, forKey: .reason)
            }
            try c.encodeIfPresent(thermalState, forKey: .thermalState)
            try c.encodeIfPresent(charging, forKey: .charging)
        }
        enum ValueKeys: String, CodingKey { case value, reason }
    }

    public var v = 1
    public var mac: Mac
    public var sampledAt: Date?
    /// live or paused.
    public var sampling: String
    /// How often a new sample is published right now.
    public var intervalS: Double
    /// true only in the developer demo server; absent otherwise.
    public var demo: Bool?
    public var annunciator: [Light]
    public var findings: [Item]
    public var findingsTruncated = false
    public var incidents: [IncidentItem]
    public var incidentsTruncated = false
    public var readings: Readings
    public var topApps: [App]
    public var topAppsTruncated = false
    /// Only in a stream's first event: 60 points, oldest first. Empty with `historyUnavailable` saying why.
    public var history: [WebPoint]?
    public var historyUnavailable: String?
    /// Only in `sample` events: the newest point.
    public var point: WebPoint?
}

public enum WebHistory: Sendable {
    /// The event carries no history.
    case none
    case points([WebPoint])
    case unavailable(String)
}

public struct WebDashboardInputs {
    public var snapshot: Snapshot?
    /// Live findings (never replayed ones).
    public var findings: [Finding]
    public var incidents: [Incident]
    public var history: WebHistory
    public var point: WebPoint?
    /// The Settings label; blank falls back to `modelName`.
    public var displayName: String
    /// Marketing name ("MacBook Pro").
    public var modelName: String
    /// hw.model ("Mac16,7").
    public var hardwareModel: String
    public var macOS: String
    public var appVersion: String
    public var uptime: TimeInterval?
    public var paused: Bool
    public var intervalS: Double
    public var demo: Bool
    public var redaction: FleetRedaction
    public var isMuted: (Finding) -> Bool
    /// Seams for data the app must not serve (see WebDashboardEndpoint.privilegedFilter). There is deliberately no
    /// input for browser tabs or process contents.
    public var excludeProcess: (ProcessSample) -> Bool
    public var excludeFinding: (Finding) -> Bool

    public init(snapshot: Snapshot?, findings: [Finding], incidents: [Incident], history: WebHistory = .none, point: WebPoint? = nil,
                displayName: String, modelName: String, hardwareModel: String, macOS: String, appVersion: String, uptime: TimeInterval?,
                paused: Bool, intervalS: Double, demo: Bool = false, redaction: FleetRedaction,
                isMuted: @escaping (Finding) -> Bool = { _ in false },
                excludeProcess: @escaping (ProcessSample) -> Bool = { _ in false },
                excludeFinding: @escaping (Finding) -> Bool = { _ in false }) {
        self.snapshot = snapshot; self.findings = findings; self.incidents = incidents; self.history = history; self.point = point
        self.displayName = displayName; self.modelName = modelName; self.hardwareModel = hardwareModel; self.macOS = macOS
        self.appVersion = appVersion; self.uptime = uptime; self.paused = paused; self.intervalS = intervalS; self.demo = demo
        self.redaction = redaction; self.isMuted = isMuted; self.excludeProcess = excludeProcess; self.excludeFinding = excludeFinding
    }
}

public enum WebDashboardState {
    public static let maxBytes = 64 << 10, topAppCount = 10, historyStep: TimeInterval = 30, historyPoints = 60
    static let thermalNames = ["nominal", "fair", "serious", "critical"]

    static func severity(_ s: Finding.Severity) -> String {
        switch s { case .info: return "info"; case .caution: return "caution"; case .warning: return "warning" }
    }
    static func severity(_ raw: Int) -> String { Finding.Severity(rawValue: raw).map(severity) ?? "info" }

    public static func build(_ i: WebDashboardInputs) -> WebDashboardDocument {
        let r = i.redaction
        let shown = i.findings.filter { !i.isMuted($0) && !i.excludeFinding($0) }
        let lights = Annunciator.lights.map { l in
            WebDashboardDocument.Light(key: l.key, label: l.label, level: Annunciator.level(l, in: shown).map(severity) ?? "ok")
        }
        let findings = shown.compactMap(r.finding)
            .sorted { ($1.severity, $1.since, $0.kind, $0.title) < ($0.severity, $0.since, $1.kind, $1.title) }
            .map { WebDashboardDocument.Item(kind: $0.kind, severity: severity($0.severity), title: $0.title, detail: $0.detail, since: $0.since) }
        let incidents = i.incidents.filter { !i.excludeFinding(Self.finding(of: $0)) }.compactMap(r.incident)
            .sorted { ($1.since, $0.kind) < ($0.since, $1.kind) }
            .map { WebDashboardDocument.IncidentItem(kind: $0.kind, severity: severity($0.severity), title: $0.title, start: $0.since, end: $0.end) }
        // Only the ten shown are scrubbed, each from a bounded prefix (scrubbing is regex work, and this runs per sample).
        let apps = AppUsage.aggregate((i.snapshot?.processes ?? []).filter { !i.excludeProcess($0) })
            .sorted { ($1.cpu, $0.name, $1.memory) < ($0.cpu, $1.name, $0.memory) }
            .prefix(topAppCount)
            .map { a in WebDashboardDocument.App(name: String(r.scrub(String(a.name.prefix(256))).prefix(64)), cpuPercent: a.cpu,
                                                 memoryBytes: Double(a.memory), energyWatts: a.energyWatts, count: a.processes) }
        let trimmed = i.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let mac = WebDashboardDocument.Mac(name: r.scrub(trimmed.isEmpty ? i.modelName : trimmed), model: i.hardwareModel,
                                           macos: i.macOS, app: i.appVersion, uptimeS: i.uptime)
        var history: [WebPoint]?, unavailable: String?
        switch i.history {
        case .none: break
        case .points(let p): history = p
        case .unavailable(let why): history = []; unavailable = why
        }
        return WebDashboardDocument(mac: mac, sampledAt: i.snapshot?.time, sampling: i.paused ? "paused" : "live", intervalS: i.intervalS,
                                    demo: i.demo ? true : nil, annunciator: lights, findings: findings, incidents: incidents,
                                    readings: i.snapshot.map(readings) ?? .missing("No sample yet"), topApps: apps,
                                    history: history, historyUnavailable: unavailable, point: i.point)
    }

    /// An incident as the finding it came from, for `excludeFinding` (which looks at the id).
    static func finding(of x: Incident) -> Finding {
        Finding(id: x.key, severity: x.severity, icon: x.icon, title: x.title, detail: x.detail, since: x.start, destination: x.destination)
    }

    static func readings(_ s: Snapshot) -> WebDashboardDocument.Readings {
        let m = s.memory, vm = FleetValue.missing("VM statistics unavailable")
        let vol = Analyzer.startupVolume(s)
        let fan = (s.power.fans ?? []).map(\.rpm).max()
        return .init(cpuPercent: FleetValue(s.cpu.total),
                     memoryPressurePercent: m.isMeasured ? FleetValue(m.pressure) : vm,
                     memoryUsedBytes: m.isMeasured ? FleetValue(Double(m.used)) : vm,
                     memoryTotalBytes: m.total > 0 ? FleetValue(Double(m.total)) : .missing("not reported"),
                     swapBytes: FleetValue(m.swapUsed),
                     diskReadBytesPerS: FleetValue(s.disk.readBps), diskWriteBytesPerS: FleetValue(s.disk.writeBps),
                     diskFreeBytes: vol.map { FleetValue(Double($0.available)) } ?? .missing("startup volume not found"),
                     netInBytesPerS: FleetValue(s.network.inBps), netOutBytesPerS: FleetValue(s.network.outBps),
                     systemWatts: FleetValue(s.power.systemWatts), hottestC: FleetValue(s.power.hottest),
                     thermalState: thermalNames.indices.contains(s.power.thermalState) ? thermalNames[s.power.thermalState] : nil,
                     gpuPercent: FleetValue(s.gpu),
                     batteryPercent: s.power.battery.map { FleetValue($0.percent) } ?? .missing("No battery"),
                     charging: s.power.battery?.isCharging,
                     fanRpm: fan.map { FleetValue($0) } ?? .missing("No fans"))
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder.fleet; e.keyEncodingStrategy = .convertToSnakeCase; return e
    }

    /// One line of JSON, at most `maxBytes`: over it, the oldest incidents go first, then the least busy apps, then
    /// the lowest-severity findings, and that list's `*_truncated` flag is set. History is never dropped.
    public static func encode(_ d: WebDashboardDocument) -> Data {
        let e = encoder
        var doc = d
        while true {
            let data = (try? e.encode(doc)) ?? Data("{\"v\":1}".utf8)
            guard data.count > maxBytes else { return data }
            // Drop in proportion to the overshoot so a huge list doesn't take hundreds of passes.
            let excess = Double(data.count - maxBytes) / Double(data.count)
            func drop<T>(_ list: inout [T]) { list.removeLast(max(1, min(list.count, Int(Double(list.count) * excess)))) }
            if !doc.incidents.isEmpty { drop(&doc.incidents); doc.incidentsTruncated = true }
            else if !doc.topApps.isEmpty { drop(&doc.topApps); doc.topAppsTruncated = true }
            else if !doc.findings.isEmpty { drop(&doc.findings); doc.findingsTruncated = true }
            else { return data }
        }
    }

    /// `historyPoints` buckets of `historyStep` seconds ending at `now`, oldest first. Each bucket is its latest
    /// frame; an empty bucket is a gap (nothing is interpolated).
    public static func history(frames: [Snapshot], now: Date) -> [WebPoint] {
        let sorted = frames.sorted { $0.time < $1.time }
        var out: [WebPoint] = [], j = 0
        for b in 0..<historyPoints {
            let end = now.addingTimeInterval(-Double(historyPoints - 1 - b) * historyStep), start = end.addingTimeInterval(-historyStep)
            var latest: Snapshot?
            while j < sorted.count, sorted[j].time <= end {
                if sorted[j].time > start { latest = sorted[j] }
                j += 1
            }
            out.append(latest.map(WebPoint.init) ?? .gap(at: end))
        }
        return out
    }

    /// The publish cadence: the sampling interval while a window is open, else the background one (at least 5 s,
    /// the Engine's hidden publish rate).
    public static func interval(visible: Bool, interval: Double, background: Double) -> Double {
        visible ? interval : max(background, 5)
    }
}

/// The marketing model name ("MacBook Pro") for the default page label; never the computer name.
public enum WebMacModel {
    public static func name(systemProfilerJSON: Data) -> String? {
        guard let j = try? JSONSerialization.jsonObject(with: systemProfilerJSON) as? [String: Any],
              let hw = (j["SPHardwareDataType"] as? [[String: Any]])?.first,
              let name = hw["machine_name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    /// Runs system_profiler (about 0.15 s): call off the main thread.
    public static func read() -> String {
        Shell.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"]).flatMap { name(systemProfilerJSON: Data($0.utf8)) } ?? "Mac"
    }
}
