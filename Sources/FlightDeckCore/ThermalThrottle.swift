import Foundation
// "Is the Mac slowing down for heat?": combines three signals.
//   • `pmset -g therm`: the power manager's CPU speed limit and scheduler limit (percent of full speed) and the
//     thermal / performance warning levels. It's a process launch, so the app runs it only while the Thermals tab is
//     visible, every 30 s (ThermalLimits.read).
//   • ProcessInfo's thermal state (in every snapshot): fair, serious or critical pressure.
//   • The GPU's thermalLimited residency (percent of time its clock was capped for heat), where reported.
// ThrottleTracker turns them into a verdict, the time spent throttled this session, and the "CPU speed limit below
// 100% for over a minute" finding.

/// Parsed `pmset -g therm`. Every field is nil when pmset didn't report it.
public struct ThermalLimits: Sendable, Equatable, Codable {
    /// Percent of full CPU speed the power manager allows (100 = no limit).
    public var cpuSpeedLimit: Int?
    /// Percent of CPU time the scheduler may hand out (100 = no limit).
    public var cpuSchedulerLimit: Int?
    public var availableCPUs: Int?
    /// nil with `thermalWarningRecorded == false` means pmset said "No thermal warning level has been recorded".
    public var thermalWarningLevel: Int?
    public var thermalWarningRecorded: Bool
    public var performanceWarningLevel: Int?
    public init(cpuSpeedLimit: Int? = nil, cpuSchedulerLimit: Int? = nil, availableCPUs: Int? = nil,
                thermalWarningLevel: Int? = nil, thermalWarningRecorded: Bool = false, performanceWarningLevel: Int? = nil) {
        self.cpuSpeedLimit = cpuSpeedLimit; self.cpuSchedulerLimit = cpuSchedulerLimit; self.availableCPUs = availableCPUs
        self.thermalWarningLevel = thermalWarningLevel; self.thermalWarningRecorded = thermalWarningRecorded
        self.performanceWarningLevel = performanceWarningLevel
    }

    /// True when pmset reports a CPU limit below 100%.
    public var limited: Bool { (cpuSpeedLimit ?? 100) < 100 || (cpuSchedulerLimit ?? 100) < 100 }

    /// Parses pmset's output. A Mac that has never been limited prints only notes, e.g.
    ///     Note: No thermal warning level has been recorded
    ///     Note: No performance warning level has been recorded
    ///     Note: No CPU power status has been recorded
    /// Once the power manager has posted a CPU power notification it adds a block of "key = value" lines:
    ///     2024-05-01 10:12:13 +0200 CPU Power notify
    ///         CPU_Scheduler_Limit     = 100
    ///         CPU_Available_CPUs      = 10
    ///         CPU_Speed_Limit         = 100
    /// and a recorded warning level reads like "Thermal warning level set to 2." (wording varies between macOS
    /// versions, so any line naming the level with a number is accepted). With several blocks, the last one wins.
    public static func parse(_ text: String) -> ThermalLimits {
        var l = ThermalLimits()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = Int(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
                switch key {
                case "CPU_Speed_Limit": l.cpuSpeedLimit = value
                case "CPU_Scheduler_Limit": l.cpuSchedulerLimit = value
                case "CPU_Available_CPUs": l.availableCPUs = value
                default: break
                }
            } else if lower.contains("thermal warning level") {
                if lower.contains("no thermal warning level") { l.thermalWarningRecorded = false; l.thermalWarningLevel = nil }
                else if let n = lastInteger(in: line) { l.thermalWarningRecorded = true; l.thermalWarningLevel = n }
            } else if lower.contains("performance warning level"), !lower.contains("no performance warning level") {
                l.performanceWarningLevel = lastInteger(in: line)
            }
        }
        return l
    }

    /// The last run of digits in a line ("… set to 2." → 2), skipping digits that belong to a leading timestamp.
    static func lastInteger(in line: String) -> Int? {
        let tail = line.range(of: "level", options: .caseInsensitive).map { String(line[$0.upperBound...]) } ?? line
        let runs = tail.split { !$0.isNumber }
        return runs.last.flatMap { Int($0) }
    }

    /// Runs `/usr/bin/pmset -g therm` (about 10 ms) and parses it; nil if it couldn't run. Blocking: call off the main thread.
    public static func read() -> ThermalLimits? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g", "therm"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8) else { return nil }
        return parse(s)
    }
}

/// The current throttling verdict, for the Thermals page and the MCP tool.
public struct ThrottleStatus: Sendable, Equatable {
    /// nil when nothing could be measured (no pmset reading yet and no thermal state).
    public var throttled: Bool?
    /// Why, in plain English, one line per signal that says so.
    public var reasons: [String]
    /// The latest pmset reading and when it was taken (nil until the Thermals tab has been open).
    public var limits: ThermalLimits?
    public var limitsAt: Date?
    public var thermalState: Int
    public var gpuThermalLimited: Double?
    /// Seconds this session with any throttling signal, and seconds observed in total.
    public var throttledSeconds: TimeInterval
    public var observedSeconds: TimeInterval
}

/// Tracks throttling over a session. Not thread-safe: owned by ThermalWatch, which locks around it.
public final class ThrottleTracker {
    /// A pmset reading older than this no longer says anything about now (the tab closed and polling stopped).
    public static let limitsStale: TimeInterval = 90
    /// GPU capped for heat more than this percent of the time counts as throttling (a sliver is normal clock management).
    static let gpuLimitedPercent = 1.0
    /// The finding needs the speed limit below 100% for this long.
    static let findingAfter: TimeInterval = 60

    private(set) var limits: ThermalLimits?
    private(set) var limitsAt: Date?
    /// When the current run of pmset readings with a CPU limit began (nil while unlimited or unknown).
    private var limitedSince: Date?
    private var last: Date?
    private var throttledSeconds: TimeInterval = 0
    private var observedSeconds: TimeInterval = 0
    private var current = ThrottleStatus(throttled: nil, reasons: [], thermalState: 0, throttledSeconds: 0, observedSeconds: 0)

    public init() {}

    public func note(_ l: ThermalLimits, at t: Date) {
        // After a pause in polling (the tab was closed) nobody knows whether the limit lifted in between: start over.
        if let prev = limitsAt, t.timeIntervalSince(prev) > Self.limitsStale { limitedSince = nil }
        limits = l; limitsAt = t
        if l.limited { if limitedSince == nil { limitedSince = t } } else { limitedSince = nil }
    }

    /// Fresh pmset reading, or nil when there is none or it is stale.
    func freshLimits(at t: Date) -> ThermalLimits? {
        guard let l = limits, let at = limitsAt, t.timeIntervalSince(at) <= Self.limitsStale else { return nil }
        return l
    }

    /// Folds in one sample: the thermal state and GPU heat cap from the snapshot plus the latest pmset reading.
    /// Sample gaps over 2 minutes (sleep) are not counted as observed time.
    @discardableResult
    public func ingest(thermalState: Int, gpuThermalLimited: Double?, at t: Date) -> ThrottleStatus {
        let dt = last.map { t.timeIntervalSince($0) } ?? 0
        last = t
        var reasons: [String] = []
        let l = freshLimits(at: t)
        if let l, let v = l.cpuSpeedLimit, v < 100 { reasons.append("macOS limits the CPU to \(v)% of its full speed") }
        if let l, let v = l.cpuSchedulerLimit, v < 100 { reasons.append("the scheduler hands out only \(v)% of CPU time") }
        if thermalState >= 2 { reasons.append("thermal pressure is \(FanExplainer.stateName(thermalState).lowercased())") }
        if let g = gpuThermalLimited, g > Self.gpuLimitedPercent { reasons.append(String(format: "the GPU clock was capped for heat %.0f%% of the time", g)) }
        let throttled = !reasons.isEmpty
        if dt > 0 && dt <= 120 { observedSeconds += dt; if throttled { throttledSeconds += dt } }
        // "Not throttled" is only claimed with at least one real signal behind it: thermal state is always read, so it is.
        current = ThrottleStatus(throttled: throttled, reasons: reasons, limits: limits, limitsAt: limitsAt,
                                 thermalState: thermalState, gpuThermalLimited: gpuThermalLimited,
                                 throttledSeconds: throttledSeconds, observedSeconds: observedSeconds)
        return current
    }

    public var status: ThrottleStatus { current }

    /// "CPU speed limited for over a minute", while the pmset readings still say so and are fresh.
    public func finding(at t: Date) -> Finding? {
        guard let since = limitedSince, let l = freshLimits(at: t), l.limited, t.timeIntervalSince(since) >= Self.findingAfter else { return nil }
        let pct = l.cpuSpeedLimit.flatMap { $0 < 100 ? $0 : nil } ?? l.cpuSchedulerLimit ?? 100
        return Finding(id: "cpu-speed-limit", severity: pct < 70 ? .warning : .caution, icon: "speedometer",
                       title: "macOS is limiting the CPU to \(pct)% of its speed",
                       detail: "pmset reports a CPU speed limit below 100% for over a minute: the Mac is holding itself back to "
                           + "control heat or power. Better airflow, a cooler room or a lighter load lets it recover.",
                       since: since, destination: "Performance:Thermals")
    }
}
