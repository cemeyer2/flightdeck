import Foundation
// Everything the Battery health panel and the `battery` MCP tool show, built in one place so both say the same thing:
// the battery's facts now, its condition and service status, the forecast (BatteryForecast.swift) and the wear
// factors (BatteryWearSummary.swift). Pure: the caller passes in the live reading, the history and the condition.

public struct BatteryReport: Sendable {
    /// nil on Macs without a battery; everything else is then empty.
    public var battery: BatteryInfo?
    public var facts: BatteryFacts?
    /// system_profiler's condition ("Good", "Service Recommended", …); nil when not reported or not read yet.
    public var condition: String?
    public var history: [BatteryDay]
    public var lifetime: BatteryLifetime?
    public var forecast: BatteryForecast
    public var wear: BatteryWearSummary

    public var hasBattery: Bool { battery != nil }
    /// Health now: the live reading, else the latest in the history.
    public var health: Double? { battery?.health ?? history.last(where: { $0.health != nil })?.health }
    public var cycles: Int? { battery?.cycleCount ?? forecast.currentCycles }
    public var designCycles: Int? { facts?.designCycles }
    /// Days of history that came from macOS's power log rather than FlightDeck's own readings.
    public var seededDays: Int { history.filter { $0.source == .macOS }.count }

    public init(battery: BatteryInfo?, facts: BatteryFacts?, condition: String?, history: [BatteryDay], lifetime: BatteryLifetime?) {
        self.battery = battery; self.facts = facts; self.condition = condition; self.lifetime = lifetime
        // A desktop never shows a history (a stored one would be from another Mac's files, or none at all).
        self.history = battery == nil ? [] : history
        forecast = BatteryForecast.compute(self.history, designCycles: facts?.designCycles, currentCycles: battery?.cycleCount)
        wear = BatteryWearSummary.compute(self.history, cyclesPerWeek: forecast.cyclesPerWeek, designCycles: facts?.designCycles,
                                          cyclesRemaining: forecast.cyclesRemaining)
    }

    /// Plain-English service status from what macOS reports and the usual thresholds; nil without a battery.
    public var serviceStatus: String? {
        guard hasBattery else { return nil }
        var parts: [String] = []
        if let c = condition {
            parts.append(c.lowercased() == "good" || c.lowercased() == "normal" ? "macOS reports the battery's condition as \(c)." :
                            "macOS reports the battery's condition as \"\(c)\": Apple suggests having it checked.")
        } else {
            parts.append("macOS's battery condition isn't available.")
        }
        if let h = health {
            parts.append(h <= BatteryForecast.threshold
                         ? String(format: "Health is %.0f%%, at or below the 80%% where Apple typically considers a battery consumed (worth replacing).", h)
                         : String(format: "Health is %.0f%%, above the 80%% service threshold.", h))
        }
        if let c = cycles, let d = designCycles {
            parts.append(c >= d ? "It has passed its \(d)-cycle design count (\(c) cycles)." : "\(c) of \(d) design cycles used.")
        }
        return parts.joined(separator: " ")
    }

    /// The forecast in one sentence (shared by the panel and the MCP tool).
    public var forecastSentence: String {
        let f = forecast
        switch f.status {
        case let .insufficient(needed, _): return needed
        case let .notDeclining(why): return why
        case .belowThreshold: return "Health is already at or below 80%."
        case .forecast:
            if f.beyondHorizon { return "At the current trend it stays above 80% for more than \(Int(BatteryForecast.horizonYears)) years." }
            let d = f.date80.map(Self.monthYear) ?? "—"
            let early = f.date80Early.map(Self.monthYear), late = f.date80Late.map(Self.monthYear) ?? "much later (not ruled out by the data)"
            return "Projected to reach 80% around \(d)" + (early.map { " (95% range: \($0) to \(late))" } ?? "") + "."
        }
    }

    public static func monthYear(_ d: Date) -> String {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM yyyy"); return f.string(from: d)
    }
}
