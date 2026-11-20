import SwiftUI
import FlightDeckCore
// What each gauge-type cockpit instrument reads from the Engine: its big value, meter fraction, detail line and history
// traces. One description per kind, drawn two ways: as a SummaryCard in the cockpit and as a big AmbientGauge in
// Ambient mode, so both always show the same numbers. Every value is nil ("—") when it wasn't measured.

/// Everything a single-value instrument shows. Mirrors SummaryCard's parameters.
struct InstrumentReading {
    var title: String
    var value: String?
    var fraction: Double?
    var showMeter = true
    var detail: String?
    var traces: [GraphTrace]
    var maxValue: Double? = nil
    var minHeadroom: Double = 1
    /// One colour for every lit meter segment. Set where a full meter is good news (battery charge, Wi-Fi signal), so
    /// the usual warn/crit shading at the top end doesn't paint a full battery red.
    var meterColor: Color? = nil
    /// Tints the detail line when it carries a warning (unusual traffic, an unexpected restart, a sensor in use).
    var detailColor: Color? = nil
}

/// Fan speed as a share of its range. Needs the maximum; with a known minimum the range starts there (an idle fan
/// at its minimum reads as an empty meter, not a third full). nil when the fan doesn't report a maximum.
func fanFraction(_ f: FanReading) -> Double? {
    guard let mx = f.maxRPM, mx > 0 else { return nil }
    let mn = f.minRPM ?? 0
    return mx > mn ? min(max((f.rpm - mn) / (mx - mn), 0), 1) : nil
}

/// Wi-Fi RSSI on a −90…−30 dBm scale (unusable to excellent).
func wifiFraction(_ rssi: Int) -> Double { min(max(Double(rssi + 90) / 60, 0), 1) }

extension Engine {
    /// The reading for a gauge-type instrument, or nil for kinds that aren't gauges (see `InstrumentKind.isGauge`).
    /// The first seven are the Summary page's original cards, unchanged.
    func reading(_ kind: InstrumentKind, _ p: Palette) -> InstrumentReading? {
        let s = current
        switch kind {
        case .cpu:
            return InstrumentReading(title: "CPU", value: s?.cpu.total.value.map { Fmt.pct($0) },
                                     fraction: s?.cpu.total.value.map { $0 / 100 },
                                     detail: s.map { String(format: "load %.2f %.2f %.2f", $0.cpu.loadAverage[0], $0.cpu.loadAverage[1], $0.cpu.loadAverage[2]) },
                                     traces: [GraphTrace(name: "cpu", values: series { $0.cpu.total.value }, color: p.accent)], maxValue: 100)
        case .memory:
            return InstrumentReading(title: "Memory", value: s.flatMap { $0.memory.isMeasured ? Fmt.bytes($0.memory.used) : nil },
                                     fraction: s.flatMap { $0.memory.isMeasured ? Double($0.memory.used) / Double(max($0.memory.total, 1)) : nil },
                                     detail: s.map { "pressure " + ($0.memory.pressure.value.map { Fmt.pct($0) } ?? "—") + " · swap " + ($0.memory.swapUsed.value.map { Fmt.bytes($0) } ?? "—") },
                                     traces: [GraphTrace(name: "mem", values: series { Double($0.memory.used) / Double(max($0.memory.total, 1)) * 100 }, color: p.accent),
                                              GraphTrace(name: "pressure", values: series { $0.memory.pressure.value }, color: p.accent2, fill: false)], maxValue: 100)
        // Disk, Network and Energy have no natural 0–100% scale, so they show no meter; the value is "—" unless both
        // directions were measured, rather than adding a known half to an unknown one.
        case .disk:
            return InstrumentReading(title: "Disk", value: s?.disk.readBps.value.flatMap { r in s?.disk.writeBps.value.map { Fmt.rate(r + $0) } },
                                     fraction: nil, showMeter: false,
                                     detail: s.map { "R " + ($0.disk.readBps.value.map(Fmt.rate) ?? "—") + " · W " + ($0.disk.writeBps.value.map(Fmt.rate) ?? "—") },
                                     traces: [GraphTrace(name: "r", values: series { $0.disk.readBps.value }, color: p.accent),
                                              GraphTrace(name: "w", values: series { $0.disk.writeBps.value }, color: p.accent2)], minHeadroom: 1_048_576)
        // Network is shown in bits/s (as ISPs quote it); the detail line and graph stay in bytes/s.
        case .network:
            return InstrumentReading(title: "Network", value: s?.network.inBps.value.flatMap { i in s?.network.outBps.value.map { Fmt.bits(i + $0) } },
                                     fraction: nil, showMeter: false,
                                     detail: s.map { "↓ " + ($0.network.inBps.value.map(Fmt.rate) ?? "—") + " · ↑ " + ($0.network.outBps.value.map(Fmt.rate) ?? "—") },
                                     traces: [GraphTrace(name: "in", values: series { $0.network.inBps.value }, color: p.accent),
                                              GraphTrace(name: "out", values: series { $0.network.outBps.value }, color: p.accent2)], minHeadroom: 65_536)
        case .energy:
            return InstrumentReading(title: "Energy", value: s?.power.systemWatts.value.map { String(format: "%.1f W", $0) },
                                     fraction: nil, showMeter: false,
                                     detail: s.map { pw in pw.power.powerSource + (pw.power.battery.map { String(format: " · battery %.0f%%", $0.percent) } ?? "") },
                                     traces: [GraphTrace(name: "w", values: series { $0.power.systemWatts.value }, color: p.accent)], minHeadroom: 10)
        // Hottest sensor on a 0–110 °C scale, matching the Thermals tab graph.
        case .thermals:
            return InstrumentReading(title: "Thermals", value: s?.power.hottest.value.map { Fmt.temp($0) },
                                     fraction: s?.power.hottest.value.map { $0 / 110 },
                                     detail: s.map { "thermal pressure: " + thermalName($0.power.thermalState) },
                                     traces: [GraphTrace(name: "t", values: series { $0.power.hottest.value }, color: p.accent)], maxValue: 110)
        case .gpu:
            return InstrumentReading(title: "GPU", value: s?.gpu.value.map { Fmt.pct($0) }, fraction: s?.gpu.value.map { $0 / 100 },
                                     detail: s.flatMap { x in x.gpuDetail.map { g in
                                         [g.frequencyMHz.map { String(format: "%.0f MHz", $0) }, g.powerWatts.map { String(format: "%.1f W", $0) },
                                          g.memoryInUse.map { Fmt.bytes($0) + " in use" }].compactMap { $0 }.joined(separator: " · ") } } ?? "device utilization",
                                     traces: [GraphTrace(name: "g", values: series { $0.gpu.value }, color: p.accent)], maxValue: 100)
        case .memoryPressure:
            // macOS's own level (normal / warning / critical) is shown alongside the 0–100 figure it's derived from.
            let level = s.map { m -> String in
                switch m.memory.pressureLevel { case 4: "critical"; case 2: "warning"; default: "normal" }
            }
            return InstrumentReading(title: "Memory Pressure", value: s?.memory.pressure.value.map { Fmt.pct($0) },
                                     fraction: s?.memory.pressure.value.map { $0 / 100 },
                                     detail: level.map { "macOS level: " + $0 },
                                     traces: [GraphTrace(name: "p", values: series { $0.memory.pressure.value }, color: p.accent)], maxValue: 100)
        case .swap:
            // The meter is swap used of swap allocated. With no swap allocated at all (macOS adds swap files only when
            // it needs them) there is no meter rather than an "unavailable" one, since nothing is unmeasured.
            let used = s?.memory.swapUsed.value, total = s?.memory.swapTotal.value
            return InstrumentReading(title: "Swap", value: used.map { Fmt.bytes($0) },
                                     fraction: used.flatMap { u in total.flatMap { $0 > 0 ? u / $0 : nil } },
                                     showMeter: total.map { $0 > 0 } ?? true,
                                     detail: total.map { $0 > 0 ? "of " + Fmt.bytes($0) + " allocated" : "no swap allocated" },
                                     traces: [GraphTrace(name: "s", values: series { $0.memory.swapUsed.value }, color: p.accent)], minHeadroom: 1_073_741_824)
        case .fans:
            // The busiest fan leads; every fan is listed in the detail. A Mac without fans says so instead of "0 rpm".
            let fans = s?.power.fans ?? []
            let lead = fans.max { $0.rpm < $1.rpm }
            return InstrumentReading(title: "Fans", value: lead.map { String(format: "%.0f rpm", $0.rpm) },
                                     fraction: lead.flatMap(fanFraction),
                                     detail: s == nil ? nil : fans.isEmpty ? "no fans reported"
                                        : fans.map { String(format: "fan %d %.0f", $0.index + 1, $0.rpm) }.joined(separator: " · "),
                                     traces: [GraphTrace(name: "f", values: series { $0.power.fans?.map(\.rpm).max() }, color: p.accent)], minHeadroom: 1000)
        case .battery:
            let b = s?.power.battery
            let state: String? = s.map { snap in
                guard let b = snap.power.battery else { return "no battery" }
                var parts = [b.isCharging ? "charging" : b.externalConnected ? "on power" : "on battery"]
                if let w = snap.power.batteryWatts.value { parts.append(String(format: "%+.1f W", w)) }
                if let t = b.timeRemaining, t > 0 { parts.append(String(format: "%d:%02d left", t / 60, t % 60)) }
                if let h = b.health { parts.append(String(format: "health %.0f%%", h)) }
                return parts.joined(separator: " · ")
            }
            return InstrumentReading(title: "Battery", value: b.map { String(format: "%.0f%%", $0.percent) },
                                     fraction: b.map { $0.percent / 100 }, detail: state,
                                     traces: [GraphTrace(name: "b", values: series { $0.power.battery?.percent }, color: p.accent)], maxValue: 100,
                                     meterColor: p.accent)
        case .wifi:
            // Not connected (or no Wi-Fi) is nil, never a weak signal. The graph plots dBm above −100 on a 0–70 scale
            // (−100…−30 dBm), since the graph can't draw negative values.
            let w = s?.wifi
            return InstrumentReading(title: "Wi-Fi", value: w.map { "\($0.rssi) dBm" }, fraction: w.map { wifiFraction($0.rssi) },
                                     detail: s == nil ? nil : w.map { x in
                                         [x.quality, "SNR \(x.snr) dB", String(format: "%.0f Mbps", x.txRate), x.band].compactMap { $0 }.joined(separator: " · ")
                                     } ?? "not connected",
                                     traces: [GraphTrace(name: "r", values: series { $0.wifi.map { Double($0.rssi + 100) } }, color: p.accent)], maxValue: 70,
                                     meterColor: p.accent)
        case .annunciator, .findings, .topProcesses, .cpuCores, .stressMap, .clock:
            return nil
        case .destinations, .restarts, .bootTime, .batteryHealth, .cameraMic:
            return nil   // page digests: CockpitFeeds.reading (Views/CockpitFeedReadings.swift)
        }
    }
}
