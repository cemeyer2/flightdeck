// Performance › Energy › Battery health: the forecast (history, trend and 95% band against the 80% service
// threshold), what's wearing the battery, and condition and service status. Placed in Energy, right under Battery
// facts, rather than in Trends: it is about this battery and reads its live facts and condition (already fetched by
// ChargingSection), and its history reaches past Trends' 90-day window. Trends' battery chart points here.
// The report is built off the main thread by ChargingExtras (FlightDeckCore/BatteryReport.swift); demo mode shows
// DemoBattery's invented 400 days.
import SwiftUI
import FlightDeckCore

struct BatteryHealthPanel: View {
    @Environment(\.palette) var p
    /// nil while the first load runs.
    var report: BatteryReport?

    var body: some View {
        if let r = report {
            let f = r.forecast
            Panel(title: "Battery health", trailing: trailing(r)) {
                HStack(spacing: 28) {
                    Readout(label: "Health now", value: r.health.map { String(format: "%.1f", $0) }, unit: "%", color: p.accent, size: 16)
                    Readout(label: "Reaches 80%", value: reaches(f), size: 16)
                    Readout(label: "95% range", value: rangeText(f), size: 12)
                    Readout(label: "Trend", value: f.line == nil ? nil : f.perYear.map { String(format: "%+.1f", $0) }, unit: "pts/yr", size: 16)
                    Readout(label: "Cycles left", value: f.cyclesRemaining.map { r in f.designCycles.map { "\(r) of \($0)" } ?? "\(r)" }, size: 16)
                    Readout(label: "Cycles/week", value: f.cyclesPerWeek.map { String(format: "%.1f", $0) }, size: 16)
                    Spacer()
                }
                if r.history.count >= 2 {
                    BatteryForecastChart(forecast: f, history: r.history)
                }
                Label(r.forecastSentence, systemImage: f.status == .forecast ? "chart.line.downtrend.xyaxis" : "info.circle")
                    .font(.system(size: 12)).foregroundStyle(f.status == .forecast ? p.text : p.dim)
                if let c80 = f.cycles80 {
                    Text("Against cycles, the trend reaches 80% at about \(c80) cycles" + (f.cycles80Range.map { rg in " (range \(rg.low.map(String.init) ?? "?")–\(rg.high.map(String.init) ?? "not bounded"))" } ?? "") + ".")
                        .font(.caption).foregroundStyle(p.dim)
                }
                if let rep = f.replacedOn {
                    Text("A battery replacement was detected on \(rep.formatted(date: .abbreviated, time: .omitted)); the forecast uses only the readings since.")
                        .font(.caption).foregroundStyle(p.dim)
                }
                Text(sourcesNote(r)).font(.caption).foregroundStyle(p.dim)
                Divider().overlay(p.grid)
                WearFactorList(summary: r.wear)
                Divider().overlay(p.grid)
                Text("CONDITION AND SERVICE").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
                if let s = r.serviceStatus { Text(s).font(.system(size: 12)) }
                if let l = r.lifetime { Text(lifetimeText(l)).font(.caption).foregroundStyle(p.dim) }
            }
        } else {
            Panel(title: "Battery health") { Text("Loading the battery's history…").foregroundStyle(p.dim) }
        }
    }

    func trailing(_ r: BatteryReport) -> String {
        let n = r.forecast.points.count
        return "\(n) day\(n == 1 ? "" : "s") of history"
    }

    func reaches(_ f: BatteryForecast) -> String? {
        switch f.status {
        case .forecast: return f.date80.map(BatteryReport.monthYear) ?? ">\(Int(BatteryForecast.horizonYears)) yr"
        case .belowThreshold: return "reached"
        case .insufficient, .notDeclining: return "no forecast"
        }
    }

    func rangeText(_ f: BatteryForecast) -> String? {
        guard f.status == .forecast, let e = f.date80Early else { return nil }
        return BatteryReport.monthYear(e) + " –\n" + (f.date80Late.map(BatteryReport.monthYear) ?? "not bounded")
    }

    func sourcesNote(_ r: BatteryReport) -> String {
        var s = "Health is nominal capacity ÷ design capacity, one reading a day while FlightDeck runs. The trend is a Theil–Sen line (robust to the 1% steps and day-to-day wobble); the range is Sen's 95% interval for its slope, indicative only, since batteries don't age in a straight line."
        if r.seededDays > 0 { s += " \(r.seededDays) earlier day\(r.seededDays == 1 ? "" : "s") (hollow dots) come from macOS's own power log." }
        if r.history.contains(where: { $0.source == .demo }) { s += " Demo mode: this history is invented." }
        return s
    }

    func lifetimeText(_ l: BatteryLifetime) -> String {
        var parts: [String] = []
        if let t = l.maxTemp { parts.append("hottest " + Fmt.tempNumber(t, digits: 0) + TemperatureUnit.current.symbol) }
        if let t = l.minTemp { parts.append("coldest " + Fmt.tempNumber(t, digits: 0) + TemperatureUnit.current.symbol) }
        if let h = l.operatingHours { parts.append(String(format: "%@ hours in operation (%.1f years)", h.formatted(), Double(h) / 8766)) }
        return "Over its life, the battery gauge has recorded: " + parts.joined(separator: ", ") + " (macOS's power log, " + l.asOf.formatted(date: .abbreviated, time: .omitted) + ")."
    }
}

/// The five wear factors, each with a level badge (icon + word, never colour alone), what was measured and a tip.
struct WearFactorList: View {
    @Environment(\.palette) var p
    var summary: BatteryWearSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WHAT'S WEARING IT").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
                Spacer()
                Text(summary.days == 0 ? "no wear readings yet" : "last \(summary.days) day\(summary.days == 1 ? "" : "s") with readings").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
            }
            Text("Known contributors to lithium-ion ageing, measured from FlightDeck's samples while it runs. They show what is worth changing; they can't say what has worn this particular battery.")
                .font(.caption).foregroundStyle(p.dim)
            ForEach(summary.factors) { f in
                HStack(alignment: .top, spacing: 10) {
                    badge(f.level).frame(width: 92, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(f.title).font(.system(size: 12, weight: .semibold))
                            Text(f.value).font(.system(size: 12, design: .monospaced))
                        }
                        Text(f.detail).font(.caption).foregroundStyle(p.dim)
                        if let t = f.tip { Text(t).font(.caption) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    func badge(_ l: WearFactor.Level) -> some View {
        let (icon, word, color): (String, String, Color) = switch l {
        case .good: ("checkmark.circle.fill", "helping", p.accent)
        case .low: ("circle", "low", p.dim)
        case .moderate: ("exclamationmark.circle", "moderate", p.warn)
        case .high: ("exclamationmark.triangle.fill", "high", p.crit)
        case .unknown: ("questionmark.circle", "unknown", p.dim)
        }
        return Label(word, systemImage: icon).font(.system(size: 11, design: .monospaced)).foregroundStyle(color)
    }
}
