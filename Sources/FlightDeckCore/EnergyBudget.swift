import Foundation

/// Energy use per app over a span of recorded frames (from the black box). Energy is integrated from each
/// process's measured power over the time to the next frame; gaps longer than 3 intervals aren't counted.
public struct AppEnergy: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var iconPath: String
    public var wattHours: Double
    public var averageWatts: Double     // over the time the app was running and recorded
    public var activeTime: TimeInterval
}

public struct EnergyBudget: Sendable {
    public var apps: [AppEnergy]
    public var systemWattHours: Double?           // measured system draw, if reported
    public var span: TimeInterval
    public var onBattery: TimeInterval
    public var batteryDropPercent: Double?        // charge lost while on battery
    public var charge: [(Date, Double)]           // battery % over time

    public static func compute(_ t: Trace) -> EnergyBudget {
        var perApp: [String: AppEnergy] = [:]
        var sys = 0.0, sysSeen = false, onBatt = 0.0, drop = 0.0, dropSeen = false
        var charge: [(Date, Double)] = []
        let maxStep = t.interval * 3
        let frames = t.frames
        for (i, f) in frames.enumerated() {
            if let b = f.power.battery { charge.append((f.time, b.percent)) }
            guard i + 1 < frames.count else { break }
            let dt = frames[i + 1].time.timeIntervalSince(f.time)
            guard dt > 0, dt <= maxStep else { continue }
            if let w = f.power.systemWatts.value { sys += w * dt / 3600; sysSeen = true }
            if f.power.powerSource == "Battery" {
                onBatt += dt
                if let a = f.power.battery?.percent, let b = frames[i + 1].power.battery?.percent, a > b { drop += a - b; dropSeen = true }
            }
            for (p, k) in zip(f.processes, AppUsage.groupKeys(f.processes)) {
                guard let w = p.energyWatts, w > 0 else { continue }
                var a = perApp[k.key] ?? AppEnergy(id: k.key, name: k.name, iconPath: k.icon, wattHours: 0, averageWatts: 0, activeTime: 0)
                a.wattHours += w * dt / 3600
                perApp[k.key] = a
            }
            // active time per app counted once per frame, not per process
            for k in Set(AppUsage.groupKeys(f.processes).map(\.key)) where perApp[k] != nil { perApp[k]!.activeTime += dt }
        }
        let apps = perApp.values.map { a -> AppEnergy in
            var a = a; a.averageWatts = a.activeTime > 0 ? a.wattHours * 3600 / a.activeTime : 0; return a
        }.sorted { $0.wattHours > $1.wattHours }
        let span = (frames.last?.time).flatMap { l in frames.first.map { l.timeIntervalSince($0.time) } } ?? 0
        return EnergyBudget(apps: apps, systemWattHours: sysSeen ? sys : nil, span: span, onBattery: onBatt,
                            batteryDropPercent: dropSeen ? drop : nil, charge: charge)
    }
}
