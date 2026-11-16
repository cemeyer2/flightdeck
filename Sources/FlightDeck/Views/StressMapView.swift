import SwiftUI
import FlightDeckCore
// Stress Map destination: "which apps are causing misery to which parts of my Mac, right now?" as one picture.
// Subsystems are hubs on a ring, glowing from calm to amber to red; apps are bubbles inside it, sized by their misery
// and pulled toward the hubs they strain, with routes drawn to each of those hubs. Scoring lives in
// FlightDeckCore/Stress.swift; this file only lays out and draws. Everything is read from `e.current`, so the map
// also replays recordings.
//
// Cost: one `Stress.report` (an AppUsage aggregate) and a tiny relaxation over ≤ 12 bubbles per render. Hubs,
// backdrop and routes are drawn in one Canvas; only the bubbles are views, because they need hover and click.

/// The Stress Map page: the map on the left; detail of the hovered (or worst) app, the top causers and a legend on
/// the right. Wrapped in MaybeScroll so UIBench can render it off-screen.
struct StressMapView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    /// App id under the pointer (bubble or ranked row); drives highlighting and the detail panel.
    @State private var hovered: String?

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                if let s = e.current {
                    let r = Stress.report(s)
                    let focus = r.apps.first { $0.id == hovered }
                    HStack(alignment: .top, spacing: 12) {
                        Panel(title: "Stress Map", trailing: r.apps.isEmpty ? "all quiet"
                              : "\(r.apps.count) app\(r.apps.count == 1 ? "" : "s") straining this Mac") {
                            StressMap(report: r, hovered: $hovered).aspectRatio(1, contentMode: .fit)
                        }
                        .frame(minWidth: 420, maxWidth: 760)
                        VStack(spacing: 12) {
                            MiseryDetail(m: focus ?? r.apps.first, hovering: focus != nil)
                            TopCausers(apps: r.apps, hovered: $hovered)
                            StressLegend()
                        }
                        .frame(width: 340)
                    }
                } else {
                    Label("Collecting first samples…", systemImage: "hourglass").foregroundStyle(p.text)
                }
            }
            .padding(16)
        }
    }
}

extension Palette {
    /// Colour for a stress or misery level 0…1: the calm accent below 0.3, `warn` up to 0.6, then blending to `crit`
    /// by 0.85. Single-hue themes stay on the accent (hue carries no meaning there; opacity and glow still do).
    func strain(_ x: Double) -> Color {
        if mono { return accent }
        func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
            guard let ca = NSColor(a).usingColorSpace(.sRGB), let cb = NSColor(b).usingColorSpace(.sRGB),
                  let m = ca.blended(withFraction: min(max(t, 0), 1), of: cb) else { return t < 0.5 ? a : b }
            // Rebuilt as a plain sRGB Color: wrapping the blended NSColor directly can carry an extended-range colour
            // space into the render (the off-screen PNG came out tagged HDR/PQ and looked washed out).
            return Color(.sRGB, red: Double(m.redComponent), green: Double(m.greenComponent), blue: Double(m.blueComponent), opacity: Double(m.alphaComponent))
        }
        // Accent → amber is a step, not a blend: cyan and orange mix to a muddy grey that reads as "unmeasured".
        // Amber → red blends fine.
        if x < 0.3 { return accent }
        if x <= 0.6 { return warn }
        if x <= 0.85 { return mix(warn, crit, (x - 0.6) / 0.25) }
        return crit
    }
}

/// SF Symbol for each hub.
func stressIcon(_ s: Subsystem) -> String {
    switch s {
    case .cpu: "cpu"; case .memory: "memorychip"; case .disk: "internaldrive"; case .network: "network"
    case .gpu: "cube.transparent"; case .thermal: "thermometer.medium"; case .energy: "bolt.fill"
    }
}

/// AppIcon wants a path inside a bundle, so bundle paths get a trailing "/" (as in the Apps view).
func appIconPath(_ a: AppUsage) -> String { a.iconPath.hasSuffix(".app") ? a.iconPath + "/" : a.iconPath }

/// Fixed proportions of the map for a given size: where the ring, hubs and the bubble area are.
struct MapGeometry {
    var size: CGSize
    var side: CGFloat { min(size.width, size.height) }
    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    var ringR: CGFloat { side * 0.37 }
    var hubR: CGFloat { side * 0.052 }
    /// Bubbles stay inside this radius, clear of the hubs and their glow.
    var innerR: CGFloat { ringR - hubR - side * 0.03 }

    /// Hub order around the ring, clockwise from the top. Related subsystems are neighbours: Thermal sits between GPU
    /// and Energy, Memory next to CPU, so an app straining both lands between them instead of across the map.
    static let order: [Subsystem] = [.cpu, .gpu, .thermal, .energy, .network, .disk, .memory]

    func hub(_ s: Subsystem) -> CGPoint {
        let i = Double(Self.order.firstIndex(of: s) ?? 0)
        let a = -Double.pi / 2 + 2 * Double.pi * i / Double(Self.order.count)
        return CGPoint(x: center.x + ringR * cos(a), y: center.y + ringR * sin(a))
    }
}

/// One placed app bubble.
struct PlacedBubble: Identifiable {
    var id: String { m.id }
    var m: AppMisery
    var center: CGPoint
    var radius: CGFloat
}

/// The ring of hubs, the routes and the app bubbles.
struct StressMap: View {
    @Environment(\.palette) var p
    var report: StressReport
    @Binding var hovered: String?
    /// Only the biggest bubbles get a name label; more would collide on a busy map.
    static let labelled = 6

    var body: some View {
        GeometryReader { geo in
            let g = MapGeometry(size: geo.size)
            let bubbles = layout(g)
            ZStack {
                Canvas { ctx, _ in
                    drawBackdrop(&ctx, g)
                    drawRoutes(&ctx, g, bubbles)
                    drawHubs(&ctx, g)
                }
                if report.apps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal").font(.system(size: g.side * 0.07, weight: .light)).foregroundStyle(p.accent)
                        Text("All quiet").font(.system(size: g.side * 0.04, weight: .semibold, design: .monospaced)).foregroundStyle(p.text)
                        Text("No app is straining this Mac right now").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                    }
                    .position(g.center)
                }
                ForEach(Array(bubbles.enumerated()), id: \.element.id) { i, b in
                    MiseryBubble(m: b.m, radius: b.radius, showName: i < Self.labelled,
                                 highlighted: hovered == b.id, dimmed: hovered != nil && hovered != b.id)
                        .onHover { inside in if inside { hovered = b.id } else if hovered == b.id { hovered = nil } }
                        .onTapGesture { if let id = b.m.busiest, id.pid > 0 { AppActions.openInspector?(id) } }
                        .position(b.center)
                }
            }
        }
    }

    /// Places each app: bubble area ∝ misery; position is the misery-weighted average of the hubs it strains, drawn
    /// 75% of the way out (so one-hub apps sit near "their" hub and mixed ones nearer the middle), then a few rounds of
    /// pairwise pushing so bubbles don't overlap, kept inside the ring. Deterministic, so bubbles don't jitter
    /// between frames when nothing changed.
    func layout(_ g: MapGeometry) -> [PlacedBubble] {
        let maxR = g.side * 0.085, minR = g.side * 0.024
        var bs: [PlacedBubble] = report.apps.enumerated().map { i, m in
            var x = 0.0, y = 0.0, w = 0.0
            for (sub, c) in m.contributions { let h = g.hub(sub); x += h.x * c; y += h.y * c; w += c }
            var pt = w > 0 ? CGPoint(x: g.center.x + (x / w - g.center.x) * 0.75, y: g.center.y + (y / w - g.center.y) * 0.75) : g.center
            // A small golden-angle offset per rank, so apps aimed at the same spot separate in a stable direction.
            let a = Double(i) * 2.399963
            pt.x += cos(a) * 3; pt.y += sin(a) * 3
            return PlacedBubble(m: m, center: pt, radius: max(minR, maxR * sqrt(m.total)))
        }
        func clamp(_ b: inout PlacedBubble) {
            let dx = b.center.x - g.center.x, dy = b.center.y - g.center.y, d = hypot(dx, dy)
            let lim = max(g.innerR - b.radius, 0)
            if d > lim, d > 0 { b.center = CGPoint(x: g.center.x + dx / d * lim, y: g.center.y + dy / d * lim) }
        }
        for _ in 0..<60 {
            var moved = false
            for i in bs.indices { for j in bs.indices where j > i {
                let dx = bs[j].center.x - bs[i].center.x, dy = bs[j].center.y - bs[i].center.y
                let d = max(hypot(dx, dy), 0.01), need = bs[i].radius + bs[j].radius + 14   // room for name labels
                guard d < need else { continue }
                // The smaller bubble moves more, so big offenders stay close to where their misery puts them.
                let push = need - d, ri = bs[i].radius, rj = bs[j].radius
                let fi = rj / (ri + rj), fj = ri / (ri + rj)
                bs[i].center.x -= dx / d * push * fi; bs[i].center.y -= dy / d * push * fi
                bs[j].center.x += dx / d * push * fj; bs[j].center.y += dy / d * push * fj
                moved = true
            } }
            for i in bs.indices { clamp(&bs[i]) }
            if !moved { break }
        }
        return bs
    }

    /// Faint range rings and spokes, plus the ring the hubs sit on.
    func drawBackdrop(_ ctx: inout GraphicsContext, _ g: MapGeometry) {
        let c = g.center
        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
        ctx.fill(circle(g.innerR), with: .radialGradient(Gradient(colors: [p.accent.opacity(0.06), .clear]), center: c, startRadius: 0, endRadius: g.innerR))
        for f in [0.33, 0.66, 1.0] { ctx.stroke(circle(g.innerR * f), with: .color(p.grid), lineWidth: 1) }
        var spokes = Path()
        for s in MapGeometry.order { spokes.move(to: c); spokes.addLine(to: g.hub(s)) }
        ctx.stroke(spokes, with: .color(p.grid), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        ctx.stroke(circle(g.ringR), with: .color(p.dim.opacity(0.25)), lineWidth: 1.5)
    }

    /// One curved route per (app, strained hub), thickness and opacity ∝ that contribution, shaded from the app's
    /// colour to the hub's. Routes of other apps fade while one app is hovered.
    func drawRoutes(_ ctx: inout GraphicsContext, _ g: MapGeometry, _ bubbles: [PlacedBubble]) {
        for b in bubbles {
            let from = p.strain(b.m.hung ? 1 : b.m.worst)
            let fade = hovered != nil && hovered != b.id
            for (sub, c) in b.m.contributions where c >= 0.01 {
                let h = g.hub(sub)
                let dx = h.x - b.center.x, dy = h.y - b.center.y, len = max(hypot(dx, dy), 1)
                let end = CGPoint(x: h.x - dx / len * g.hubR, y: h.y - dy / len * g.hubR)
                // Bend every route the same way (perpendicular, 18% of its length) so they read as flight arcs.
                let mid = CGPoint(x: (b.center.x + end.x) / 2 - dy * 0.18, y: (b.center.y + end.y) / 2 + dx * 0.18)
                var path = Path(); path.move(to: b.center); path.addQuadCurve(to: end, control: mid)
                let k = min(1, c * 2.5)
                let alpha = fade ? 0.07 : 0.4 + 0.55 * k
                let to = p.strain(report.hub(sub)?.stress ?? 0)
                ctx.stroke(path, with: .linearGradient(Gradient(colors: [from.opacity(alpha), to.opacity(alpha)]), startPoint: b.center, endPoint: end),
                           style: StrokeStyle(lineWidth: 1 + 8 * sqrt(c), lineCap: .round))
            }
        }
    }

    /// Hubs: a glow and fill that grow with stress, a stress arc around the rim, icon and name inside, reading below.
    /// Unmeasured hubs are a dashed outline with "—", so they never look like calm ones.
    func drawHubs(_ ctx: inout GraphicsContext, _ g: MapGeometry) {
        let r = g.hubR
        for sub in MapGeometry.order {
            let h = report.hub(sub), pt = g.hub(sub), st = h?.stress
            let col = st.map(p.strain) ?? p.dim
            func circle(_ rr: CGFloat) -> Path { Path(ellipseIn: CGRect(x: pt.x - rr, y: pt.y - rr, width: 2 * rr, height: 2 * rr)) }
            if let st {
                let halo = r * (1.5 + 0.9 * st)
                ctx.fill(circle(halo), with: .radialGradient(Gradient(colors: [col.opacity(0.18 + 0.5 * st), col.opacity(0)]),
                                                             center: pt, startRadius: r * 0.7, endRadius: halo))
            }
            ctx.fill(circle(r), with: .color(p.panel))
            if let st {
                ctx.fill(circle(r), with: .color(col.opacity(0.16 + 0.4 * st)))
                ctx.stroke(circle(r), with: .color(col.opacity(0.85)), lineWidth: 1.2)
                // Stress arc: a meter around the hub, full circle = fully stressed.
                ctx.stroke(circle(r + 4), with: .color(p.meterOff), lineWidth: 3)
                if st > 0.005 {
                    var arc = Path()
                    arc.addArc(center: pt, radius: r + 4, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * st), clockwise: false)
                    ctx.stroke(arc, with: .color(col), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            } else {
                ctx.stroke(circle(r), with: .color(p.dim.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            let ink = st == nil ? p.dim : ((st ?? 0) > 0.25 ? col : p.text)
            ctx.draw(Text(Image(systemName: stressIcon(sub))).font(.system(size: r * 0.42)).foregroundColor(ink), at: CGPoint(x: pt.x, y: pt.y - r * 0.22))
            ctx.draw(Text(sub.rawValue.uppercased()).font(.system(size: max(9, r * 0.27), weight: .bold, design: .monospaced)).foregroundColor(ink),
                     at: CGPoint(x: pt.x, y: pt.y + r * 0.34))
            ctx.draw(Text(h?.reading ?? "—").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(st == nil ? p.dim : p.text),
                     at: CGPoint(x: pt.x, y: pt.y + r + 18))
        }
    }
}

/// One app bubble: coloured by its worst contribution, app icon inside, optional name below. Hung apps are solid red
/// with a dashed outer ring and a stop badge, so they stand out even among red bubbles.
struct MiseryBubble: View {
    @Environment(\.palette) var p
    var m: AppMisery
    var radius: CGFloat
    var showName: Bool
    var highlighted: Bool
    var dimmed: Bool

    var body: some View {
        let col = m.hung ? p.crit : p.strain(m.worst)
        ZStack {
            Circle().fill(RadialGradient(colors: [col.opacity(m.hung ? 0.8 : 0.6), col.opacity(m.hung ? 0.4 : 0.22)],
                                         center: .center, startRadius: 0, endRadius: radius))
            Circle().strokeBorder(col.opacity(0.95), lineWidth: highlighted ? 2.5 : 1.2)
            if m.hung {
                Circle().strokeBorder(p.crit, style: StrokeStyle(lineWidth: 2, dash: [5, 3])).padding(-6)
            }
            if radius >= 13 {
                let s = min(radius * 1.05, 40)
                AppIcon(path: appIconPath(m.app)).frame(width: s, height: s)
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .overlay(alignment: .topTrailing) {
            if m.hung {
                Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 14)).foregroundStyle(.white, p.crit)
                    .background(Circle().fill(p.background)).offset(x: 4, y: -4)
            }
        }
        .shadow(color: col.opacity(highlighted ? 0.9 : 0.5), radius: highlighted ? 12 : 5)
        .overlay(alignment: .bottom) {
            if showName || highlighted {
                // Long daemon names ("spotlightknowledged.updater") would cover neighbouring bubbles; the full name
                // is in the side panel.
                let name = m.app.name.count > 16 ? m.app.name.prefix(15) + "…" : m.app.name
                Text(m.hung ? "\(name) · not responding" : name)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(m.hung ? p.crit : p.text)
                    .lineLimit(1).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(p.background.opacity(0.75)))
                    .fixedSize()
                    .alignmentGuide(.bottom) { $0[.top] - 4 }
            }
        }
        .opacity(dimmed ? 0.35 : 1)
        .contentShape(Circle())
        .help(m.busiest == nil ? m.app.name : "\(m.app.name): click to inspect its busiest process")
    }
}

/// "38%" style percentage from a 0…1 fraction.
private func pct01(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }

/// What the app is actually using of a subsystem, in that subsystem's units (thermal blame has no unit of its own).
private func usage(_ a: AppUsage, _ s: Subsystem) -> String {
    switch s {
    case .cpu: String(format: "%.0f%% CPU", a.cpu)
    case .memory: Fmt.bytes(a.memory)
    case .disk: Fmt.rate(a.diskBps)
    case .network: Fmt.rate(a.netBps)
    case .gpu: a.gpu.map { String(format: "%.0f%% GPU", $0) } ?? "—"
    case .energy: a.energyWatts.map { String(format: "%.1f W", $0) } ?? "—"
    case .thermal: "via CPU/GPU heat"
    }
}

/// Per-subsystem breakdown for the hovered app (or the worst one when nothing is hovered).
struct MiseryDetail: View {
    @Environment(\.palette) var p
    var m: AppMisery?
    var hovering: Bool

    var body: some View {
        Panel(title: hovering ? "Selected app" : "Worst offender", trailing: m.map { "misery " + pct01($0.total) }) {
            if let m {
                HStack(spacing: 10) {
                    AppIcon(path: appIconPath(m.app)).frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.app.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                        Text("\(m.app.processes) process\(m.app.processes == 1 ? "" : "es")").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                    }
                    Spacer()
                }
                if m.hung {
                    Label("Not responding: macOS reports this app hung", systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(p.crit)
                }
                let rows = m.contributions.sorted { $0.value > $1.value }
                if rows.isEmpty {
                    Text("No measurable strain on any subsystem.").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                }
                ForEach(rows, id: \.key) { sub, c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: stressIcon(sub)).font(.system(size: 10)).foregroundStyle(p.strain(c)).frame(width: 14)
                            Text(sub.rawValue.uppercased()).font(.meterLabel).foregroundStyle(p.dim).frame(width: 62, alignment: .leading)
                            Text(usage(m.app, sub)).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.text).lineLimit(1)
                            Spacer()
                            Text(pct01(c)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(p.strain(c))
                        }
                        HStack(spacing: 6) {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(p.meterOff)
                                    Capsule().fill(p.strain(c)).frame(width: max(3, g.size.width * c))
                                }
                            }
                            .frame(height: 4)
                            Text("\(pct01(m.shares[sub] ?? 0)) of use").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(p.dim)
                                .frame(width: 74, alignment: .trailing)
                        }
                        .padding(.leading, 20)
                    }
                }
                if let b = m.busiest, b.pid > 0 {   // kernel_task (PID 0) has no inspector, as in Processes
                    Text("Click its bubble to inspect PID \(b.pid)").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                }
            } else {
                Label("Nothing is straining this Mac right now.", systemImage: "checkmark.seal")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(p.text)
            }
        }
    }
}

/// The five most miserable apps with the subsystem each hurts most. Hovering a row highlights its bubble; clicking
/// inspects it, like the bubble.
struct TopCausers: View {
    @Environment(\.palette) var p
    var apps: [AppMisery]
    @Binding var hovered: String?

    var body: some View {
        Panel(title: "Top misery causers") {
            if apps.isEmpty {
                Text("None. All quiet.").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
            }
            ForEach(Array(apps.prefix(5).enumerated()), id: \.element.id) { i, m in
                let col = m.hung ? p.crit : p.strain(m.worst)
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(p.dim).frame(width: 12)
                    AppIcon(path: appIconPath(m.app)).frame(width: 16, height: 16)
                    Text(m.app.name).font(.system(size: 12)).foregroundStyle(p.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(m.hung ? "HUNG" : (m.main?.rawValue.uppercased() ?? "—"))
                        .font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(col)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(col.opacity(0.15)))
                        .overlay(Capsule().strokeBorder(col.opacity(0.5)))
                    Text(pct01(m.total)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(col)
                        .frame(width: 38, alignment: .trailing)
                }
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovered == m.id ? p.accent.opacity(0.12) : .clear))
                .contentShape(Rectangle())
                .onHover { inside in if inside { hovered = m.id } else if hovered == m.id { hovered = nil } }
                .onTapGesture { if let id = m.busiest, id.pid > 0 { AppActions.openInspector?(id) } }
            }
        }
    }
}

/// How to read the map, including the scoring rule in one sentence.
struct StressLegend: View {
    @Environment(\.palette) var p

    func row<Icon: View>(_ text: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 10) {
            icon().frame(width: 54, height: 18)
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.text)
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        Panel(title: "Legend") {
            row("Hub: how strained that part is") {
                HStack(spacing: 4) { ForEach([0.1, 0.45, 0.9], id: \.self) { Circle().fill(p.strain($0).opacity(0.6)).overlay(Circle().strokeBorder(p.strain($0))).frame(width: 13) } }
            }
            row("Bubble area: an app's misery") {
                HStack(spacing: 4) { ForEach([7.0, 11, 16], id: \.self) { Circle().fill(p.accent.opacity(0.35)).overlay(Circle().strokeBorder(p.accent)).frame(width: $0) } }
            }
            row("Route width: what it adds there") {
                VStack(spacing: 4) { Capsule().fill(p.accent.opacity(0.4)).frame(height: 1.5); Capsule().fill(p.warn.opacity(0.8)).frame(height: 5) }
            }
            row("Dashed red ring: not responding") {
                Circle().strokeBorder(p.crit, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 16)
            }
            row("Dashed hub, \"—\": not measured") {
                Circle().strokeBorder(p.dim, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 16)
            }
            Text("Misery = the app's share of a resource × how strained that resource is. Unmeasured readings blame nobody.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}
