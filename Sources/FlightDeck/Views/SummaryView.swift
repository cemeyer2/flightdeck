import SwiftUI
import FlightDeckCore
// Summary destination, the app's front page: the annunciator panel, the diagnosis banner (analyzer findings),
// one card per subsystem with a short history graph, and the top process per resource. Everything is read from
// `e.current` / `e.series`, so the page also replays recordings.

/// Wrapped in MaybeScroll so UIBench can render it off-screen (a ScrollView renders empty there).
struct SummaryView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p

    var body: some View {
        MaybeScroll {
            VStack(spacing: 12) {
                AnnunciatorPanel()
                DiagnosisBanner()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    let s = e.current
                    SummaryCard(title: "CPU", value: s?.cpu.total.value.map { Fmt.pct($0) },
                                fraction: s?.cpu.total.value.map { $0 / 100 },
                                detail: s.map { String(format: "load %.2f %.2f %.2f", $0.cpu.loadAverage[0], $0.cpu.loadAverage[1], $0.cpu.loadAverage[2]) },
                                traces: [GraphTrace(name: "cpu", values: e.series { $0.cpu.total.value }, color: p.accent)], maxValue: 100)
                    SummaryCard(title: "Memory", value: s.flatMap { $0.memory.isMeasured ? Fmt.bytes($0.memory.used) : nil },
                                fraction: s.flatMap { $0.memory.isMeasured ? Double($0.memory.used) / Double(max($0.memory.total, 1)) : nil },
                                detail: s.map { "pressure " + ($0.memory.pressure.value.map { Fmt.pct($0) } ?? "—") + " · swap " + ($0.memory.swapUsed.value.map { Fmt.bytes($0) } ?? "—") },
                                traces: [GraphTrace(name: "mem", values: e.series { Double($0.memory.used) / Double(max($0.memory.total, 1)) * 100 }, color: p.accent),
                                         GraphTrace(name: "pressure", values: e.series { $0.memory.pressure.value }, color: p.accent2, fill: false)], maxValue: 100)
                    // Disk, Network and Energy have no natural 0–100% scale, so they show no meter; the value is "—"
                    // unless both directions were measured, rather than adding a known half to an unknown one.
                    SummaryCard(title: "Disk", value: s?.disk.readBps.value.flatMap { r in s?.disk.writeBps.value.map { Fmt.rate(r + $0) } },
                                fraction: nil, showMeter: false,
                                detail: s.map { "R " + ($0.disk.readBps.value.map(Fmt.rate) ?? "—") + " · W " + ($0.disk.writeBps.value.map(Fmt.rate) ?? "—") },
                                traces: [GraphTrace(name: "r", values: e.series { $0.disk.readBps.value }, color: p.accent),
                                         GraphTrace(name: "w", values: e.series { $0.disk.writeBps.value }, color: p.accent2)], minHeadroom: 1_048_576)
                    // Network is shown in bits/s (as ISPs quote it); the detail line and graph stay in bytes/s.
                    SummaryCard(title: "Network", value: s?.network.inBps.value.flatMap { i in s?.network.outBps.value.map { Fmt.bits(i + $0) } },
                                fraction: nil, showMeter: false,
                                detail: s.map { "↓ " + ($0.network.inBps.value.map(Fmt.rate) ?? "—") + " · ↑ " + ($0.network.outBps.value.map(Fmt.rate) ?? "—") },
                                traces: [GraphTrace(name: "in", values: e.series { $0.network.inBps.value }, color: p.accent),
                                         GraphTrace(name: "out", values: e.series { $0.network.outBps.value }, color: p.accent2)], minHeadroom: 65_536)
                    SummaryCard(title: "Energy", value: s?.power.systemWatts.value.map { String(format: "%.1f W", $0) },
                                fraction: nil, showMeter: false,
                                detail: s.map { pw in pw.power.powerSource + (pw.power.battery.map { String(format: " · battery %.0f%%", $0.percent) } ?? "") },
                                traces: [GraphTrace(name: "w", values: e.series { $0.power.systemWatts.value }, color: p.accent)], minHeadroom: 10)
                    // Hottest sensor on a 0–110 °C scale, matching the Thermals tab graph.
                    SummaryCard(title: "Thermals", value: s?.power.hottest.value.map { String(format: "%.0f °C", $0) },
                                fraction: s?.power.hottest.value.map { $0 / 110 },
                                detail: s.map { "thermal pressure: " + thermalName($0.power.thermalState) },
                                traces: [GraphTrace(name: "t", values: e.series { $0.power.hottest.value }, color: p.accent)], maxValue: 110)
                    SummaryCard(title: "GPU", value: s?.gpu.value.map { Fmt.pct($0) }, fraction: s?.gpu.value.map { $0 / 100 },
                                detail: s.flatMap { x in x.gpuDetail.map { g in
                                    [g.frequencyMHz.map { String(format: "%.0f MHz", $0) }, g.powerWatts.map { String(format: "%.1f W", $0) },
                                     g.memoryInUse.map { Fmt.bytes($0) + " in use" }].compactMap { $0 }.joined(separator: " · ") } } ?? "device utilization",
                                traces: [GraphTrace(name: "g", values: e.series { $0.gpu.value }, color: p.accent)], maxValue: 100)
                    TopProcessesCard()
                }
            }
            .padding(16)
        }
    }
}

/// Display name for macOS thermal state 0–3 (ProcessInfo.ThermalState order); out-of-range values are clamped.
func thermalName(_ s: Int) -> String { ["Nominal", "Fair", "Serious", "Critical"][min(max(s, 0), 3)] }

/// One subsystem card: big current value ("—" when unmeasured), optional segmented meter, 70 pt history graph of
/// Engine's rolling history (nil frames draw as gaps) and a one-line detail.
struct SummaryCard: View {
    @Environment(\.palette) var p
    var title: String
    var value: String?
    var fraction: Double?
    var showMeter = true
    var detail: String?
    var traces: [GraphTrace]
    var maxValue: Double? = nil
    var minHeadroom: Double = 1

    var body: some View {
        Panel(title: title) {
            HStack(alignment: .bottom) {
                Readout(label: "now", value: value, size: 26)
                Spacer()
            }
            if showMeter { VFDMeter(fraction: fraction, segments: 30) }
            HistoryGraph(traces: traces, maxValue: maxValue, minHeadroom: minHeadroom).frame(height: 70)
            Text(detail ?? "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1)
        }
    }
}

/// The single heaviest process for each resource in the current snapshot. Energy and network only consider processes
/// where that metric was measured, so an unmeasured process never wins as "0 W".
struct TopProcessesCard: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var body: some View {
        Panel(title: "Top Processes") {
            let procs = e.current?.processes ?? []
            VStack(alignment: .leading, spacing: 6) {
                row("CPU", procs.max { $0.cpu < $1.cpu }.map { ($0.name, Fmt.pct($0.cpu)) })
                row("Memory", procs.max { $0.memory < $1.memory }.map { ($0.name, Fmt.bytes($0.memory)) })
                row("Energy", procs.filter { $0.energyWatts != nil }.max { ($0.energyWatts ?? 0) < ($1.energyWatts ?? 0) }.map { ($0.name, String(format: "%.2f W", $0.energyWatts ?? 0)) })
                row("Network", procs.filter { $0.network != nil }.max { ($0.network!.inBps + $0.network!.outBps) < ($1.network!.inBps + $1.network!.outBps) }.map { ($0.name, Fmt.rate($0.network!.inBps + $0.network!.outBps)) })
                row("Disk", procs.max { $0.diskReadBps + $0.diskWriteBps < $1.diskReadBps + $1.diskWriteBps }.map { ($0.name, Fmt.rate($0.diskReadBps + $0.diskWriteBps)) })
                row("Wakeups", procs.max { $0.wakeups < $1.wakeups }.map { ($0.name, String(format: "%.0f/s", $0.wakeups)) })
            }
            .font(.system(size: 12, design: .monospaced))
        }
    }
    func row(_ k: String, _ v: (String, String)?) -> some View {
        HStack {
            Text(k.uppercased()).font(.meterLabel).foregroundStyle(p.dim).frame(width: 64, alignment: .leading)
            Text(v?.0 ?? "—").foregroundStyle(p.text).lineLimit(1)
            Spacer()
            Text(v?.1 ?? "—").foregroundStyle(p.accent)
        }
    }
}

/// Answers "why is my Mac slow?" from the current frame.
/// Shows at most six findings (the rest via the Flight Log) on a background tinted by the worst severity. During replay
/// `e.findings` are the findings recomputed for the replayed moment.
struct DiagnosisBanner: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p

    var body: some View {
        let all = e.findings
        let f = all.filter { !Alerts.shared.isMuted($0) }
        let muted = all.count - f.count
        let worst = f.map(\.severity).max()
        VStack(alignment: .leading, spacing: 8) {
            if e.current == nil {
                Label("Collecting first samples…", systemImage: "hourglass").foregroundStyle(p.text)
            } else if f.isEmpty {
                Label("All systems normal. Nothing is holding this Mac back right now.", systemImage: "checkmark.seal")
                    .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(p.text)
            }
            ForEach(f.prefix(6)) { FindingRow(f: $0) }
            if f.count > 6 {
                Button("\(f.count - 6) more in the Flight Log") { e.navigationRequest = Destination.flightLog.rawValue }
                    .buttonStyle(.link).font(.caption)
            }
            if muted > 0 {
                Text("\(muted) muted finding\(muted == 1 ? "" : "s") (right-click a finding to mute or unmute)").font(.caption).foregroundStyle(p.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill((worst.map(p.color) ?? p.accent).opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((worst.map(p.color) ?? p.accent).opacity(0.35)))
    }
}

/// Cockpit annunciator: one labelled light per subsystem, lit by the worst finding in it.
/// Each light matches findings by id prefix (the ids are assigned by the Analyzer and DiagnosticReports, e.g.
/// "cpu:<app>", "leak:<app>", "report:Crash…"). A finding can light more than one lamp (e.g. "cpu-throttled" lights
/// CPU and THERM). Caution/warning lights fill with their colour; info only tints. Clicking goes to the first matching
/// finding's destination, or the light's default page.
struct AnnunciatorPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p

    // (label, finding-id prefixes, default navigation target as a Destination raw value or "Performance:<tab>")
    static let lights: [(label: String, match: [String], dest: String)] = [
        ("CPU", ["cpu:", "cpu-saturated", "unusual-cpu", "cpu-throttled", "wakeups:"], "Performance:CPU"),
        ("MEM", ["mem-pressure", "leak:"], "Performance:Memory"),
        ("SWAP", ["swap-", "swapping"], "Performance:Memory"),
        ("THERM", ["thermal", "gpu-thermal", "cpu-throttled"], "Performance:Thermals"),
        ("DISK", ["disk-busy", "drive:"], "Performance:Disk"),
        ("STORAGE", ["disk-low", "disk-full"], "Disk Space"),
        ("NET", ["net-", "wifi-weak"], "Performance:Network"),
        ("GPU", ["gpu:", "gpu-recovery", "gpu-memory"], "Performance:GPU"),
        ("POWER", ["unusual-power", "battery-health", "sleep-"], "Performance:Energy"),
        ("HANG", ["hang:", "report:Hang"], "Processes"),
        ("CRASH", ["report:Crash"], "Flight Log"),
        ("AWAKE", ["awake:"], "Processes"),
    ]

    var body: some View {
        let f = e.findings.filter { !Alerts.shared.isMuted($0) }   // muted findings don't light the annunciator
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(Self.lights, id: \.label) { light in
                let hits = f.filter { x in light.match.contains { x.id.hasPrefix($0) } }.sorted { $0.severity > $1.severity }
                let sev = hits.map(\.severity).max()
                Button { e.navigationRequest = hits.first?.destination ?? light.dest } label: {
                    Text(light.label)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundStyle(sev.map { $0 >= .caution ? Color.black : p.text } ?? p.dim.opacity(0.6))
                        .background(RoundedRectangle(cornerRadius: 4).fill(sev.map { $0 >= .caution ? p.color($0) : p.accent.opacity(0.25) } ?? p.panel))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(sev.map { p.color($0) } ?? p.panelBorder, lineWidth: 1))
                        .shadow(color: sev.map { $0 >= .caution ? p.color($0).opacity(0.6) : .clear } ?? .clear, radius: 5)
                }
                .buttonStyle(.plain)
                .help(hits.isEmpty ? "\(light.label): normal" : hits.map(\.title).joined(separator: "\n"))
            }
        }
    }
}
