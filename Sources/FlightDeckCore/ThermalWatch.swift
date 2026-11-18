import Foundation
// Ties the thermal pieces together for the app: per-sensor history (SensorHistory), throttling (ThrottleTracker),
// fan health (FanHealthMonitor) and the user's temperature alerts (TemperatureAlertMonitor). The Engine calls
// `ingest` on its sampling queue for every snapshot and adds the returned findings to the Analyzer's; views and the MCP
// server read `status()`. Per sample the work is O(fans + alert rules); the catalog is rebuilt, and the history
// updated, only when the sensors were actually re-read (every 4 s), which is O(sensors).

/// Everything the Thermals page and the `temperatures` tool show besides the raw snapshot.
public struct ThermalStatus: Sendable {
    public var catalog: SensorCatalog?
    public var throttle: ThrottleStatus
    public var fans: [FanStatus]
    /// nil = unknown (fans not read), true = this Mac has no fans.
    public var fanless: Bool?
}

/// Thread-safe (one lock around all state): ingested on the sampling queue, read from the main actor.
public final class ThermalWatch: @unchecked Sendable {
    public let chip: ChipFamily
    public let history: SensorHistory
    private let lock = NSLock()
    private let throttle = ThrottleTracker()
    private let fanHealth = FanHealthMonitor()
    private let alerts = TemperatureAlertMonitor()
    private var catalog: SensorCatalog?
    private var catalogReadAt: Date?

    public init(chip: ChipFamily = .current, historyCapacity: Int = 450) {
        self.chip = chip
        history = SensorHistory(capacity: historyCapacity)
    }

    /// Replaces the alert rules (from Settings). Takes effect at the next sample.
    public func setRules(_ rules: [TemperatureAlertRule]) {
        lock.lock(); alerts.rules = rules; lock.unlock()
    }

    /// A `pmset -g therm` reading, taken while the Thermals tab is visible.
    public func note(limits: ThermalLimits, at t: Date) {
        lock.lock(); throttle.note(limits, at: t); lock.unlock()
    }

    /// One snapshot in, findings out (temperature alerts, fan problems, a sustained CPU speed limit).
    public func ingest(_ s: Snapshot) -> [Finding] {
        lock.lock(); defer { lock.unlock() }
        let readAt = s.power.sensorsReadAt ?? s.time
        // Snapshots without sensorsReadAt (older traces) rebuild every time; live ones only after a new sensor read.
        if catalog == nil || s.power.sensorsReadAt == nil || catalogReadAt != readAt {
            let c = SensorCatalog.build(s.power, chip: chip)
            catalog = c; catalogReadAt = readAt
            history.ingest(c, readAt: readAt)
        }
        let families = catalog?.families ?? []
        throttle.ingest(thermalState: s.power.thermalState, gpuThermalLimited: s.gpuDetail?.thermalLimited, at: s.time)
        let hottest = families.map(\.max).max()
        fanHealth.ingest(fans: s.power.fans, hottest: hottest, at: s.time)
        var out = alerts.ingest(families, at: s.time) + fanHealth.findings(at: s.time)
        if let f = throttle.finding(at: s.time) { out.append(f) }
        return out
    }

    public func status() -> ThermalStatus {
        lock.lock(); defer { lock.unlock() }
        return ThermalStatus(catalog: catalog, throttle: throttle.status, fans: fanHealth.statuses, fanless: fanHealth.fanless)
    }
}
