// Wi-Fi page: every network heard in the last scan as a sortable table. Unknowns say why (hidden by macOS without
// Location permission, a network that hides its name, a BSSID with no registered vendor).
import SwiftUI
import FlightDeckCore

struct WiFiNetworksPanel: View {
    @Environment(\.palette) var p
    var scan: WiFiScanResult
    var own: Set<Int>
    @State private var sort: Column = .signal

    enum Column: String, CaseIterable { case name = "Network", signal = "Signal", channel = "Channel", band = "Band" }

    /// Strongest first by default; other columns sort ascending, with signal breaking ties.
    var rows: [WiFiNetwork] {
        scan.networks.sorted { a, b in
            switch sort {
            case .signal: return a.rssi > b.rssi
            case .name: return (a.ssid ?? "\u{FFFF}", -a.rssi) < (b.ssid ?? "\u{FFFF}", -b.rssi)
            case .channel: return (a.channel ?? 999, -a.rssi) < (b.channel ?? 999, -b.rssi)
            case .band: return (a.band.map { WiFiBand.allCases.firstIndex(of: $0) ?? 9 } ?? 9, -a.rssi) < (b.band.map { WiFiBand.allCases.firstIndex(of: $0) ?? 9 } ?? 9, -b.rssi)
            }
        }
    }

    func cell(_ s: String, _ w: CGFloat, dim: Bool = false, bold: Bool = false) -> some View {
        Text(s).fontWeight(bold ? .semibold : .regular).foregroundStyle(dim ? p.dim : p.text).frame(width: w, alignment: .leading).lineLimit(1)
    }

    func header(_ c: Column, _ w: CGFloat) -> some View {
        Button { sort = c } label: {
            Text(c.rawValue.uppercased() + (sort == c ? " ▾" : "")).font(.meterLabel).foregroundStyle(sort == c ? p.text : p.dim)
                .frame(width: w, alignment: .leading)
        }.buttonStyle(.plain)
    }

    var body: some View {
        Panel(title: "Networks heard", trailing: "\(scan.networks.count) · \(scan.time.formatted(date: .omitted, time: .standard))") {
            HStack(spacing: 8) {
                header(.name, 170); cell("BSSID", 124, dim: true); cell("VENDOR", 100, dim: true); header(.signal, 84)
                cell("NOISE", 44, dim: true); header(.band, 58); header(.channel, 64); cell("WIDTH", 60, dim: true)
                cell("SECURITY", 100, dim: true); cell("STANDARD", 128, dim: true)
            }
            .font(.meterLabel)
            ForEach(rows) { n in
                let mine = own.contains(n.id)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        if mine { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(p.accent) }
                        Text(name(n)).foregroundStyle(n.ssid == nil ? p.dim : (mine ? p.accent : p.text)).fontWeight(mine ? .semibold : .regular).lineLimit(1)
                    }.frame(width: 170, alignment: .leading)
                    cell(n.bssid ?? "hidden", 124, dim: n.bssid == nil)
                    cell(vendor(n), 100, dim: n.vendor.name == nil)
                    HStack(spacing: 4) {
                        Circle().fill(WiFiHealth.signal(n.rssi).color(p)).frame(width: 6, height: 6)
                        Text("\(n.rssi) dBm").foregroundStyle(p.text)
                    }.frame(width: 84, alignment: .leading)
                    cell(n.noise.map { "\($0)" } ?? "—", 44, dim: n.noise == nil)
                    cell(n.band?.rawValue ?? "unknown", 58, dim: n.band == nil)
                    cell(channel(n), 64, dim: n.channel == nil)
                    cell(n.widthMHz.map { "\($0) MHz" } ?? "unknown", 60, dim: n.widthMHz == nil)
                    cell(n.security ?? "unknown", 100, dim: n.security == nil)
                    cell(n.phy ?? "unknown", 128, dim: n.phy == nil)
                }
                .font(.system(size: 11, design: .monospaced))
                .help(n.vendor.label)
            }
            Text("★ your network (the access point this Mac is on, and others broadcasting the same name). Vendor comes from the BSSID's manufacturer prefix; many access points use private (randomized) BSSIDs for extra networks, which have none.")
                .font(.caption).foregroundStyle(p.dim).lineLimit(3)
        }
    }

    func name(_ n: WiFiNetwork) -> String {
        if let s = n.ssid { return s }
        return scan.identifiersHidden ? "hidden by macOS" : "hidden network"
    }

    func vendor(_ n: WiFiNetwork) -> String {
        switch n.vendor {
        case .known(let v): v
        case .privateAddress: "private"
        case .unlisted: "not in table"
        case .noMAC: "unknown"
        }
    }

    func channel(_ n: WiFiNetwork) -> String {
        guard let c = n.channel else { return "unknown" }
        return "\(c)" + (n.band.map { WiFiChannels.isDFS($0, c) } == true ? " DFS" : "")
    }
}
