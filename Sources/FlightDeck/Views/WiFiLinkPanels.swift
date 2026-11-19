// Wi-Fi page panels about this Mac's own link: health ratings with the reasons a rate may be low, the link history
// graph with roam and band-change markers, and the walk-test readout.
import SwiftUI
import FlightDeckCore

/// Signal, SNR, interference and width rated in plain English, then the link-rate explanation.
struct WiFiHealthPanel: View {
    @Environment(\.palette) var p
    var link: WiFiLinkNow?
    var recommendation: WiFiRecommendation?
    var utilization: Double?

    var body: some View {
        Panel(title: "Your connection", trailing: link.map { l in [l.ssid ?? "name hidden", l.point.band?.rawValue, l.point.channel.map { "ch \($0)" }].compactMap { $0 }.joined(separator: " · ") }) {
            if let link {
                let r = WiFiHealth.assess(link.point, phy: link.phy, recommendation: recommendation, utilization: utilization)
                HStack(spacing: 22) {
                    Readout(label: "RSSI", value: "\(link.point.rssi)", unit: "dBm", color: WiFiHealth.signal(link.point.rssi).color(p))
                    Readout(label: "Noise", value: "\(link.point.noise)", unit: "dBm")
                    Readout(label: "SNR", value: "\(link.point.snr)", unit: "dB", color: WiFiHealth.snr(link.point.snr).color(p))
                    Readout(label: "Link rate", value: String(format: "%.0f", link.point.txRate), unit: "Mbps")
                    Spacer(minLength: 0)
                }
                Text([link.phy, link.point.widthMHz.map { "\($0) MHz" }, link.security, link.point.bssid.map { "BSSID \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim).textSelection(.enabled)
                Divider()
                // Rating line, then its explanation underneath (a side column was too narrow to read).
                ForEach(r.items) { i in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: i.rating.icon).foregroundStyle(i.rating.color(p)).frame(width: 14)
                            Text(i.aspect).foregroundStyle(p.text).frame(width: 120, alignment: .leading)
                            Text(i.rating.rawValue).foregroundStyle(i.rating.color(p)).frame(width: 74, alignment: .leading)
                            Text(i.value).foregroundStyle(p.text)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        Text(i.detail).font(.caption).foregroundStyle(p.dim).lineLimit(3).padding(.leading, 22)
                    }
                }
                Divider()
                Text(r.rateSummary).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.text).lineLimit(4)
                ForEach(r.rateReasons, id: \.self) { reason in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(p.dim)
                        Text(reason).foregroundStyle(p.text).lineLimit(4)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            } else {
                Text("Not connected to Wi-Fi (or Wi-Fi is off).").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
            }
        }
        .frame(width: 520)
    }
}

/// RSSI and noise, SNR, and link rate since the page opened, with roams and band changes marked.
struct WiFiLinkHistoryPanel: View {
    @Environment(\.palette) var p
    var history: WiFiLinkHistory

    var body: some View {
        let pts = history.points
        let events = history.events
        let start = pts.first?.time ?? Date(), end = pts.last?.time ?? Date()
        let marks = events.filter { $0.kind != .reconnected }.map(\.time)
        Panel(title: "Link over time", trailing: pts.isEmpty ? nil : "\(Fmt.duration(end.timeIntervalSince(start))) · while this page is open") {
            if pts.count < 2 {
                Text("Collecting readings (the Wi-Fi link is re-read every 5 seconds)…").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
            } else {
                WiFiTimeGraph(title: "Signal and noise (dBm)", series: [("RSSI", p.accent, pts.map { ($0.time, Double($0.rssi)) }),
                                                                       ("Noise", p.accent2, pts.map { ($0.time, Double($0.noise)) })],
                              range: -100 ... -20, start: start, end: end, marks: marks)
                WiFiTimeGraph(title: "SNR (dB)", series: [("SNR", p.accent, pts.map { ($0.time, Double($0.snr)) })],
                              range: 0...70, start: start, end: end, marks: marks)
                WiFiTimeGraph(title: "Link rate (Mbps)", series: [("TX", p.accent, pts.map { ($0.time, $0.txRate) })],
                              range: 0...max(100, (pts.map(\.txRate).max() ?? 0) * 1.15), start: start, end: end, marks: marks)
                if events.isEmpty {
                    Text("No roams or band changes so far.").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                } else {
                    ForEach(events.suffix(8)) { ev in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: ev.kind == .roam ? "arrow.left.arrow.right" : ev.kind == .disconnected ? "wifi.slash" : "dot.radiowaves.right")
                                .foregroundStyle(p.warn).frame(width: 14)
                            Text(ev.time.formatted(date: .omitted, time: .standard)).foregroundStyle(p.dim)
                            Text(ev.text).foregroundStyle(p.text).lineLimit(2)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }
}

/// A small time-axis line graph for the link history. Values are clamped to `range`; gaps of more than 20 s between
/// readings (page closed, link dropped) break the line. `marks` are drawn as dashed verticals (roams, band changes).
struct WiFiTimeGraph: View {
    @Environment(\.palette) var p
    var title: String
    var series: [(String, Color, [(Date, Double)])]
    var range: ClosedRange<Double>
    var start: Date, end: Date
    var marks: [Date]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(title.uppercased()).font(.meterLabel).foregroundStyle(p.dim)
                ForEach(series.indices, id: \.self) { i in
                    HStack(spacing: 3) {
                        Circle().fill(series[i].1).frame(width: 6, height: 6)
                        Text(series[i].0 + (series[i].2.last.map { String(format: " %.0f", $0.1) } ?? "")).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.text)
                    }
                }
                Spacer(minLength: 0)
            }
            Canvas { ctx, size in
                let span = max(end.timeIntervalSince(start), 1)
                func x(_ t: Date) -> CGFloat { CGFloat(t.timeIntervalSince(start) / span) * size.width }
                func y(_ v: Double) -> CGFloat { size.height - CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)) * size.height }
                for i in 1..<4 {
                    let gy = size.height * CGFloat(i) / 4
                    ctx.stroke(Path { $0.move(to: .init(x: 0, y: gy)); $0.addLine(to: .init(x: size.width, y: gy)) }, with: .color(p.grid), lineWidth: 1)
                }
                for m in marks {
                    ctx.stroke(Path { $0.move(to: .init(x: x(m), y: 0)); $0.addLine(to: .init(x: x(m), y: size.height)) },
                               with: .color(p.warn.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                for (_, color, pts) in series {
                    var path = Path(); var prev: Date?
                    for (t, v) in pts {
                        let pt = CGPoint(x: x(t), y: y(v))
                        if let pr = prev, t.timeIntervalSince(pr) <= 20 { path.addLine(to: pt) } else { path.move(to: pt) }
                        prev = t
                    }
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                for (v, yy) in [(range.upperBound, 1.0), (range.lowerBound, size.height - 11)] {
                    ctx.draw(Text(String(format: "%.0f", v)).font(.system(size: 9, design: .monospaced)).foregroundColor(p.dim), at: CGPoint(x: 2, y: yy), anchor: .topLeading)
                }
            }
            .frame(height: 70)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.background.opacity(0.6)))
        }
    }
}

/// Walk test: one huge RSSI number with a quality bar, readable from across the room while walking around.
struct WalkTestPanel: View {
    @Environment(\.palette) var p
    var point: WiFiLinkPoint?

    var body: some View {
        Panel(title: "Walk test", trailing: "updates every 5 s (as often as macOS refreshes the reading)") {
            if let pt = point {
                let rating = WiFiHealth.signal(pt.rssi)
                HStack(alignment: .center, spacing: 30) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(pt.rssi)").font(.system(size: 96, weight: .medium, design: .monospaced)).foregroundStyle(rating.color(p))
                        Text("dBm · \(rating.rawValue.uppercased())").font(.system(size: 18, weight: .semibold, design: .monospaced)).foregroundStyle(rating.color(p))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        // −90 dBm (unusable) to −40 dBm (right next to the access point).
                        VFDMeter(fraction: min(1, max(0, Double(pt.rssi + 90) / 50)), segments: 30, height: 26)
                        Text("SNR \(pt.snr) dB · \(String(format: "%.0f", pt.txRate)) Mbps" + (pt.channel.map { " · \(pt.band?.rawValue ?? "") channel \($0)" } ?? ""))
                            .font(.system(size: 14, design: .monospaced)).foregroundStyle(p.text)
                        Text("Walk slowly and pause a few seconds in each spot. Around −67 dBm or better is fine for calls and video; below −75 dBm is a dead spot.")
                            .font(.caption).foregroundStyle(p.dim).lineLimit(3)
                    }
                }
            } else {
                Text("Not connected to Wi-Fi.").font(.system(size: 14, design: .monospaced)).foregroundStyle(p.dim)
            }
        }
    }
}
