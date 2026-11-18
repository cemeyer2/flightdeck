import SwiftUI
import FlightDeckCore
// The view for each cockpit instrument kind. Gauge-type kinds are SummaryCards built from `Engine.reading`; the rest
// reuse the Summary page's own panels (annunciator, findings banner, top processes) or existing components (CoreTile,
// the Stress Map's static drawing). Nothing here animates: every instrument redraws once per sample.

/// One placed instrument, drawn at its size.
struct InstrumentView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var slot: InstrumentSlot

    /// History graph height per size: small matches the classic Summary card (70 pt); bigger cards get a taller graph.
    static func graphHeight(_ s: InstrumentSize) -> CGFloat {
        switch s { case .small: 70; case .medium: 90; case .large: 110 }
    }

    var body: some View {
        switch slot.kind {
        case .annunciator: AnnunciatorPanel()
        case .findings: DiagnosisBanner()
        case .topProcesses: TopProcessesCard()
        case .cpuCores: CPUCoresInstrument(size: slot.size)
        case .stressMap: StressMapInstrument(size: slot.size)
        case .clock: ClockInstrument(size: slot.size)
        default:
            if let r = e.reading(slot.kind, p) { SummaryCard(r, graphHeight: Self.graphHeight(slot.size)) }
        }
    }
}

extension SummaryCard {
    /// A card for one instrument reading (in an extension so SummaryCard keeps its memberwise initializer).
    init(_ r: InstrumentReading, graphHeight: CGFloat = 70) {
        self.init(title: r.title, value: r.value, fraction: r.fraction, showMeter: r.showMeter, detail: r.detail,
                  traces: r.traces, maxValue: r.maxValue, minHeadroom: r.minHeadroom, graphHeight: graphHeight,
                  meterColor: r.meterColor)
    }
}

/// Per-core CPU. Small and medium: a strip of vertical bars, one per logical core, tinted by P/E kind and drawn in one
/// Canvas (cheap even with 24 cores). Large: the Performance tab's CoreTile grid, with a history graph per core.
struct CPUCoresInstrument: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var size: InstrumentSize

    var body: some View {
        let cores = e.current?.cpu.cores ?? []
        let pCount = cores.filter { $0.kind == .performance }.count, eCount = cores.filter { $0.kind == .efficiency }.count
        Panel(title: "CPU Cores", trailing: cores.isEmpty ? nil : pCount + eCount > 0 ? "\(pCount) P · \(eCount) E" : "\(cores.count) cores") {
            if cores.isEmpty {
                Text("—").font(.system(size: 26, design: .monospaced)).foregroundStyle(p.dim)
            } else if size == .large {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                    ForEach(cores.indices, id: \.self) { CoreTile(index: $0) }
                }
            } else {
                strip(cores).frame(height: size == .small ? 96 : 118)
                CoreLegend()
            }
        }
    }

    /// One bar per core, filled to its current %, over a dim track; the core number sits under each bar.
    func strip(_ cores: [CoreSample]) -> some View {
        Canvas { ctx, sz in
            let n = CGFloat(cores.count), gap: CGFloat = n > 16 ? 2 : 4
            let w = max((sz.width - gap * (n - 1)) / n, 2), labelH: CGFloat = 12, h = sz.height - labelH
            for (i, c) in cores.enumerated() {
                let x = CGFloat(i) * (w + gap)
                let color = c.kind == .efficiency ? p.eCore : p.pCore
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: w, height: h), cornerRadius: 1.5), with: .color(p.meterOff))
                let fill = h * CGFloat(min(max(c.total / 100, 0), 1))
                if fill > 0 {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: h - fill, width: w, height: fill), cornerRadius: 1.5), with: .color(color))
                }
                if w >= 9 {
                    ctx.draw(Text("\(c.index)").font(.system(size: 8, design: .monospaced)).foregroundColor(p.dim),
                             at: CGPoint(x: x + w / 2, y: sz.height - labelH / 2))
                }
            }
        }
        .accessibilityLabel("Per-core CPU usage")
    }
}

/// A small Stress Map. It always uses the map's static SwiftUI drawing (the off-screen path), not the Core Animation
/// layers of the full page: the cockpit stays free of continuous motion and the map just redraws once per sample.
/// Clicking opens the Stress Map page.
struct StressMapInstrument: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var size: InstrumentSize

    var body: some View {
        let r = e.current.map { Stress.report($0) }
        Panel(title: "Stress Map", trailing: r.map { $0.apps.isEmpty ? "all quiet" : "\($0.apps.count) straining" }) {
            if let r, let s = e.current {
                StressMap(report: r, sampleTime: s.time, hovered: .constant(nil))
                    .environment(\.offscreen, true)
                    .frame(maxWidth: .infinity)
                    .frame(height: size == .small ? 250 : size == .medium ? 300 : 380)
                    .contentShape(Rectangle())
                    .onTapGesture { e.navigationRequest = Destination.stressMap.rawValue }
                    .help("Open the Stress Map")
            } else {
                Text("—").font(.system(size: 26, design: .monospaced)).foregroundStyle(p.dim)
            }
        }
    }
}

/// Local time, date and how long the Mac has been up. Read from the wall clock when the view redraws, which happens
/// once per sample, so the minute display is never more than a sample late. Uptime is shown at minute precision.
struct ClockInstrument: View {
    @Environment(\.palette) var p
    @EnvironmentObject var e: Engine   // observed only so the clock redraws with each sample
    var size: InstrumentSize

    /// Boot time doesn't change while we run, so it's read once.
    static let bootTime = Sysctl.timeval("kern.boottime")

    var body: some View {
        let now = Date()
        Panel(title: "Clock", trailing: now.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
            HStack(alignment: .bottom, spacing: 28) {
                Readout(label: "local time", value: now.formatted(date: .omitted, time: .shortened), size: size == .small ? 26 : 34)
                Readout(label: "uptime", value: Self.bootTime.map { uptime(now.timeIntervalSince($0)) }, size: size == .small ? 18 : 22)
                Spacer()
            }
            if size != .small {
                Text(TimeZone.current.localizedName(for: .standard, locale: .current) ?? TimeZone.current.identifier)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1)
            }
        }
    }

    /// "3d 4h 12m", "4h 12m" or "12m".
    func uptime(_ s: TimeInterval) -> String {
        let t = Int(max(s, 0)) / 60, d = t / 1440, h = (t % 1440) / 60, m = t % 60
        return d > 0 ? "\(d)d \(h)h \(m)m" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
