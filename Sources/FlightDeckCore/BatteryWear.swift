import Foundation
// What wears a battery, measured per day from the snapshots FlightDeck already takes. These are the known lithium-ion
// ageing factors (time held near full charge, heat, deep discharges, cycling); a battery's actual ageing also depends
// on its chemistry and history, so they are presented as contributors, never as a diagnosis.
//
// Cost: `BatteryWearCounter.ingest` is O(1) per snapshot: a few additions into the open day's `BatteryWearDay`, kept in
// `DayRecord.batteryWear` (DailyLog.swift). No new sampling: battery %, plug state and temperature are already in each
// snapshot's `PowerSample.battery`; the hold check reuses `ChargeState.assess` on the same reading.

/// One day's battery-wear tallies. Seconds count only real sampling steps (gaps such as sleep are excluded, as for
/// `DayRecord.observedSeconds`), so shares are of the time FlightDeck saw, not of the whole day.
public struct BatteryWearDay: Codable, Sendable, Hashable {
    /// Seconds with a battery reading, and how many of them were on external power.
    public var observedSeconds = 0.0
    public var pluggedSeconds = 0.0
    /// Plugged in at 95% charge or more: the high state of charge that ages lithium-ion cells fastest at rest.
    public var pluggedHighSeconds = 0.0
    /// Plugged in, below full and not charging (`ChargeState.held`): Optimized Battery Charging, a charge limit, or a
    /// charger condition holding the charge down.
    public var heldSeconds = 0.0
    /// Seconds with a battery temperature reading; the time-weighted sum (°C × s) for the average; the hottest; and
    /// the time above 35 °C and 40 °C (the bands where heat-driven ageing accelerates).
    public var tempSeconds = 0.0
    public var tempSum = 0.0
    public var tempMax: Double?
    public var above35Seconds = 0.0
    public var above40Seconds = 0.0
    /// Discharges (on battery) that went below 20% and below 10%. A discharge counts once; the next one counts after
    /// the charge has been back above the threshold by 10 points (see `BatteryWearCounter`).
    public var dischargesBelow20 = 0
    public var dischargesBelow10 = 0
    /// Lowest charge seen this day, %.
    public var minPercent: Double?

    public init() {}

    /// Average battery temperature while measured, °C.
    public var averageTemp: Double? { tempSeconds > 0 ? tempSum / tempSeconds : nil }

    // Decoded field by field with defaults, so a field added later never makes an older file unreadable (synthesized
    // Decodable would require every non-optional key).
    enum CodingKeys: String, CodingKey {
        case observedSeconds, pluggedSeconds, pluggedHighSeconds, heldSeconds, tempSeconds, tempSum, tempMax
        case above35Seconds, above40Seconds, dischargesBelow20, dischargesBelow10, minPercent
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? 0 }
        observedSeconds = try d(.observedSeconds); pluggedSeconds = try d(.pluggedSeconds)
        pluggedHighSeconds = try d(.pluggedHighSeconds); heldSeconds = try d(.heldSeconds)
        tempSeconds = try d(.tempSeconds); tempSum = try d(.tempSum); tempMax = try c.decodeIfPresent(Double.self, forKey: .tempMax)
        above35Seconds = try d(.above35Seconds); above40Seconds = try d(.above40Seconds)
        dischargesBelow20 = try c.decodeIfPresent(Int.self, forKey: .dischargesBelow20) ?? 0
        dischargesBelow10 = try c.decodeIfPresent(Int.self, forKey: .dischargesBelow10) ?? 0
        minPercent = try c.decodeIfPresent(Double.self, forKey: .minPercent)
    }

    /// Sums several days (for a window's totals). Maxima and minima take the extreme.
    public static func total(_ days: [BatteryWearDay]) -> BatteryWearDay {
        var t = BatteryWearDay()
        for d in days {
            t.observedSeconds += d.observedSeconds; t.pluggedSeconds += d.pluggedSeconds
            t.pluggedHighSeconds += d.pluggedHighSeconds; t.heldSeconds += d.heldSeconds
            t.tempSeconds += d.tempSeconds; t.tempSum += d.tempSum
            if let m = d.tempMax { t.tempMax = max(t.tempMax ?? m, m) }
            t.above35Seconds += d.above35Seconds; t.above40Seconds += d.above40Seconds
            t.dischargesBelow20 += d.dischargesBelow20; t.dischargesBelow10 += d.dischargesBelow10
            if let m = d.minPercent { t.minPercent = min(t.minPercent ?? m, m) }
        }
        return t
    }
}

/// The O(1) accumulator. Holds only the deep-discharge hysteresis between snapshots (not persisted: after a relaunch
/// mid-discharge below 20%, that discharge can be counted a second time).
public struct BatteryWearCounter: Sendable {
    /// Charge at or above which a plugged-in battery counts as "high".
    public static let highPercent = 95.0
    public static let deepThresholds = (shallow: 20.0, deep: 10.0)
    /// Points above a threshold the charge must regain before the next discharge below it counts again, so a charge
    /// wobbling around 19–20% is one discharge, not many.
    public static let rearm = 10.0
    private var armed20 = true, armed10 = true

    public init() {}

    /// Folds one snapshot into `day`. `dt` is the seconds the snapshot stands for (0 after a gap: extremes and
    /// crossings still count, durations don't).
    public mutating func ingest(_ s: Snapshot, dt: Double, into day: inout BatteryWearDay?) {
        guard let b = s.power.battery else { return }
        var w = day ?? BatteryWearDay()
        let pct = b.percent
        w.observedSeconds += dt
        if b.externalConnected {
            w.pluggedSeconds += dt
            if pct >= Self.highPercent { w.pluggedHighSeconds += dt }
            if case .held = ChargeState.assess(battery: b, details: s.power.charging, pmset: nil) { w.heldSeconds += dt }
        }
        if let t = b.temperature, t > -40, t < 100 {   // outside that range it's a gauge placeholder, not a temperature
            w.tempSeconds += dt; w.tempSum += t * dt
            w.tempMax = max(w.tempMax ?? t, t)
            if t > 35 { w.above35Seconds += dt }
            if t > 40 { w.above40Seconds += dt }
        }
        w.minPercent = min(w.minPercent ?? pct, pct)
        let onBattery = !b.externalConnected
        if onBattery, pct < Self.deepThresholds.shallow, armed20 { w.dischargesBelow20 += 1; armed20 = false }
        if onBattery, pct < Self.deepThresholds.deep, armed10 { w.dischargesBelow10 += 1; armed10 = false }
        if pct >= Self.deepThresholds.shallow + Self.rearm { armed20 = true }
        if pct >= Self.deepThresholds.deep + Self.rearm { armed10 = true }
        day = w
    }
}
