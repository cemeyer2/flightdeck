import Foundation
// Fleet, part 1: the JSON a sharing Mac serves to its paired Macs. Deliberately small: identity, the vital signs, the
// latest findings and incidents (kind, severity and redacted wording only), and a coarse 30-minute history for
// sparklines. Nothing else about the Mac is ever put in these types: no processes, PIDs, command lines, user names,
// paths or network destinations. `FleetStatus.build` is the only place a Snapshot is turned into fleet data.

/// What any Mac on the local network may ask for without pairing: enough to show "FlightDeck on Charlie's MacBook Pro
/// — pair to view", nothing more.
public struct FleetHello: Codable, Sendable, Equatable {
    /// Protocol version; a viewer refuses anything it doesn't speak.
    public var proto: Int
    /// This Mac's random FlightDeck fleet ID (a UUID, not derived from hardware).
    public var id: String
    /// The computer name (System Settings › General › Sharing), as Bonjour already advertises it.
    public var name: String
    /// Whether the sharing Mac's user has opened a pairing window in Settings right now.
    public var pairingOpen: Bool
    public init(proto: Int = FleetProtocol.version, id: String, name: String, pairingOpen: Bool) {
        self.proto = proto; self.id = id; self.name = name; self.pairingOpen = pairingOpen
    }
}

public enum FleetProtocol {
    public static let version = 1
    /// The Bonjour service type advertised while sharing is on (listed in Info.plist's NSBonjourServices).
    public static let serviceType = "_flightdeck._tcp"
}

/// Who the sharing Mac is. Paired viewers only.
public struct FleetIdentity: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// `hw.model`, e.g. "Mac14,6".
    public var model: String
    /// "laptop", "mini", "studio", "pro", "imac" or "desktop", for the card's icon.
    public var kind: String
    public var macOS: String
    public var appVersion: String
    public init(id: String, name: String, model: String, kind: String, macOS: String, appVersion: String) {
        self.id = id; self.name = name; self.model = model; self.kind = kind; self.macOS = macOS; self.appVersion = appVersion
    }

    /// The icon family from `hw.model` (and whether there is a battery, which settles every laptop).
    public static func kind(model: String, hasBattery: Bool) -> String {
        if hasBattery || model.hasPrefix("MacBook") { return "laptop" }
        if model.hasPrefix("Macmini") { return "mini" }
        if model.hasPrefix("iMac") { return "imac" }
        if model.hasPrefix("MacPro") { return "pro" }
        // Apple silicon desktops are all "MacNN,N"; these are the Studio, mini and Pro identifiers so far.
        let studio: Set = ["Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac15,14", "Mac16,9"]
        let mini: Set = ["Macmini9,1", "Mac14,3", "Mac14,12", "Mac16,10", "Mac16,11"]
        if studio.contains(model) { return "studio" }
        if mini.contains(model) { return "mini" }
        if model == "Mac14,8" { return "pro" }
        return "desktop"
    }
}

/// A reading that is either a number or unavailable with a reason: never a fake 0.
public struct FleetValue: Codable, Sendable, Equatable {
    public var value: Double?
    public var reason: String?
    public init(_ value: Double?, reason: String? = nil) { self.value = value; self.reason = value == nil ? (reason ?? "not reported") : nil }
    public init(_ m: Measured<Double>) {
        switch m { case .value(let v): self.init(v); case .unavailable(let r): self.init(nil, reason: r) }
    }
    public static func missing(_ reason: String) -> FleetValue { FleetValue(nil, reason: reason) }
}

public struct FleetBattery: Codable, Sendable, Equatable {
    public var percent: Double
    public var charging: Bool
    public var onPower: Bool
    public init(percent: Double, charging: Bool, onPower: Bool) { self.percent = percent; self.charging = charging; self.onPower = onPower }
}

public struct FleetVitals: Codable, Sendable, Equatable {
    /// Total CPU busy, 0…100.
    public var cpu: FleetValue
    /// Memory pressure 0…100 and macOS's level (1 normal, 2 warning, 4 critical; nil when unmeasured).
    public var memoryPressure: FleetValue
    public var memoryLevel: Int?
    public var memoryUsed: FleetValue
    public var memoryTotal: FleetValue
    /// Hottest sensor, °C.
    public var hottest: FleetValue
    /// Startup volume free and total bytes.
    public var diskFree: FleetValue
    public var diskTotal: FleetValue
    /// nil on Macs without a battery (`batteryReason` says so).
    public var battery: FleetBattery?
    public var batteryReason: String?
    /// Seconds since boot.
    public var uptime: FleetValue
    /// ProcessInfo.ThermalState raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermalState: Int
    public var sampledAt: Date
    public init(cpu: FleetValue, memoryPressure: FleetValue, memoryLevel: Int?, memoryUsed: FleetValue, memoryTotal: FleetValue,
                hottest: FleetValue, diskFree: FleetValue, diskTotal: FleetValue, battery: FleetBattery?, batteryReason: String?,
                uptime: FleetValue, thermalState: Int, sampledAt: Date) {
        self.cpu = cpu; self.memoryPressure = memoryPressure; self.memoryLevel = memoryLevel; self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal; self.hottest = hottest; self.diskFree = diskFree; self.diskTotal = diskTotal
        self.battery = battery; self.batteryReason = batteryReason; self.uptime = uptime; self.thermalState = thermalState
        self.sampledAt = sampledAt
    }
}

/// A finding or incident as shared: the kind (the part of the finding ID before any ":", e.g. "mem-pressure"), never
/// the full ID (which can carry an app or PID), and redacted wording.
public struct FleetFinding: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(kind)|\(title)|\(since.timeIntervalSince1970)" }
    public var kind: String
    /// Finding.Severity raw value: 1 info, 2 caution, 3 warning.
    public var severity: Int
    public var icon: String
    public var title: String
    public var detail: String?
    public var since: Date
    /// Incidents only: when it ended (nil while ongoing; always nil for findings).
    public var end: Date?
    public init(kind: String, severity: Int, icon: String, title: String, detail: String?, since: Date, end: Date? = nil) {
        self.kind = kind; self.severity = severity; self.icon = icon; self.title = title; self.detail = detail; self.since = since; self.end = end
    }
}

/// One coarse history point (every `FleetHistory.step` seconds).
public struct FleetPoint: Codable, Sendable, Equatable {
    public var t: Date
    public var cpu: Double?
    public var memoryPressure: Double?
    public var hottest: Double?
    public init(t: Date, cpu: Double?, memoryPressure: Double?, hottest: Double?) {
        self.t = t; self.cpu = cpu; self.memoryPressure = memoryPressure; self.hottest = hottest
    }
    public init(_ s: Snapshot) {
        self.init(t: s.time, cpu: s.cpu.total.value, memoryPressure: s.memory.isMeasured ? s.memory.pressure.value : nil, hottest: s.power.hottest.value)
    }
}

/// Everything a paired viewer gets in one request.
public struct FleetStatus: Codable, Sendable, Equatable {
    public var identity: FleetIdentity
    public var vitals: FleetVitals?
    /// Why `vitals` is missing (e.g. still starting).
    public var vitalsReason: String?
    public var findings: [FleetFinding]
    public var incidents: [FleetFinding]
    public var history: [FleetPoint]
    public init(identity: FleetIdentity, vitals: FleetVitals?, vitalsReason: String? = nil, findings: [FleetFinding],
                incidents: [FleetFinding], history: [FleetPoint]) {
        self.identity = identity; self.vitals = vitals; self.vitalsReason = vitals == nil ? (vitalsReason ?? "No sample yet") : nil
        self.findings = findings; self.incidents = incidents; self.history = history
    }

    /// Worst current finding first (then newest).
    public var worst: FleetFinding? { findings.max { ($0.severity, $1.since) < ($1.severity, $0.since) } }

    public static let maxFindings = 12, maxIncidents = 20

    /// Builds what is served from the live state. Findings and incidents pass through `FleetRedaction`, which drops
    /// private kinds (camera/mic, destinations) and scrubs paths, addresses, host names and the user's names.
    public static func build(identity: FleetIdentity, snapshot: Snapshot?, findings: [Finding], incidents: [Incident],
                             history: [FleetPoint], uptime: TimeInterval?, redaction: FleetRedaction) -> FleetStatus {
        let shared = findings.compactMap(redaction.finding).sorted { ($0.severity, $0.since) > ($1.severity, $1.since) }
        let recent = incidents.sorted { $0.start > $1.start }.compactMap(redaction.incident)
        return FleetStatus(identity: identity, vitals: snapshot.map { vitals($0, uptime: uptime) }, findings: Array(shared.prefix(maxFindings)),
                           incidents: Array(recent.prefix(maxIncidents)), history: history)
    }

    public static func vitals(_ s: Snapshot, uptime: TimeInterval?) -> FleetVitals {
        let m = s.memory
        let vol = Analyzer.startupVolume(s)
        let noVol = FleetValue.missing("startup volume not found")
        let batt = s.power.battery.map { FleetBattery(percent: $0.percent, charging: $0.isCharging, onPower: $0.externalConnected) }
        return FleetVitals(cpu: FleetValue(s.cpu.total),
                           memoryPressure: m.isMeasured ? FleetValue(m.pressure) : .missing("VM statistics unavailable"),
                           memoryLevel: m.isMeasured ? m.pressureLevel : nil,
                           memoryUsed: m.isMeasured ? FleetValue(Double(m.used)) : .missing("VM statistics unavailable"),
                           memoryTotal: m.total > 0 ? FleetValue(Double(m.total)) : .missing("not reported"),
                           hottest: FleetValue(s.power.hottest),
                           diskFree: vol.map { FleetValue(Double($0.available)) } ?? noVol,
                           diskTotal: vol.map { FleetValue(Double($0.capacity)) } ?? noVol,
                           battery: batt, batteryReason: batt == nil ? "No battery" : nil,
                           uptime: uptime.map { FleetValue($0) } ?? .missing("boot time not reported"),
                           thermalState: s.power.thermalState, sampledAt: s.time)
    }
}
