// Internet page panels: the Wi-Fi link and latency probe right now, and the speed-test history charts (one point per
// test, placed by time, so irregular manual tests and the schedule's runs read correctly).
import SwiftUI
import FlightDeckCore

/// The link as it is now (Wi-Fi from CoreWLAN, latency from the opt-in probe), to set against the last test.
struct LinkNowPanel: View {
    @Environment(\.palette) var p
    var snapshot: Snapshot?
    var demo = false

    func row(_ k: String, _ v: String?, why: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k).foregroundStyle(p.dim).frame(width: 92, alignment: .leading)
            Text(v ?? why).foregroundStyle(v == nil ? p.dim : p.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.font(.system(size: 11, design: .monospaced))
    }

    /// "3.1 ms · ±0.4 · 0% loss"; nil when that target has no result.
    func ping(_ r: LatencyResult?) -> String? {
        guard let r else { return nil }
        return (r.avgMs.map { String(format: "%.1f ms", $0) } ?? "no reply") + String(format: " · ±%.1f · %.0f%% loss", r.jitterMs ?? 0, r.loss)
    }

    var body: some View {
        // Demo mode shows the invented link the demo tests were "run" on, never this Mac's.
        let w = snapshot?.wifi
        let lat = snapshot?.latency
        let router = lat?.first { $0.role == "Router" }, net = lat?.first { $0.role == "Internet" }
        return Panel(title: "Link now", trailing: demo ? "demo" : nil) {
            if demo {
                row("Wi-Fi", "−58 dBm (Excellent) · 1201 Mbps link · 5 GHz", why: "")
                row("Router", "3.1 ms · ±0.4 · 0% loss", why: "")
                row("Internet", "17.0 ms · ±1.2 · 0% loss (1.1.1.1)", why: "")
            } else {
                row("Wi-Fi", w.map { "\($0.rssi) dBm (\($0.quality)) · \(Int($0.txRate)) Mbps link" + ($0.band.map { " · \($0)" } ?? "") },
                    why: "not on Wi-Fi (off, not associated, or wired)")
                if let phy = w?.phy { row("Standard", phy, why: "") }
                row("Router", ping(router), why: "latency probe off (Settings › Network)")
                row("Internet", ping(net).map { $0 + " (\(net!.host))" }, why: "latency probe off (Settings › Network)")
            }
            Text("The Wi-Fi link rate is the radio's raw rate; real throughput tops out around half to two-thirds of it. A slow router ping points at the local network, a slow internet ping with a fast router at the provider.")
                .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 360)
    }
}

/// Download, upload and responsiveness over the selected range, plus the most recent tests as a table.
struct SpeedHistoryPanel: View {
    @Environment(\.palette) var p
    var results: [SpeedTestResult]
    @Binding var days: Int

    var body: some View {
        let now = Date(), from = now.addingTimeInterval(-Double(days) * 86_400)
        Panel(title: "Test history", trailing: "\(results.count) test\(results.count == 1 ? "" : "s") in \(days) days") {
            Picker("", selection: $days) { Text("7 days").tag(7); Text("30 days").tag(30) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            if results.isEmpty {
                // One message rather than three empty plots.
                Text("No tests in the last \(days) days. Run one above, or turn on scheduled tests in Settings › Network.")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            } else { charts(from: from, to: now) }
            if !results.isEmpty {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 2) {
                    GridRow { Text("WHEN").gridColumnAlignment(.leading); Text("DOWN"); Text("UP"); Text("RPM"); Text("") }
                        .font(.meterLabel).foregroundStyle(p.dim)
                    ForEach(results.suffix(6).reversed()) { r in
                        GridRow {
                            Text(r.time.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            Text(r.downloadMbps.map { String(format: "%.0f", $0) } ?? "—")
                            Text(r.uploadMbps.map { String(format: "%.0f", $0) } ?? "—")
                            Text(r.responsivenessRPM.map { String(format: "%.0f", $0) } ?? "—")
                            Text(r.scheduled ? "scheduled" : "manual").foregroundStyle(p.dim)
                        }
                    }
                }.font(.system(size: 11, design: .monospaced))
            }
        }
    }

    @ViewBuilder func charts(from: Date, to now: Date) -> some View {
        chart("Download, Mbps", results.compactMap { r in r.downloadMbps.map { (r.time, $0) } }, from: from, to: now, color: p.accent)
        chart("Upload, Mbps", results.compactMap { r in r.uploadMbps.map { (r.time, $0) } }, from: from, to: now, color: p.accent2)
        // Dashed guides at the Low/Medium (200) and Medium/High (800) boundaries.
        chart("Responsiveness, RPM", results.compactMap { r in r.responsivenessRPM.map { (r.time, $0) } }, from: from, to: now,
              color: p.accent, guides: [200, 800])
    }

    func chart(_ title: String, _ pts: [(Date, Double)], from: Date, to: Date, color: Color, guides: [Double] = []) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.meterLabel).foregroundStyle(p.dim)
            TimePointChart(points: pts, from: from, to: to, color: color, guides: guides).frame(height: 70)
        }
    }
}

/// Points at their times across [from, to], joined by a line when consecutive tests are under a day apart (a longer
/// gap is left open rather than implying what happened in between).
struct TimePointChart: View {
    @Environment(\.palette) var p
    var points: [(Date, Double)]
    var from: Date
    var to: Date
    var color: Color
    var guides: [Double] = []

    var body: some View {
        let top = HistoryGraph(traces: []).niceCeil(max((points.map(\.1).max() ?? 0) * 1.15, 1))
        Canvas { ctx, size in
            let span = max(to.timeIntervalSince(from), 1)
            func pt(_ d: Date, _ v: Double) -> CGPoint {
                CGPoint(x: CGFloat(d.timeIntervalSince(from) / span) * size.width, y: size.height - CGFloat(min(v / top, 1)) * size.height)
            }
            for g in guides where g < top {
                let y = size.height - CGFloat(g / top) * size.height
                ctx.stroke(Path { $0.move(to: .init(x: 0, y: y)); $0.addLine(to: .init(x: size.width, y: y)) },
                           with: .color(p.dim.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            for (a, b) in zip(points, points.dropFirst()) where b.0.timeIntervalSince(a.0) < 86_400 {
                ctx.stroke(Path { $0.move(to: pt(a.0, a.1)); $0.addLine(to: pt(b.0, b.1)) }, with: .color(color.opacity(0.6)), lineWidth: 1.5)
            }
            for (d, v) in points {
                let c = pt(d, v)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(color))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(p.background.opacity(0.6)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { if points.isEmpty { Text("no tests in this range").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim) } }
        .overlay(alignment: .topLeading) { Text(String(format: "%.0f", top)).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim).padding(4) }
    }
}
