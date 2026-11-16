import Foundation
// Per-charge drain attribution: "since unplugged 2 h 10 min ago: Photos 31%, Safari 18%…". `DailyLog` keeps one
// `ChargeSession` open while the Mac runs on battery, adding each app's billed energy (from the per-process counters
// that are already sampled) and the measured system energy. When the Mac is plugged in the session closes and is kept
// as the last one, so the panel can still answer "where did my last charge go?".

/// One stretch on battery power.
public struct ChargeSession: Codable, Sendable, Hashable {
    public struct App: Codable, Sendable, Hashable { public var name: String; public var icon: String; public var wattHours: Double }
    public var start: Date
    /// True when FlightDeck saw the unplug itself. False when it started (or relaunched) already on battery, so the
    /// session only covers the time since then.
    public var sawUnplug: Bool
    public var startPercent: Double?
    /// When it ended (plugged in); nil while still on battery.
    public var end: Date?
    public var lastTime: Date
    public var lastPercent: Double?
    /// Measured system energy on battery, Wh (nil on Macs that don't report system power).
    public var systemWh: Double?
    /// Billed energy per app (`AppUsage` key), Wh.
    public var apps: [String: App] = [:]

    public init(start: Date, sawUnplug: Bool, percent: Double?) {
        self.start = start; self.sawUnplug = sawUnplug; startPercent = percent; lastTime = start; lastPercent = percent
    }

    /// Battery points used (never negative). nil when the charge wasn't readable at both ends.
    public var percentUsed: Double? { startPercent.flatMap { s in lastPercent.map { max(s - $0, 0) } } }
    public var duration: TimeInterval { (end ?? lastTime).timeIntervalSince(start) }

    /// Each app's share of the energy, biggest first. Shares are of the measured system energy when the Mac reports
    /// it (so the remainder is "display, macOS and others"), else of the total billed to apps.
    public func attribution(top: Int = 8) -> DrainAttribution {
        let billed = apps.values.reduce(0) { $0 + $1.wattHours }
        // Billed energy can slightly exceed the system meter (different sources); the larger figure keeps shares ≤ 100%.
        let total = systemWh.map { max($0, billed) } ?? billed
        let rows = apps.map { k, a in DrainAttribution.Row(id: k, name: a.name, icon: a.icon, wattHours: a.wattHours, share: total > 0 ? a.wattHours / total : 0) }
            .filter { $0.wattHours > 0 }.sorted { $0.wattHours > $1.wattHours }
        let shown = Array(rows.prefix(top))
        let shownWh = shown.reduce(0) { $0 + $1.wattHours }
        return DrainAttribution(rows: shown, totalWh: total > 0 ? total : nil, ofSystem: systemWh != nil,
                                otherShare: total > 0 ? max(total - shownWh, 0) / total : nil)
    }
}

/// The answer the panel shows. `rows` are the top apps; `otherShare` is everything else (other apps and, when shares
/// are of system energy, the display and macOS).
public struct DrainAttribution: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable { public var id: String; public var name: String; public var icon: String; public var wattHours: Double; public var share: Double }
    public var rows: [Row]
    public var totalWh: Double?
    /// Whether shares are of measured system energy (true) or of the energy billed to apps (false).
    public var ofSystem: Bool
    public var otherShare: Double?

    /// "Photos 31%, Safari 18%, Mail 6%" (apps under 1% left out).
    public var summary: String {
        rows.filter { $0.share >= 0.01 }.prefix(5).map { "\($0.name) \(Int(($0.share * 100).rounded()))%" }.joined(separator: ", ")
    }
}

/// What `DailyLog` publishes about battery sessions.
public struct ChargeStatus: Sendable {
    /// Open while on battery.
    public var current: ChargeSession?
    /// The most recent completed session.
    public var last: ChargeSession?
}
