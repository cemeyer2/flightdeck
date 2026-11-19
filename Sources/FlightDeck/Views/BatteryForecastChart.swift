// The battery health chart: daily health readings (FlightDeck's own as a line, days seeded from macOS's power log as
// hollow dots), the Theil–Sen trend through them, and past the last reading the projection with its 95% band, against
// the 80% service threshold. One data hue (accent); the band is the same hue, translucent; the threshold is recessive
// and dashed. Hovering reads out the nearest day. Drawn with Canvas like DayChart and HistoryGraph.
import SwiftUI
import FlightDeckCore

struct BatteryForecastChart: View {
    @Environment(\.palette) var p
    var forecast: BatteryForecast
    var history: [BatteryDay]
    @State private var hoverX: CGFloat?

    /// Time domain: the history, extended to where the band's late edge (or the trend) reaches 80%, at most 3 years on
    /// and at least a quarter of the history's span, so the projection is visible without dwarfing the data.
    var domain: (start: Date, end: Date) {
        let start = history.first?.start ?? Date(), last = history.last?.start ?? start
        guard forecast.status == .forecast, forecast.line != nil else { return (start, max(last, start.addingTimeInterval(86_400))) }
        let span = last.timeIntervalSince(start)
        let target = forecast.date80Late ?? forecast.date80 ?? last.addingTimeInterval(3 * 365 * 86_400)
        let end = min(max(target.addingTimeInterval(30 * 86_400), last.addingTimeInterval(span / 4)), last.addingTimeInterval(3 * 365 * 86_400))
        return (start, end)
    }

    /// Health scale: always shows 80% and 100%, plus whatever the readings and the band's visible part need.
    var range: (low: Double, high: Double) {
        let hs = history.compactMap(\.health)
        var lo = min(hs.min() ?? 80, 80) - 2, hi = max(hs.max() ?? 100, 100) + 1
        if let b = forecast.band(at: domain.end) { lo = min(lo, max(b.low, 60)) - 1; hi = max(hi, min(b.high, 110)) }
        return (lo, hi)
    }

    var body: some View {
        let d = domain, r = range
        let lastDate = history.last?.start ?? d.end
        VStack(alignment: .leading, spacing: 2) {
            Text(readout(d)).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1)
            Canvas { ctx, size in
                let span = max(d.end.timeIntervalSince(d.start), 86_400)
                func x(_ t: Date) -> CGFloat { CGFloat(t.timeIntervalSince(d.start) / span) * size.width }
                func y(_ h: Double) -> CGFloat { size.height - CGFloat((h - r.low) / (r.high - r.low)) * size.height }
                // Grid: every 5 points, labelled at 80/90/100.
                var g = (r.low / 5).rounded(.up) * 5
                while g <= r.high {
                    var line = Path(); line.move(to: CGPoint(x: 0, y: y(g))); line.addLine(to: CGPoint(x: size.width, y: y(g)))
                    ctx.stroke(line, with: .color(p.grid), lineWidth: 1)
                    if Int(g) % 10 == 0 { ctx.draw(Text("\(Int(g))%").font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim), at: CGPoint(x: 2, y: y(g) - 6), anchor: .leading) }
                    g += 5
                }
                // The 80% service threshold.
                var th = Path(); th.move(to: CGPoint(x: 0, y: y(80))); th.addLine(to: CGPoint(x: size.width, y: y(80)))
                ctx.stroke(th, with: .color(p.warn.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                // Projection band and trend, from the last reading on.
                if forecast.line != nil, forecast.status == .forecast || forecast.status == .belowThreshold {
                    let steps = 60
                    let times = (0...steps).map { lastDate.addingTimeInterval(d.end.timeIntervalSince(lastDate) * Double($0) / Double(steps)) }
                    let pts = times.compactMap { t in forecast.band(at: t).map { (t, $0) } }
                    var band = Path()
                    for (i, (t, b)) in pts.enumerated() { let pt = CGPoint(x: x(t), y: y(b.high)); if i == 0 { band.move(to: pt) } else { band.addLine(to: pt) } }
                    for (t, b) in pts.reversed() { band.addLine(to: CGPoint(x: x(t), y: y(b.low))) }
                    band.closeSubpath()
                    ctx.fill(band, with: .color(p.accent.opacity(0.18)))
                    var trend = Path()
                    for (i, (t, b)) in pts.enumerated() { let pt = CGPoint(x: x(t), y: y(b.mid)); if i == 0 { trend.move(to: pt) } else { trend.addLine(to: pt) } }
                    ctx.stroke(trend, with: .color(p.accent), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
                // The fitted trend over the history itself (thin), so the reader sees what the projection continues.
                if let first = history.first?.start, forecast.line != nil, let a = forecast.band(at: first), let b = forecast.band(at: lastDate) {
                    var fit = Path(); fit.move(to: CGPoint(x: x(first), y: y(a.mid))); fit.addLine(to: CGPoint(x: x(lastDate), y: y(b.mid)))
                    ctx.stroke(fit, with: .color(p.accent.opacity(0.5)), lineWidth: 1)
                }
                // History: FlightDeck's days as a 2 px line, broken across gaps of more than 3 days (no interpolation).
                var line = Path(); var prev: Date?
                for day in history where day.source != .macOS {
                    guard let h = day.health else { continue }
                    let pt = CGPoint(x: x(day.start), y: y(h))
                    if let pv = prev, day.start.timeIntervalSince(pv) <= 3 * 86_400 { line.addLine(to: pt) } else { line.move(to: pt) }
                    prev = day.start
                }
                ctx.stroke(line, with: .color(p.text.opacity(0.85)), lineWidth: 2)
                for day in history where day.source == .macOS {
                    guard let h = day.health else { continue }
                    let c = CGRect(x: x(day.start) - 3, y: y(h) - 3, width: 6, height: 6)
                    ctx.stroke(Path(ellipseIn: c), with: .color(p.text.opacity(0.85)), lineWidth: 1.5)
                }
                if let hx = hoverX {
                    var cross = Path(); cross.move(to: CGPoint(x: hx, y: 0)); cross.addLine(to: CGPoint(x: hx, y: size.height))
                    ctx.stroke(cross, with: .color(p.dim), lineWidth: 1)
                }
            }
            .frame(height: 150)
            .background(GeometryReader { geo in
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    if case let .active(pt) = phase { hoverX = pt.x; width = geo.size.width } else { hoverX = nil }
                }
            })
            HStack {
                Text(d.start.formatted(date: .abbreviated, time: .omitted))
                Spacer()
                if d.end > lastDate.addingTimeInterval(86_400) { Text("last reading " + lastDate.formatted(date: .abbreviated, time: .omitted)); Spacer() }
                Text(d.end.formatted(date: .abbreviated, time: .omitted))
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim)
        }
    }

    @State private var width: CGFloat = 1

    /// The hovered day's reading and the trend there; without hover, how to read the chart.
    func readout(_ d: (start: Date, end: Date)) -> String {
        guard let hx = hoverX else { return "Hover for a day's reading · dashed: trend, shaded: 95% range · dashed line: 80%" }
        let t = d.start.addingTimeInterval(Double(hx / max(width, 1)) * d.end.timeIntervalSince(d.start))
        var parts = [t.formatted(date: .abbreviated, time: .omitted)]
        if let near = history.min(by: { abs($0.start.timeIntervalSince(t)) < abs($1.start.timeIntervalSince(t)) }),
           abs(near.start.timeIntervalSince(t)) < 2 * 86_400, let h = near.health {
            parts.append(String(format: "health %.1f%%", h) + (near.cycles.map { ", \($0) cycles" } ?? "") + (near.source == .macOS ? " (macOS power log)" : ""))
        }
        if let b = forecast.band(at: t), forecast.line != nil { parts.append(String(format: "trend %.1f%% (%.1f–%.1f)", b.mid, b.low, b.high)) }
        return parts.joined(separator: " · ")
    }
}
