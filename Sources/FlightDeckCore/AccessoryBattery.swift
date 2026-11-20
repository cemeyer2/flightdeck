import Foundation
// Peripherals › accessory batteries: levels of Bluetooth/USB accessories over time, and how long the current charge
// should last. Sources (no private entitlements): Apple's own HID accessories (Magic Mouse/Keyboard/Trackpad)
// publish "BatteryPercent" in the IORegistry, which is cheap and read every 20 minutes; AirPods and other headsets'
// levels (per bud and case) come only from `system_profiler SPBluetoothDataType`, which takes about a second, so they
// are recorded when the Peripherals page loads, never on a timer. The estimate fits a Theil–Sen line to the current
// discharge (the readings since the last charge), so a few odd readings don't swing it.

public struct AccessoryReading: Codable, Hashable, Sendable {
    public var time: Date
    /// "Main", or "Left" / "Right" / "Case" for earbuds, in %.
    public var levels: [String: Int]
    public init(time: Date, levels: [String: Int]) { self.time = time; self.levels = levels }
}

public struct AccessoryEstimate: Codable, Hashable, Sendable {
    /// Percentage points lost per day over the current discharge.
    public var ratePerDay: Double
    public var daysLeft: Double
    public var since: Date
    public var readings: Int
    /// "about 9 days left at this rate".
    public var text: String {
        if daysLeft >= 2 { return "about \(Int(daysLeft.rounded())) days left at this rate" }
        let h = max(1, Int((daysLeft * 24).rounded()))
        return "about \(h) hour\(h == 1 ? "" : "s") left at this rate"
    }
}

public struct AccessoryBattery: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: String?
    public var connected: Bool
    /// Latest levels (from this reading, or the last recorded one when not connected).
    public var levels: [String: Int]
    public var lastSeen: Date?
    /// Saved readings, oldest first.
    public var history: [AccessoryReading]
    public var estimate: Measured<AccessoryEstimate>
    public init(name: String, kind: String?, connected: Bool, levels: [String: Int], lastSeen: Date?, history: [AccessoryReading],
                estimate: Measured<AccessoryEstimate>) {
        self.name = name; self.kind = kind; self.connected = connected; self.levels = levels; self.lastSeen = lastSeen
        self.history = history; self.estimate = estimate
    }
    public static func == (a: Self, b: Self) -> Bool { a.name == b.name && a.levels == b.levels && a.history == b.history && a.connected == b.connected }
    public func hash(into h: inout Hasher) { h.combine(name); h.combine(levels) }

    /// Parts in the order earbuds are usually described.
    public static let partOrder = ["Main", "Left", "Right", "Case"]
    public var orderedLevels: [(part: String, pct: Int)] { Self.partOrder.compactMap { k in levels[k].map { (k, $0) } } }
}

public enum AccessoryForecast {
    public static let lowThreshold = 15
    static let maxPoints = 240

    /// The current discharge of `part`: readings back from the newest while the level only falls (a 1-point rise is
    /// gauge noise; more means it was charged in between).
    public static func discharge(_ readings: [AccessoryReading], part: String) -> [(Date, Int)] {
        let pts = readings.sorted { $0.time < $1.time }.compactMap { r in r.levels[part].map { (r.time, $0) } }
        guard var i = pts.indices.last else { return [] }
        while i > 0, pts[i - 1].1 >= pts[i].1 - 1 { i -= 1 }
        return Array(pts[i...])
    }

    /// How long the charge should last at the current rate. Needs at least 3 readings over 12 hours and a drop of 3
    /// points; earbuds' buds are skipped by callers (they drain in hours of use and refill in the case).
    public static func estimate(_ readings: [AccessoryReading], part: String = "Main") -> Measured<AccessoryEstimate> {
        let seg = discharge(readings, part: part)
        guard let first = seg.first, let last = seg.last else { return .unavailable("no readings yet") }
        if seg.count < 3 || last.0.timeIntervalSince(first.0) < 12 * 3600 {
            return .unavailable("needs about a day of readings since the last charge")
        }
        if first.1 - last.1 < 3 { return .unavailable("level hasn't dropped enough yet to estimate") }
        // Thin long discharges evenly (Theil–Sen is O(n²)); x in days since the segment started.
        let step = max(1, seg.count / maxPoints)
        var pts = stride(from: 0, to: seg.count, by: step).map { seg[$0] }
        if pts.last?.0 != last.0 { pts.append(last) }
        let xy = pts.map { (x: $0.0.timeIntervalSince(first.0) / 86_400, y: Double($0.1)) }
        guard let fit = TheilSen.fit(xy), fit.slope < 0 else { return .unavailable("not draining at the moment") }
        let rate = -fit.slope
        return .value(AccessoryEstimate(ratePerDay: rate, daysLeft: Double(last.1) / rate, since: first.0, readings: seg.count))
    }

    /// One value per reading for a sparkline: the main level, or the lower bud for earbuds.
    public static func sparkValues(_ readings: [AccessoryReading]) -> [(Date, Double)] {
        readings.compactMap { r in
            let v = r.levels["Main"] ?? [r.levels["Left"], r.levels["Right"]].compactMap { $0 }.min() ?? r.levels["Case"]
            return v.map { (r.time, Double($0)) }
        }
    }

    /// Low-battery findings: a main battery that crossed below `lowThreshold` with the newest reading, which happens
    /// once per discharge (it has to be charged above the threshold to cross again).
    public static func lowFinding(name: String, previous: AccessoryReading?, new: AccessoryReading) -> Finding? {
        guard let now = new.levels["Main"], now < lowThreshold else { return nil }
        if let before = previous?.levels["Main"], before < lowThreshold { return nil }
        return Finding(id: "accessory-low:\(name)", severity: .info, icon: "battery.25percent", title: "\(name) battery is at \(now)%",
                       detail: "Charge it soon; FlightDeck says this once per discharge.", since: new.time, destination: "Peripherals")
    }

    /// Joins this moment's levels (connected devices) with saved history into one list, connected first.
    public static func combine(current: [(name: String, kind: String?, levels: [String: Int])], history: [String: [AccessoryReading]],
                               since: Date) -> [AccessoryBattery] {
        var out: [AccessoryBattery] = []
        var names = Set<String>()
        for c in current where !c.levels.isEmpty && names.insert(c.name).inserted {
            let h = (history[c.name] ?? []).filter { $0.time >= since }
            out.append(AccessoryBattery(name: c.name, kind: c.kind, connected: true, levels: c.levels, lastSeen: h.last?.time,
                                        history: h, estimate: c.levels["Main"] == nil ? .unavailable("estimates are for single-battery accessories") : estimate(h)))
        }
        for (name, all) in history.sorted(by: { $0.key < $1.key }) where !names.contains(name) {
            let h = all.filter { $0.time >= since }
            guard let last = h.last else { continue }
            out.append(AccessoryBattery(name: name, kind: nil, connected: false, levels: last.levels, lastSeen: last.time, history: h,
                                        estimate: .unavailable("not connected")))
        }
        return out
    }
}
