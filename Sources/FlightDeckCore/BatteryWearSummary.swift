import Foundation
// Turns the per-day wear tallies (BatteryWear.swift) into the five known ageing factors, each with a level and a
// plain-English tip. Thresholds are deliberately conservative rules of thumb from lithium-ion ageing behaviour
// (calendar ageing speeds up at high charge and high temperature; deep discharges and cycling add cycle ageing). They
// say what is worth changing, not what has damaged this battery: no measurement here can attribute lost capacity.

public struct WearFactor: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case highCharge = "high_charge", heat, deepDischarge = "deep_discharges", cycling, chargeHold = "charge_hold" }
    /// `good`: helping; `low`/`moderate`/`high`: how much this contributes; `unknown`: not enough observation.
    public enum Level: String, Sendable { case good, low, moderate, high, unknown }
    public var id: String { kind.rawValue }
    public var kind: Kind
    public var title: String
    public var level: Level
    /// The measurement, short ("62% of plugged-in time").
    public var value: String
    /// What was measured and over how long.
    public var detail: String
    /// What would help, when something would.
    public var tip: String?
}

public struct BatteryWearSummary: Sendable {
    /// Days covered by the window and FlightDeck's observed hours in it.
    public var days: Int
    public var observedHours: Double
    public var totals: BatteryWearDay
    public var factors: [WearFactor]

    public static let windowDays = 30
    /// Less observation than this and a share is reported as unknown rather than as a number that means little.
    public static let minHours = 2.0

    /// Over the last `windowDays` of `history` that have wear tallies. `cyclesPerWeek` comes from the forecast.
    public static func compute(_ history: [BatteryDay], cyclesPerWeek: Double?, designCycles: Int?, cyclesRemaining: Int?) -> BatteryWearSummary {
        let withWear = history.filter { $0.wear != nil }
        let end = withWear.last?.start ?? Date()
        let window = withWear.filter { end.timeIntervalSince($0.start) < Double(windowDays) * 86_400 }
        let t = BatteryWearDay.total(window.compactMap(\.wear))
        let hours = t.observedSeconds / 3600, plugged = t.pluggedSeconds / 3600
        let over = "over \(window.count) day\(window.count == 1 ? "" : "s") (\(Self.hours(hours)) observed)"
        var f: [WearFactor] = []

        // 1. Time at high charge while plugged in.
        if plugged >= minHours {
            let share = t.pluggedHighSeconds / t.pluggedSeconds
            let level: WearFactor.Level = share >= 0.6 ? .high : share >= 0.3 ? .moderate : .low
            f.append(WearFactor(kind: .highCharge, title: "Time at high charge", level: level,
                                value: pct(share) + " of plugged-in time at 95% or more",
                                detail: "\(Self.hours(plugged)) plugged in \(over).",
                                tip: share >= 0.3 ? "It spends \(pct(share)) of plugged-in time at 95–100%. Sitting full is what ages a battery fastest at rest: Optimized Battery Charging or a charge limit (System Settings › Battery) would slow ageing." : nil))
        } else {
            f.append(unknown(.highCharge, "Time at high charge", "Needs at least \(Int(minHours)) hours plugged in while FlightDeck runs (has \(Self.hours(plugged)))."))
        }

        // 2. Heat.
        if t.tempSeconds >= minHours * 3600, let avg = t.averageTemp {
            let s35 = t.above35Seconds / t.tempSeconds, s40 = t.above40Seconds / t.tempSeconds
            let level: WearFactor.Level = s40 >= 0.02 || t.above40Seconds >= 3 * 3600 ? .high : s35 >= 0.1 ? .moderate : .low
            let maxText = t.tempMax.map { String(format: ", hottest %.1f °C", $0) } ?? ""
            f.append(WearFactor(kind: .heat, title: "Heat", level: level,
                                value: String(format: "average %.1f °C", avg) + maxText,
                                detail: "Above 35 °C: \(pct(s35)) (\(Self.hours(t.above35Seconds / 3600))); above 40 °C: \(pct(s40)) (\(Self.hours(t.above40Seconds / 3600))), \(over).",
                                tip: level == .low ? nil : "Heat speeds up ageing, especially at high charge. Keep vents clear and the Mac off soft surfaces and out of the sun; heavy work while charging warms the battery most."))
        } else {
            f.append(unknown(.heat, "Heat", "Needs at least \(Int(minHours)) hours of battery temperature readings."))
        }

        // 3. Deep discharges.
        if hours >= minHours {
            let level: WearFactor.Level = t.dischargesBelow10 >= 3 ? .high : t.dischargesBelow10 >= 1 || t.dischargesBelow20 >= 6 ? .moderate : .low
            f.append(WearFactor(kind: .deepDischarge, title: "Deep discharges", level: level,
                                value: "\(t.dischargesBelow20) below 20%, \(t.dischargesBelow10) below 10%",
                                detail: "Discharges FlightDeck saw \(over)" + (t.minPercent.map { String(format: "; lowest charge %.0f%%.", $0) } ?? "."),
                                tip: level == .low ? nil : "Running down below 10–20% strains the cells more than shallow use. Plugging in a little earlier is gentler; an occasional deep discharge is fine."))
        } else {
            f.append(unknown(.deepDischarge, "Deep discharges", "Needs at least \(Int(minHours)) hours of observation."))
        }

        // 4. Cycles per week (from the cycle counter, not the tallies).
        if let w = cyclesPerWeek {
            let level: WearFactor.Level = w > 7 ? .high : w > 4 ? .moderate : .low
            var detail = "From the battery's cycle counter over the last \(windowDays) days."
            if let r = cyclesRemaining, let d = designCycles, w > 0.05 {
                detail += String(format: " %d of its %d design cycles remain: about %@ at this rate.", r, d, Self.span(weeks: Double(r) / w))
            }
            f.append(WearFactor(kind: .cycling, title: "Cycling", level: level, value: String(format: "%.1f cycles a week", w), detail: detail,
                                tip: level == .low ? nil : "Each full cycle (100% of capacity drained, in any number of pieces) wears the battery a little. Staying plugged in for long desk sessions saves cycles, ideally with a charge limit."))
        } else {
            f.append(unknown(.cycling, "Cycling", "Needs cycle counts spanning at least a week."))
        }

        // 5. Charge limit / Optimized Charging: the hold detection, as a share of plugged-in time.
        if plugged >= minHours {
            let share = t.heldSeconds / t.pluggedSeconds
            let highShare = t.pluggedHighSeconds / t.pluggedSeconds
            let level: WearFactor.Level = share >= 0.2 ? .good : highShare >= 0.3 ? .moderate : .low
            f.append(WearFactor(kind: .chargeHold, title: "Charge limit / Optimized Charging", level: level,
                                value: share > 0 ? pct(share) + " of plugged-in time held below full" : "never seen holding below full",
                                detail: "Plugged in, below full and not charging \(over). Which feature held it isn't published.",
                                tip: level == .good ? "macOS is holding the charge below full for part of the time, which slows ageing." :
                                    highShare >= 0.3 ? "No charge hold was seen while it sat near full. Turning on Optimized Battery Charging, or a charge limit, would help." : nil))
        } else {
            f.append(unknown(.chargeHold, "Charge limit / Optimized Charging", "Needs at least \(Int(minHours)) hours plugged in while FlightDeck runs."))
        }
        return BatteryWearSummary(days: window.count, observedHours: hours, totals: t, factors: f)
    }

    static func unknown(_ k: WearFactor.Kind, _ title: String, _ why: String) -> WearFactor {
        WearFactor(kind: k, title: title, level: .unknown, value: "not enough data yet", detail: why, tip: nil)
    }
    static func pct(_ share: Double) -> String { String(format: "%.0f%%", share * 100) }
    static func hours(_ h: Double) -> String { h < 1 ? String(format: "%.0f min", h * 60) : h < 10 ? String(format: "%.1f h", h) : String(format: "%.0f h", h) }
    /// "8 months", "2.5 years".
    public static func span(weeks: Double) -> String {
        let months = weeks / 4.345
        if months < 1 { return String(format: "%.0f weeks", max(weeks, 1)) }
        if months < 24 { return String(format: "%.0f months", months) }
        return String(format: "%.1f years", months / 12)
    }
}
