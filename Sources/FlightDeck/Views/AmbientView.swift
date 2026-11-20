import SwiftUI
import FlightDeckCore
// Ambient mode's content: a dim, glanceable instrument panel for a second display. A big clock and the master caution
// light across the top, large gauges (the gauge-type instruments of the chosen layout, see AmbientPlan) in the middle,
// and a findings ticker along the bottom.
//
// Cost: like the cockpit it redraws once per sample and has no continuous animation. The only other trigger is a
// once-a-minute TimelineView tick, which keeps the clock right while sampling is paused and moves the burn-in shift.
// The shift is a plain offset taken from `BurnIn.offset` for the current minute; it is never animated.

struct AmbientView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) private var themePalette
    @ObservedObject var model: CockpitModel
    /// Overall brightness (night style). Applied as opacity over the black window background.
    @AppStorage("ambientBrightness") private var brightness = 0.6
    /// Fixed time for off-screen renders; nil = the wall clock.
    var fixedNow: Date? = nil

    /// Night style: the theme's colours on pure black with near-black panels. A light theme uses the dark palette, since
    /// a white panel would light up a dark room.
    var palette: Palette {
        var p = themePalette.scheme == .light ? Palette.of(.dark) : themePalette
        p.background = .black
        p.panel = Color(white: 0.035)
        p.panelBorder = p.accent.opacity(0.10)
        return p
    }

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            content(now: fixedNow ?? ctx.date)
        }
        .environment(\.palette, palette)
        .environment(\.colorScheme, .dark)
        .opacity(brightness)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .contextMenu {
            Picker("Brightness", selection: $brightness) {
                Text("30%").tag(0.3); Text("45%").tag(0.45); Text("60%").tag(0.6); Text("80%").tag(0.8); Text("100%").tag(1.0)
            }
            Picker("Gauges From", selection: Binding(get: { model.store.ambientLayout?.id }, set: { model.store.ambient = $0 })) {
                if model.store.ambientLayout == nil { Text("Standard Gauges").tag(UUID?.none) }
                ForEach(model.store.layouts) { Text($0.name).tag(Optional($0.id)) }
            }
            Divider()
            Button("Exit Ambient Mode (Esc)") { AmbientController.shared.close() }
        }
    }

    func content(now: Date) -> some View {
        let p = palette
        let gauges = AmbientPlan.gauges(for: model.store.ambientLayout)
        let findings = e.findings.filter { !Alerts.shared.isMuted($0) }.sorted { $0.severity > $1.severity }
        let shift = BurnIn.offset(minute: BurnIn.minute(of: now))
        // Rows of at most four: 4 → one row, 5–6 → rows of three, 7–8 → rows of four.
        let cols = gauges.count <= 4 ? gauges.count : gauges.count <= 6 ? 3 : 4
        return VStack(spacing: 28) {
            HStack(alignment: .top) {
                AmbientClock(now: now, replay: e.mode == .replay)
                Spacer()
                MasterCaution(worst: findings.first?.severity, count: findings.count, collecting: e.current == nil)
            }
            // Plain stacks rather than a lazy grid: the rows share whatever height the screen has left (each gauge's
            // graph flexes), so the ticker stays on screen from a 4:3 iPad to an ultrawide. A short last row keeps
            // its gauges the same width as the rows above.
            let rows = stride(from: 0, to: gauges.count, by: max(cols, 1)).map { Array(gauges[$0..<min($0 + cols, gauges.count)]) }
            VStack(spacing: 22) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 22) {
                        ForEach(row) { k in
                            if let r = e.reading(k, p) { AmbientGauge(r: r) } else { FeedReading(kind: k, now: now) { AmbientGauge(r: $0) } }
                        }
                        ForEach(row.count..<cols, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            AmbientTicker(findings: findings, now: now, collecting: e.current == nil)
        }
        .padding(48)
        .offset(x: CGFloat(shift.x), y: CGFloat(shift.y))
    }
}

/// Big local time and date. "REPLAY" is shown while the gauges show a recording rather than this moment.
struct AmbientClock: View {
    @Environment(\.palette) var p
    var now: Date
    var replay: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 104, weight: .light, design: .monospaced)).foregroundStyle(p.text)
                .shadow(color: p.accent.opacity(p.glow > 0 ? 0.35 : 0), radius: p.glow * 4)
                .lineLimit(1).minimumScaleFactor(0.5)
            HStack(spacing: 14) {
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                if let boot = ClockInstrument.bootTime {
                    Text("· UP " + ClockInstrument(size: .small).uptime(now.timeIntervalSince(boot)).uppercased())
                }
                if replay { Text("REPLAY").foregroundStyle(p.warn) }
            }
            .font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundStyle(p.dim)
        }
    }
}

/// The master caution light: dark when all is well; lit (filled with the severity colour, with a steady glow) while
/// any unmuted finding is a caution or warning. Info-level findings only tint its outline.
struct MasterCaution: View {
    @Environment(\.palette) var p
    var worst: Finding.Severity?
    var count: Int
    var collecting: Bool
    var body: some View {
        let lit = worst.map { $0 >= .caution } ?? false
        let c = worst.map(p.color) ?? p.panelBorder
        VStack(spacing: 10) {
            Text(worst == .warning ? "MASTER\nWARNING" : "MASTER\nCAUTION")
                .multilineTextAlignment(.center)
                .font(.system(size: 26, weight: .heavy, design: .monospaced))
                .foregroundStyle(lit ? Color.black : p.dim.opacity(0.45))
                .frame(width: 230, height: 110)
                .background(RoundedRectangle(cornerRadius: 10).fill(lit ? c : p.panel))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(worst == nil ? p.panelBorder : c, lineWidth: 2))
                .shadow(color: lit ? c.opacity(0.75) : .clear, radius: 22)
            Text(collecting ? "COLLECTING" : count == 0 ? "ALL SYSTEMS NORMAL" : "\(count) FINDING\(count == 1 ? "" : "S")")
                .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(lit ? c : p.dim)
        }
    }
}

/// One large gauge: the same reading as the cockpit card, sized to be read across a room.
struct AmbientGauge: View {
    @Environment(\.palette) var p
    var r: InstrumentReading
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(r.title.uppercased()).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
            Text(r.value ?? "—")
                .font(.system(size: 64, weight: .medium, design: .monospaced))
                .foregroundStyle(r.value == nil ? p.dim : p.text)
                .shadow(color: p.accent.opacity(p.glow > 0 && r.value != nil ? 0.5 : 0), radius: p.glow * 2)
                .lineLimit(1).minimumScaleFactor(0.4)
            if r.showMeter { VFDMeter(fraction: r.fraction, segments: 32, color: r.meterColor, height: 16) }
            HistoryGraph(traces: r.traces, maxValue: r.maxValue, minHeadroom: r.minHeadroom).frame(minHeight: 40, maxHeight: 220)
            Text(r.detail ?? "—").font(.system(size: 15, design: .monospaced)).foregroundStyle(r.detailColor ?? p.dim).lineLimit(1)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(p.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(p.panelBorder))
    }
}

/// Findings, one at a time, worst first. It steps to the next finding every 8 s of wall-clock time when the view
/// redraws (once per sample), so it reads as a ticker without any scrolling animation.
struct AmbientTicker: View {
    @Environment(\.palette) var p
    var findings: [Finding]
    var now: Date
    var collecting: Bool
    static let step: TimeInterval = 8

    var body: some View {
        let i = findings.isEmpty ? 0 : Int(now.timeIntervalSince1970 / Self.step) % findings.count
        let f = findings.isEmpty ? nil : findings[i]
        HStack(spacing: 16) {
            Image(systemName: f?.icon ?? (collecting ? "hourglass" : "checkmark.seal"))
                .font(.system(size: 26)).foregroundStyle(f.map { p.color($0.severity) } ?? p.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(f?.title ?? (collecting ? "Collecting first samples…" : "All systems normal"))
                    .font(.system(size: 24, weight: .semibold, design: .monospaced)).foregroundStyle(p.text).lineLimit(1)
                Text(f?.detail ?? (collecting ? " " : "Nothing is holding this Mac back right now."))
                    .font(.system(size: 16, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1)
            }
            Spacer()
            if findings.count > 1 {
                Text("\(i + 1)/\(findings.count)").font(.system(size: 18, weight: .semibold, design: .monospaced)).foregroundStyle(p.dim)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14).fill((f.map { p.color($0.severity) } ?? p.accent).opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder((f.map { p.color($0.severity) } ?? p.accent).opacity(0.3)))
    }
}
