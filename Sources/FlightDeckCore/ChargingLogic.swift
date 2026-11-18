import Foundation
// Charging logic on top of the parsed readings: the power flow (adapter → Mac / battery, or battery → Mac), the
// time-to-80%/100% estimates, hold detection (plugged in but not charging) and weak-charger warnings. Pure functions,
// so they are unit-tested with fixture values; nothing here reads the machine.

/// Where the Mac's power is going right now, W. nil = not measured. Edges are never negative.
public struct ChargeFlow: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case adapter, battery }
    public var source: Source
    /// Power arriving from the adapter (SystemPowerIn, else SystemVoltageIn × SystemCurrentIn).
    public var adapterIn: Double?
    /// What the Mac itself uses (SystemLoad, else derived).
    public var mac: Double?
    /// Battery power, signed: + charging, - draining (Voltage × Amperage, else telemetry BatteryPower).
    public var battery: Double?
    /// Lost converting the adapter's power (AdapterEfficiencyLoss).
    public var loss: Double?

    public var adapterToBattery: Double? { source == .adapter ? battery.map { max($0, 0) } : nil }
    /// The battery's contribution to the Mac: all of it on battery, or the shortfall when the adapter can't keep up.
    public var batteryToMac: Double? { battery.map { max(-$0, 0) } }
    /// The adapter's share of the Mac's draw: the draw minus any battery top-up, else adapter input minus charging and loss.
    public var adapterToMac: Double? {
        guard source == .adapter else { return nil }
        if let mac { return max(mac - (batteryToMac ?? 0), 0) }
        if let a = adapterIn, let b = battery { return max(a - max(b, 0) - (loss ?? 0), 0) }
        return nil
    }

    /// `battery` comes from BatteryInfo (already sign-corrected); telemetry fills the rest. Readings of 0 from the
    /// telemetry while on adapter mean "not measured" for SystemPowerIn (it reads 0 on battery), so only > 0 counts.
    public static func compute(battery: BatteryInfo?, telemetry t: PowerTelemetry?) -> ChargeFlow? {
        guard let b = battery else { return nil }
        let onAdapter = b.externalConnected
        var f = ChargeFlow(source: onAdapter ? .adapter : .battery)
        if let v = b.voltage, let a = b.amperage { f.battery = v * a } else { f.battery = t?.batteryPower }
        if onAdapter {
            if let p = t?.systemPowerIn, p > 0 { f.adapterIn = p }
            else if let v = t?.systemVoltageIn, let i = t?.systemCurrentIn, v > 0, i > 0 { f.adapterIn = v * i }
            f.loss = t?.adapterEfficiencyLoss.flatMap { $0 > 0 ? $0 : nil }
        }
        if let l = t?.systemLoad, l > 0 { f.mac = l }
        else if !onAdapter, let bw = f.battery, bw < 0 { f.mac = -bw }
        else if let a = f.adapterIn, let bw = f.battery { f.mac = max(a - bw - (f.loss ?? 0), 0) }
        return f
    }
}

/// A time estimate and what it's based on.
public struct ChargeETA: Equatable, Sendable {
    public enum Basis: String, Sendable { case macOS = "macOS estimate", recentRate = "recent rate", reached = "reached" }
    public var minutes: Double?
    public var basis: Basis
}

public enum ChargeEstimate {
    /// Charge gained per minute, by least squares over points in the last `window` seconds. nil without at least 3
    /// points over 3 minutes, or when the charge isn't rising (a flat or falling fit would give a meaningless ETA).
    public static func rate(_ points: [(time: Date, percent: Double)], now: Date, window: TimeInterval = 600) -> Double? {
        let p = points.filter { now.timeIntervalSince($0.time) <= window }
        guard p.count >= 3, let first = p.first, let last = p.last, last.time.timeIntervalSince(first.time) >= 180 else { return nil }
        let xs = p.map { $0.time.timeIntervalSince(first.time) / 60 }, ys = p.map(\.percent)
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        guard sxx > 0 else { return nil }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        return slope > 0.01 ? slope : nil
    }

    /// Times to 80% and to full while charging; nil when not charging. macOS only estimates time to full
    /// (AvgTimeToFull, else TimeRemaining while charging), so time to 80% always comes from the recent rate.
    public static func estimate(percent: Double, isCharging: Bool, fullyCharged: Bool?, avgTimeToFull: Int?, timeRemaining: Int?,
                                ratePerMinute: Double?) -> (to80: ChargeETA, toFull: ChargeETA)? {
        if fullyCharged == true || percent >= 100 { return (ChargeETA(minutes: nil, basis: .reached), ChargeETA(minutes: nil, basis: .reached)) }
        guard isCharging else { return nil }
        let to80 = percent >= 80 ? ChargeETA(minutes: nil, basis: .reached)
                                 : ChargeETA(minutes: ratePerMinute.map { (80 - percent) / $0 }, basis: .recentRate)
        let mac = [avgTimeToFull, timeRemaining].compactMap { $0 }.first { $0 > 0 }
        let toFull = mac.map { ChargeETA(minutes: Double($0), basis: .macOS) }
            ?? ChargeETA(minutes: ratePerMinute.map { (100 - percent) / $0 }, basis: .recentRate)
        return (to80, toFull)
    }
}

/// `pmset -g batt`: e.g. " -InternalBattery-0 (id=1234)\t80%; AC attached; not charging present: true".
public struct PmsetBattery: Equatable, Sendable {
    public var source: String?
    public var percent: Int?
    /// The state field as written ("charging", "discharging", "charged", "AC attached", "finishing charge").
    public var state: String?
    public var notCharging: Bool
    public var onHold: Bool

    public static func parse(_ text: String) -> PmsetBattery? {
        var r = PmsetBattery(notCharging: false, onHold: false)
        if let q = text.range(of: "drawing from '") { r.source = text[q.upperBound...].split(separator: "'").first.map(String.init) }
        guard let line = text.split(separator: "\n").first(where: { $0.contains("InternalBattery") }) else { return r.source == nil ? nil : r }
        let fields = line.split(separator: "\t").last.map { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
        r.percent = fields.first.flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
        if fields.count > 1 { r.state = fields[1] }
        let lower = line.lowercased()
        r.notCharging = lower.contains("not charging"); r.onHold = lower.contains("on hold")
        return r
    }
}

/// What the battery is doing, with hold detection.
public enum ChargeState: Equatable, Sendable {
    case noBattery, onBattery, charging, full
    /// Plugged in, below full, not charging: Optimized Battery Charging, a charge limit, or a charger condition.
    case held(percent: Double, pmsetConfirms: Bool, reasonCode: Int64?)

    public static func assess(battery: BatteryInfo?, details: ChargingDetails?, pmset: PmsetBattery?) -> ChargeState {
        guard let b = battery else { return .noBattery }
        guard b.externalConnected else { return .onBattery }
        if b.isCharging { return .charging }
        if details?.facts.fullyCharged == true || b.percent >= 99.5 || pmset?.state?.lowercased() == "charged" { return .full }
        let code = details?.charger?.notChargingReason.flatMap { $0 != 0 ? $0 : nil }
        return .held(percent: b.percent, pmsetConfirms: (pmset?.notCharging ?? false) || (pmset?.onHold ?? false), reasonCode: code)
    }
}

/// Weak-charger warnings from measurements only (no table of what each Mac "should" have).
public enum ChargerCheck {
    public static func warnings(adapter: AdapterReport?, flow: ChargeFlow?, charger: ChargerFlags?, peakSystemW: Double?) -> [String] {
        var w: [String] = []
        if let s = charger?.slowChargingReason, s != 0 { w.append(String(format: "macOS reports a slow-charging condition (code 0x%llX).", s)) }
        if let t = charger?.thermallyLimited, t > 0 { w.append("Charging has been slowed by temperature for \(t / 60) min.") }
        if flow?.source == .adapter, let b = flow?.batteryToMac, b > 0.5 {
            w.append(String(format: "The charger can't keep up: the battery is supplying %.1f W while plugged in.", b))
        }
        let rated = adapter?.negotiatedWatts ?? adapter?.watts.map(Double.init)
        if let r = rated, let peak = peakSystemW, peak > r {
            w.append(String(format: "This charger (%.0f W) is below the most this Mac has drawn since FlightDeck started (%.0f W); under that load the battery drains.", r, peak))
        }
        return w
    }
}
