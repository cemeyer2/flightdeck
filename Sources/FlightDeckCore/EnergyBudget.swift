import Foundation
// Backs the Energy tab's "what used my battery" view: replays a black-box span and integrates power per app.
// Everything here is derived from recorded frames, so it works the same for the last hour or a saved trace.

/// Energy use per app over a span of recorded frames (from the black box). Energy is integrated from each
/// process's measured power over the time to the next frame; gaps longer than 3 intervals aren't counted.
/// Apps are grouped the same way as the process list (see `AppUsage.groupKeys`).
public struct AppEnergy: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var iconPath: String
    /// Integrated from per-process billed energy (`ProcessSample.energyWatts`); only covers processes the trace kept.
    public var wattHours: Double
    public var averageWatts: Double     // over the time the app was running and recorded
    /// Counted seconds the app was present in the recorded frames, starting from the first frame in which it drew power.
    public var activeTime: TimeInterval
}

/// Totals for a recorded span. Optional fields are nil when the Mac never reported that quantity
/// (no system power sensor, no battery), rather than 0.
public struct EnergyBudget: Sendable {
    public var apps: [AppEnergy]
    public var systemWattHours: Double?
    /// System energy not attributed to any recorded app (display, unrecorded processes, macOS itself); nil if unknown.
    public var unattributedWattHours: Double?           // measured system draw, if reported
    /// Wall-clock length from first to last frame, including any gaps.
    public var span: TimeInterval
    /// Counted (non-gap) seconds spent on battery power.
    public var onBattery: TimeInterval
    public var batteryDropPercent: Double?        // charge lost while on battery
    public var charge: [(Date, Double)]           // battery % over time

    /// Integrates each frame's readings over the interval until the next frame (left Riemann sum), in watt-hours.
    /// Called from a detached utility task by the Energy view (fine tier for 1 h, coarse tier for longer spans).
    public static func compute(_ t: Trace) -> EnergyBudget {
        var perApp: [String: AppEnergy] = [:]
        var sys = 0.0, sysSeen = false, onBatt = 0.0, drop = 0.0, dropSeen = false
        var charge: [(Date, Double)] = []
        // Steps longer than 3 sampling intervals are gaps (sleep, pause, app not running): we don't know what
        // happened, so they contribute nothing rather than stretching the previous frame's power across them.
        let maxStep = t.interval * 3
        let frames = t.frames
        for (i, f) in frames.enumerated() {
            // The charge curve includes every frame (gaps included); the chart draws it over time as-is.
            if let b = f.power.battery { charge.append((f.time, b.percent)) }
            guard i + 1 < frames.count else { break }
            let dt = frames[i + 1].time.timeIntervalSince(f.time)
            guard dt > 0, dt <= maxStep else { continue }
            if let w = f.power.systemWatts.value { sys += w * dt / 3600; sysSeen = true }
            if f.power.powerSource == "Battery" {
                onBatt += dt
                // Only falling charge counts, so a brief tick up from calibration doesn't cancel real drain.
                if let a = f.power.battery?.percent, let b = frames[i + 1].power.battery?.percent, a > b { drop += a - b; dropSeen = true }
            }
            // Processes without an energy reading are skipped, not counted as 0 W.
            for (p, k) in zip(f.processes, AppUsage.groupKeys(f.processes)) {
                guard let w = p.energyWatts, w > 0 else { continue }
                var a = perApp[k.key] ?? AppEnergy(id: k.key, name: k.name, iconPath: k.icon, wattHours: 0, averageWatts: 0, activeTime: 0)
                a.wattHours += w * dt / 3600
                perApp[k.key] = a
            }
            // Active time is counted once per frame per app, not per process. Only apps already in `perApp` (that have
            // drawn power in this or an earlier frame) accumulate it; frames where they are present at 0 W still count.
            for k in Set(AppUsage.groupKeys(f.processes).map(\.key)) where perApp[k] != nil { perApp[k]!.activeTime += dt }
        }
        // Average over active time, not over the whole span, so a short heavy burst reads as heavy.
        var apps = perApp.values.map { a -> AppEnergy in
            var a = a; a.averageWatts = a.activeTime > 0 ? a.wattHours * 3600 / a.activeTime : 0; return a
        }.sorted { $0.wattHours > $1.wattHours }
        // Recordings that carry cumulative energy (newer black boxes) are integrated exactly from those counters instead.
        // (Only if the counters actually show energy being used; otherwise keep the rate-based figures.)
        if frames.contains(where: { $0.processes.contains { $0.energyTotal != nil } }) {
            let exact = Cumulative.perApp(frames, \.energyTotal).map { k, v in
                let active = max(v.last.timeIntervalSince(v.first), 1)
                return AppEnergy(id: k, name: v.name, iconPath: v.icon, wattHours: v.amount / 3600, averageWatts: v.amount / active, activeTime: active)
            }.filter { $0.wattHours > 0 }.sorted { $0.wattHours > $1.wattHours }
            if !exact.isEmpty { apps = exact }
        }
        let span = (frames.last?.time).flatMap { l in frames.first.map { l.timeIntervalSince($0.time) } } ?? 0
        // What the recorded apps don't account for: the display, quieter processes the black box didn't keep, the system.
        let unattributed = sysSeen ? max(sys - apps.reduce(0) { $0 + $1.wattHours }, 0) : nil
        return EnergyBudget(apps: apps, systemWattHours: sysSeen ? sys : nil, unattributedWattHours: unattributed, span: span, onBattery: onBatt,
                            batteryDropPercent: dropSeen ? drop : nil, charge: charge)
    }
}
