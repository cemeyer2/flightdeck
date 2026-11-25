import SwiftUI
import FlightDeckCore
// Summary destination, the app's front page: the annunciator panel, the diagnosis banner (analyzer findings),
// one card per subsystem with a short history graph, and the top process per resource, arranged by the user's cockpit
// layout. Everything is read from `e.current` / `e.series`, so the page also replays recordings.

/// The Summary page is the customizable cockpit (CockpitView.swift): the user's chosen layout of instruments, which by
/// default is exactly the classic Summary (annunciator, findings banner, one card per subsystem, top processes).
/// The cards' contents live in CockpitReadings.swift; the panels below are instruments too.
struct SummaryView: View {
    var body: some View { CockpitView() }
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
    /// Taller for medium and large cockpit instruments; 70 pt is the classic Summary card.
    var graphHeight: CGFloat = 70
    /// Single meter colour (see InstrumentReading.meterColor); nil keeps the usual level shading.
    var meterColor: Color? = nil
    /// Tints the detail line (see InstrumentReading.detailColor); nil keeps it dim.
    var detailColor: Color? = nil

    var body: some View {
        Panel(title: title) {
            HStack(alignment: .bottom) {
                Readout(label: "now", value: value, size: 26)
                Spacer()
            }
            if showMeter { VFDMeter(fraction: fraction, segments: 30, color: meterColor) }
            HistoryGraph(traces: traces, maxValue: maxValue, minHeadroom: minHeadroom).frame(height: graphHeight)
            Text(detail ?? "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(detailColor ?? p.dim).lineLimit(1)
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

/// Cockpit annunciator: one labelled light per subsystem, lit by the worst finding in it (the table and matching are
/// `Annunciator` in FlightDeckCore, shared with the web dashboard). Caution/warning lights fill with their colour;
/// info only tints. Clicking goes to the first matching finding's destination, or the light's default page.
struct AnnunciatorPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p

    var body: some View {
        let f = e.findings.filter { !Alerts.shared.isMuted($0) }   // muted findings don't light the annunciator
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(Annunciator.lights, id: \.label) { light in
                let hits = Annunciator.hits(light, in: f)
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
