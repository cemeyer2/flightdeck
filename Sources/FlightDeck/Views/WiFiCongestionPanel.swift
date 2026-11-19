// Wi-Fi page: channel congestion per band from the last scan, the channel recommendation, and a UniFi console's own
// radio utilization (measured airtime at the access point, which beats anything this Mac can infer from a scan).
import SwiftUI
import FlightDeckCore

struct WiFiCongestionPanel: View {
    @Environment(\.palette) var p
    var scan: WiFiScanResult
    var own: Set<Int>
    var recommendation: WiFiRecommendation?
    var ownBand: WiFiBand?

    var body: some View {
        Panel(title: "Channel congestion", trailing: "from this Mac's position only") {
            if let r = recommendation {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: r.suggestion == nil ? "checkmark.circle" : "lightbulb").foregroundStyle(r.suggestion == nil ? p.accent : p.warn)
                    Text(r.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.text).lineLimit(5)
                }
            }
            // Bands with networks, plus your own band even if it's the only network there.
            let bands = WiFiBand.allCases.filter { b in b == ownBand || scan.networks.contains { $0.band == b } }
            ForEach(bands, id: \.self) { b in
                ChannelLoadChart(band: b, loads: WiFiCongestion.loads(scan, band: b, own: own),
                                 count: scan.networks.filter { $0.band == b }.count, current: b == ownBand ? recommendation?.channel : nil,
                                 suggested: b == ownBand ? recommendation?.suggestion : nil)
            }
            Text("Each bar is the networks this Mac hears on that 20 MHz channel, weighted by signal (−55 dBm or louder counts fully, fading to nothing at −90 dBm). Wide networks count on every channel they cover; 2.4 GHz networks also spill onto neighbouring channels. A scan sees networks, not how busy they are.")
                .font(.caption).foregroundStyle(p.dim).lineLimit(4)
        }
    }
}

/// Bars per 20 MHz channel: neighbours' load, with your own network's part highlighted on top.
struct ChannelLoadChart: View {
    @Environment(\.palette) var p
    var band: WiFiBand
    var loads: [WiFiChannelLoad]
    var count: Int
    var current: Int?
    var suggested: Int?

    var body: some View {
        let top = max(2, (loads.map(\.score).max() ?? 0) * 1.1)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(band.rawValue).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(p.text)
                Text("\(count) network\(count == 1 ? "" : "s")").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                Spacer()
                legend("neighbours", p.accent2); legend("your network", p.accent)
                if band == .ghz5 { legend("DFS (radar) channels", p.dim.opacity(0.3)) }
            }
            Canvas { ctx, size in
                let n = CGFloat(max(loads.count, 1)), slot = size.width / n, barH = size.height - 14
                for (i, l) in loads.enumerated() {
                    let x = CGFloat(i) * slot
                    if WiFiChannels.isDFS(band, l.channel) {
                        ctx.fill(Path(CGRect(x: x, y: 0, width: slot, height: barH)), with: .color(p.dim.opacity(0.08)))
                    }
                    let other = l.score - l.ownScore
                    let hOther = CGFloat(other / top) * barH, hOwn = CGFloat(l.ownScore / top) * barH
                    let w = max(slot - 2, 1)
                    ctx.fill(Path(roundedRect: CGRect(x: x + 1, y: barH - hOther, width: w, height: hOther), cornerRadius: 1.5), with: .color(p.accent2.opacity(0.85)))
                    ctx.fill(Path(roundedRect: CGRect(x: x + 1, y: barH - hOther - hOwn, width: w, height: hOwn), cornerRadius: 1.5), with: .color(p.accent))
                    // Your current primary channel and the suggested one get a marker under the axis.
                    if l.channel == current || l.channel == suggested {
                        let c = l.channel == current ? p.accent : p.warn
                        ctx.fill(Path(CGRect(x: x + 1, y: barH + 1, width: w, height: 2)), with: .color(c))
                    }
                    // Label every channel on 2.4/5 GHz; every other one on 6 GHz (59 channels).
                    if band != .ghz6 || i % 2 == 0 {
                        ctx.draw(Text("\(l.channel)").font(.system(size: 8, design: .monospaced)).foregroundColor(l.channel == current ? p.accent : p.dim),
                                 at: CGPoint(x: x + slot / 2, y: barH + 4), anchor: .top)
                    }
                }
                ctx.stroke(Path { $0.move(to: .init(x: 0, y: barH)); $0.addLine(to: .init(x: size.width, y: barH)) }, with: .color(p.grid), lineWidth: 1)
            }
            .frame(height: 96)
        }
    }

    func legend(_ s: String, _ c: Color) -> some View {
        HStack(spacing: 3) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9); Text(s).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim) }
    }
}

/// UniFi access-point radios, flattened for the page.
struct WiFiUniFiRadio: Identifiable, Hashable {
    var id: String { ap + "|" + (radio.band ?? "?") + "|\(index)" }
    var ap: String
    var index: Int
    var radio: UniFiRadio
}

enum WiFiUniFiRadios {
    static func list(_ s: UniFiSnapshot?) -> [WiFiUniFiRadio] {
        guard let s else { return [] }
        return s.devices.filter { $0.kind == .accessPoint }.flatMap { d in
            d.radios.enumerated().map { WiFiUniFiRadio(ap: d.displayName, index: $0.offset, radio: $0.element) }
        }
    }

    /// Utilization of the radio this Mac is probably on: the only AP radio on the link's band and channel. With
    /// several on the same channel, which one is this Mac's can't be known from here, so nil.
    static func utilization(_ radios: [WiFiUniFiRadio], band: WiFiBand?, channel: Int?) -> Double? {
        guard let band, let channel else { return nil }
        let m = radios.filter { WiFiBand(label: $0.radio.band) == band && $0.radio.channel == channel }
        return m.count == 1 ? m[0].radio.utilizationPercent : nil
    }
}

struct WiFiUniFiPanel: View {
    @Environment(\.palette) var p
    var radios: [WiFiUniFiRadio]
    var demo: Bool

    func cell(_ s: String, _ w: CGFloat, dim: Bool = false) -> some View {
        Text(s).foregroundStyle(dim ? p.dim : p.text).frame(width: w, alignment: .leading).lineLimit(1)
    }

    var body: some View {
        Panel(title: "Access point radios (UniFi)", trailing: demo ? "demo network" : "as measured by the access points") {
            HStack(spacing: 8) {
                cell("ACCESS POINT", 200, dim: true); cell("BAND", 70, dim: true); cell("CHANNEL", 70, dim: true); cell("WIDTH", 70, dim: true)
                cell("UTILIZATION", 220, dim: true); cell("CLIENTS", 70, dim: true); cell("TX POWER", 80, dim: true)
            }.font(.meterLabel)
            ForEach(radios) { r in
                HStack(spacing: 8) {
                    cell(r.ap, 200); cell(r.radio.band ?? "unknown", 70, dim: r.radio.band == nil)
                    cell(r.radio.channel.map(String.init) ?? "unknown", 70, dim: r.radio.channel == nil)
                    cell(r.radio.widthMHz.map { "\($0) MHz" } ?? "unknown", 70, dim: r.radio.widthMHz == nil)
                    HStack(spacing: 6) {
                        VFDMeter(fraction: r.radio.utilizationPercent.map { $0 / 100 }, segments: 16, height: 8).frame(width: 140)
                        Text(r.radio.utilizationPercent.map { String(format: "%.0f%%", $0) } ?? "not reported").foregroundStyle(r.radio.utilizationPercent == nil ? p.dim : p.text)
                    }.frame(width: 220, alignment: .leading)
                    cell(r.radio.clientCount.map(String.init) ?? "unknown", 70, dim: r.radio.clientCount == nil)
                    cell(r.radio.txPowerDbm.map { "\($0) dBm" } ?? "unknown", 80, dim: r.radio.txPowerDbm == nil)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            Text("Utilization is the share of time each radio found its channel busy, measured at the access point: a better guide to congestion than this Mac's scan. Above about 50% the channel is crowded.")
                .font(.caption).foregroundStyle(p.dim).lineLimit(3)
        }
    }
}
