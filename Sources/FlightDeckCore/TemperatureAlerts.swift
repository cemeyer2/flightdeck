import Foundation
// User temperature alerts: "CPU above 95 °C for 2 minutes". One rule per sensor family, set in Settings › Alerts and
// stored in °C (the threshold is shown in the user's unit). A rule that holds becomes an ordinary Finding, so the
// banner, notifications (with their mutes and cooldown), the annunciator and the Flight Log treat it like any other.

public struct TemperatureAlertRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String { family.rawValue }
    /// A family from `SensorGroup.families` (CPU covers performance, efficiency and other CPU sensors).
    public var family: SensorGroup
    public var enabled: Bool
    /// °C. The family's hottest sensor must stay above this.
    public var thresholdC: Double
    /// For at least this long.
    public var minutes: Double
    public init(family: SensorGroup, enabled: Bool, thresholdC: Double, minutes: Double) {
        self.family = family; self.enabled = enabled; self.thresholdC = thresholdC; self.minutes = minutes
    }

    /// Every rule starts off. The thresholds are where each part is clearly hot, not yet at its limit: Apple-silicon
    /// CPUs and GPUs run up to ~100-105 °C before throttling hard, SSDs start slowing at ~70-80 °C, and lithium
    /// batteries age fastest above ~45 °C.
    public static let defaults: [TemperatureAlertRule] = [
        .init(family: .cpu, enabled: false, thresholdC: 95, minutes: 2),
        .init(family: .gpu, enabled: false, thresholdC: 90, minutes: 2),
        .init(family: .soc, enabled: false, thresholdC: 95, minutes: 2),
        .init(family: .ssd, enabled: false, thresholdC: 70, minutes: 5),
        .init(family: .battery, enabled: false, thresholdC: 45, minutes: 5),
    ]

    public static let defaultsKey = "temperatureAlerts"

    /// Stored rules merged over the defaults, so families added later still appear (off). Bad data → defaults.
    public static func load(_ data: Data?) -> [TemperatureAlertRule] {
        let saved = data.flatMap { try? JSONDecoder().decode([TemperatureAlertRule].self, from: $0) } ?? []
        let byFamily = Dictionary(saved.map { ($0.family, $0) }, uniquingKeysWith: { a, _ in a })
        return defaults.map { byFamily[$0.family] ?? $0 }
    }
    public static func save(_ rules: [TemperatureAlertRule]) -> Data? { try? JSONEncoder().encode(rules) }
}

/// Evaluates the rules once per sample. Not thread-safe: owned by ThermalWatch, which locks around it.
public final class TemperatureAlertMonitor {
    public var rules: [TemperatureAlertRule] = []
    /// Once firing, a rule clears only when the temperature drops this far below the threshold, so a reading hovering
    /// at the line doesn't end and restart the finding (and its Flight Log incident) every few seconds.
    static let hysteresis = 2.0
    /// When each family went above its threshold, and which are currently firing.
    private var above: [SensorGroup: Date] = [:]
    private var firing: Set<SensorGroup> = []
    private var last: Date?

    public init() {}

    /// `readings` are the families' hottest sensors (SensorCatalog.families) at time `t`.
    public func ingest(_ readings: [GroupReading], at t: Date) -> [Finding] {
        // A gap (sleep, paused sampling) means we don't know the temperature was high throughout: start over.
        if let last, t.timeIntervalSince(last) > 120 { above = [:]; firing = [] }
        last = t
        let byFamily = Dictionary(readings.map { ($0.family, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Finding] = []
        for r in rules {
            guard r.enabled, let g = byFamily[r.family] else { above[r.family] = nil; firing.remove(r.family); continue }
            let limit = firing.contains(r.family) ? r.thresholdC - Self.hysteresis : r.thresholdC
            guard g.max > limit else { above[r.family] = nil; firing.remove(r.family); continue }
            let start = above[r.family] ?? t
            above[r.family] = start
            guard t.timeIntervalSince(start) >= r.minutes * 60 else { continue }
            firing.insert(r.family)
            let mins = r.minutes == 1 ? "1 minute" : "\(Int(r.minutes)) minutes"
            // `since` is when the temperature crossed the line, so notifications and the Flight Log date it correctly.
            out.append(Finding(id: "temp-alert:\(r.family.rawValue)", severity: .caution, icon: "thermometer.high",
                               title: "\(r.family.title) is above \(Fmt.temp(r.thresholdC)): \(Fmt.temp(g.max))",
                               detail: "Your alert: \(r.family.title) above \(Fmt.temp(r.thresholdC)) for \(mins). Hottest sensor: \(g.hottest).",
                               since: start, destination: "Performance:Thermals"))
        }
        return out
    }
}
