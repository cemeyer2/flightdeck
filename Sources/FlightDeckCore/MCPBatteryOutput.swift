import Foundation
// Output of the `battery` MCP tool: the battery's facts now, condition and service status, the health forecast (or
// exactly why there isn't one) and the wear factors, from the same `BatteryReport` the app's Battery health panel uses.
// Read-only. Desktops get a one-line "no battery" answer rather than a page of nulls.

extension MCPTools {
    func battery() async throws -> JSON {
        guard let s = await source.snapshot() else { throw noSample() }
        guard let b = s.power.battery else {
            return object([("summary", .str("This Mac has no battery.")), ("has_battery", .bool(false))])
        }
        let h = await source.batteryHistory()
        let condition = batteryCondition()
        let r = BatteryReport(battery: b, facts: s.power.charging?.facts, condition: condition, history: h?.days ?? [], lifetime: h?.lifetime)
        let f = r.forecast

        let facts: JSON = .object(dropping: [
            ("charge_percent", F.r1(b.percent)), ("charging", .bool(b.isCharging)), ("plugged_in", .bool(b.externalConnected)),
            ("health_percent", r.health.map(F.r1) ?? F.unavailable("capacity not reported")),
            ("cycles", b.cycleCount.map(JSON.int) ?? F.unavailable("not reported")),
            ("design_cycles", r.designCycles.map(JSON.int)),
            ("design_capacity_mah", (r.facts?.designCapacity ?? b.designCapacity).map(JSON.int)),
            ("full_charge_capacity_mah", r.facts?.fullChargeCapacity.map(JSON.int)),
            ("temperature_c", b.temperature.map(F.r1)),
            ("condition", condition.map(JSON.str) ?? F.unavailable("system_profiler didn't report it")),
            ("lifetime", r.lifetime.map { l in
                .object(dropping: [("max_temp_c", l.maxTemp.map(F.r1)), ("min_temp_c", l.minTemp.map(F.r1)),
                                   ("operating_hours", l.operatingHours.map(JSON.int)), ("as_of", F.time(l.asOf)),
                                   ("source", "battery gauge, via macOS's power log")])
            }),
        ])

        var forecast: [(String, JSON?)] = [("status", .str(Self.statusName(f.status))), ("summary", .str(r.forecastSentence)),
                                           ("days_of_history", .int(f.points.count)), ("span_days", .int(Int(f.spanDays.rounded()))),
                                           ("days_from_macos_power_log", r.seededDays > 0 ? .int(r.seededDays) : nil),
                                           ("battery_replaced_on", f.replacedOn.map(F.time))]
        if case let .insufficient(_, weeks) = f.status { forecast.append(("weeks_needed", weeks.map(JSON.int))) }
        if let py = f.perYear, f.line != nil {
            forecast.append(("trend_points_per_year", F.r1(py)))
            if let range = f.perYearRange { forecast.append(("trend_range_95", .array([F.r1(range.low), F.r1(range.high)]))) }
        }
        if f.status == .forecast {
            forecast += [("reaches_80_percent", f.date80.map(Self.day) ?? .str("more than \(Int(BatteryForecast.horizonYears)) years")),
                         ("reaches_80_percent_range_95", .array([f.date80Early.map(Self.day) ?? .null,
                                                                 f.date80Late.map(Self.day) ?? .str("not bounded by the data")]))]
        }
        if let c = f.cycles80 {
            forecast.append(("cycles_at_80_percent", .int(c)))
            if let rg = f.cycles80Range { forecast.append(("cycles_at_80_percent_range_95", .array([rg.low.map(JSON.int) ?? .null, rg.high.map(JSON.int) ?? .null]))) }
        }
        forecast += [("cycles_remaining_to_design", f.cyclesRemaining.map(JSON.int)),
                     ("cycles_per_week", f.cyclesPerWeek.map(F.r1)),
                     ("design_cycles_reached_around", f.designCyclesDate.map(Self.day)),
                     ("method", "Theil–Sen line through daily health (weekly medians past 120 days), 95% range from Sen's slope interval; the range assumes independent daily readings, so treat it as indicative.")]

        let factors: JSON = .array(r.wear.factors.map { w in
            .object(dropping: [("factor", .str(w.kind.rawValue)), ("level", .str(w.level.rawValue)), ("value", .str(w.value)),
                               ("detail", .str(w.detail)), ("tip", w.tip.map(JSON.str))])
        })
        let summary = [String(format: "Health %@, %@ cycles.", r.health.map { String(format: "%.0f%%", $0) } ?? "unknown", b.cycleCount.map(String.init) ?? "unknown"),
                       r.forecastSentence].joined(separator: " ")
        return object([
            ("summary", .str(summary)), ("has_battery", .bool(true)), ("facts", facts),
            ("service_status", r.serviceStatus.map(JSON.str)),
            ("forecast", .object(dropping: forecast)),
            ("wear_factors", factors),
            ("wear_window_days", .int(r.wear.days)),
            ("wear_note", "Known contributors to lithium-ion ageing, measured from FlightDeck's own samples while it runs; they are not a diagnosis of this battery."),
        ])
    }

    static func statusName(_ s: BatteryForecast.Status) -> String {
        switch s { case .forecast: "forecast"; case .insufficient: "insufficient_data"; case .notDeclining: "not_declining"; case .belowThreshold: "below_80_percent" }
    }
    /// "2027-08-14": a day is as precise as a forecast of this kind deserves.
    static func day(_ d: Date) -> JSON {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return .str(String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
    }
}
