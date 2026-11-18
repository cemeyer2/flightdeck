import SwiftUI
import FlightDeckCore
// Thermals tab panels: "Is the Mac slowing down for heat?" (ThrottlePanel) and per-fan health (FanHealthPanel).
// Unknown values show "—" with the reason; nothing is filled in.

/// Throttling verdict from ThermalWatch: pmset's CPU limits (read only while this tab is open), thermal pressure and
/// the GPU's heat cap, plus the time spent throttled this session. In replay only the snapshot's own signals are shown.
struct ThrottlePanel: View {
    @Environment(\.palette) var p
    let status: ThrottleStatus?
    let snapshot: Snapshot?
    var body: some View {
        let l = status?.limits
        let state = snapshot?.power.thermalState ?? 0
        let gpu = snapshot?.gpuDetail?.thermalLimited
        let throttled = status?.throttled ?? (snapshot.map { _ in state >= 2 || (gpu ?? 0) > 1 })
        Panel(title: "Is the Mac slowing down for heat?") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: throttled == true ? "tortoise.fill" : "hare")
                    .font(.system(size: 20)).foregroundStyle(throttled == true ? p.warn : p.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(throttled == nil ? "— Not measured yet" : throttled! ? "Yes" : "No: running at full speed")
                        .font(.system(size: 15, weight: .semibold))
                    ForEach(status?.reasons ?? [], id: \.self) { r in
                        Text(r.prefix(1).uppercased() + r.dropFirst() + ".").font(.system(size: 11)).foregroundStyle(p.dim)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 22) {
                Readout(label: "CPU speed limit", value: l?.cpuSpeedLimit.map { "\($0)" }, unit: "%", color: (l?.cpuSpeedLimit ?? 100) < 100 ? p.warn : nil, size: 18)
                Readout(label: "Scheduler limit", value: l?.cpuSchedulerLimit.map { "\($0)" }, unit: "%", size: 18)
                Readout(label: "GPU heat cap", value: gpu.map { String(format: "%.0f", $0) }, unit: "% of time", size: 18)
                Readout(label: "Throttled", value: status.map { Fmt.duration($0.throttledSeconds) }, size: 18)
                Spacer(minLength: 0)
            }
            Text(footnote(l)).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Where the numbers come from and what's missing.
    func footnote(_ l: ThermalLimits?) -> String {
        guard let status else { return "Replay: only the recorded thermal state and GPU heat cap are known." }
        var parts: [String] = []
        if let l {
            parts.append(l.thermalWarningRecorded ? "thermal warning level \(l.thermalWarningLevel.map(String.init) ?? "—")" : "no thermal warning recorded")
            if l.cpuSpeedLimit == nil { parts.append("no CPU power status recorded (never limited since boot)") }
            if let at = status.limitsAt { parts.append("pmset read \(Int(Date().timeIntervalSince(at))) s ago") }
        } else {
            parts.append("— CPU limits: waiting for the first pmset reading (taken every 30 s while this tab is open)")
        }
        if status.observedSeconds > 0 {
            parts.append(String(format: "throttled %.0f%% of %@ observed", status.throttledSeconds / status.observedSeconds * 100, Fmt.duration(status.observedSeconds)))
        }
        return parts.joined(separator: " · ")
    }
}

/// Fans from the SMC with their health (FanHealthMonitor): RPM against target, minimum and maximum, percent of
/// maximum, and any sustained problem. Fanless Macs say so; an unreadable SMC says that instead.
struct FanHealthPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    let fans: [FanReading]?
    let health: [FanStatus]
    var body: some View {
        Panel(title: "Fans", trailing: "from the SMC") {
            if let fans, fans.isEmpty {
                Label("This Mac has no fans: it cools itself by slowing down (see above).", systemImage: "wind").foregroundStyle(p.dim)
            } else if let fans {
                let byIndex = Dictionary(health.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
                HStack(alignment: .top, spacing: 28) {
                    ForEach(fans) { f in fanCard(f, byIndex[f.index]) }
                    Spacer(minLength: 0)
                }
                HistoryGraph(traces: fans.map { f in
                    GraphTrace(name: "fan\(f.index)", values: e.series { $0.power.fans?.first { $0.index == f.index }?.rpm },
                               color: f.index == 0 ? p.accent : p.accent2, fill: f.index == 0) },
                             minHeadroom: 2000, format: { String(format: "%.0f rpm", $0) }).frame(height: 100)
            } else {
                Text("— Fan speeds couldn't be read from the SMC on this Mac.").foregroundStyle(p.dim)
            }
        }
    }

    func fanCard(_ f: FanReading, _ h: FanStatus?) -> some View {
        let issues = h?.issues ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Readout(label: "Fan \(f.index + 1)", value: String(format: "%.0f", f.rpm), unit: "RPM")
                Readout(label: "Target", value: f.targetRPM.map { String(format: "%.0f", $0) }, unit: "RPM", size: 15)
                Readout(label: "Of max", value: f.fraction.map { String(format: "%.0f", $0 * 100) }, unit: "%", size: 15)
            }
            VFDMeter(fraction: f.fraction, segments: 20, height: 6).frame(width: 220)
            Text([f.minRPM.map { String(format: "min %.0f", $0) } ?? "min —", f.maxRPM.map { String(format: "max %.0f", $0) } ?? "max —"]
                    .joined(separator: " · "))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
            if issues.isEmpty {
                Label(e.mode == .live ? "Healthy" : "Health is checked live only", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(p.dim)
            }
            ForEach(issues, id: \.self) { i in
                Label(i.text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(i == .stalled ? p.crit : p.warn)
            }
        }
    }
}
