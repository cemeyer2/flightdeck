import SwiftUI
import FlightDeckCore

// Side and bottom panels of the Network view: this network's facts, the discovery controls (with what each one does,
// because the active scan and traceroute send packets), and the sortable device list.

private func factRow(_ p: Palette, _ k: String, _ v: String, dim: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(k).foregroundStyle(p.dim).frame(width: 82, alignment: .leading)
        Text(v).foregroundStyle(dim ? p.dim : p.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
    }
    .font(.system(size: 11, design: .monospaced))
}

struct NetworkFactsPanel: View {
    @Environment(\.palette) var p
    var s: NetworkSurvey
    var body: some View {
        Panel(title: "This network") {
            let gw = s.devices.first { $0.isGateway }
            factRow(p, "Route", s.route.map { "default via \($0.gateway) on \($0.interface)" } ?? "no default route", dim: s.route == nil)
            if let ap = s.accessPoint {
                factRow(p, "Wi-Fi", ap.ssid ?? "name hidden (needs Location permission)", dim: ap.ssid == nil)
                factRow(p, "AP BSSID", ap.bssid ?? "hidden (needs Location permission)", dim: ap.bssid == nil)
                factRow(p, "Channel", [ap.channel, ap.rssi.map { "\($0) dBm" }].compactMap { $0 }.joined(separator: " · "))
            }
            factRow(p, "Router", gw.map { "\($0.displayName) · \($0.vendor.name ?? "vendor unknown")" } ?? "not seen", dim: gw == nil)
            let v6 = s.devices.filter(\.isIPv6Router)
            if !v6.isEmpty { factRow(p, "IPv6 router", v6.map(\.displayName).joined(separator: ", ")) }
            factRow(p, "DNS", s.dns.isEmpty ? "none in /etc/resolv.conf" : s.dns.joined(separator: ", "), dim: s.dns.isEmpty)
            ForEach(s.topology.branches) { b in
                factRow(p, b.interface.name, ([b.interface.displayName] + b.interface.ipv4.map { "\($0.address)/\($0.prefix)" } + b.interface.globalIPv6.prefix(1))
                    .joined(separator: " · "))
            }
            if !s.topology.hops.isEmpty {
                factRow(p, "Path", s.topology.hops.map { h in "\(h.number) " + (h.ip ?? "no reply") + (h.ms.map { String(format: " %.0f ms", $0) } ?? "") }
                    .joined(separator: "\n"))
            }
            ForEach(s.notes, id: \.self) { Text($0).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct DiscoveryPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: NetworkMapModel
    func note(_ t: String) -> some View {
        Text(t).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
    }
    var body: some View {
        Panel(title: "Discovery") {
            if model.fixed && Demo.isEnabled {
                note("Demo mode: an invented network. Nothing here describes your real network, and scanning is off.")
            }
            note("Read without sending anything: this Mac's interfaces, routes and ARP/NDP caches (re-read every 10 s while this view is open), plus a Bonjour browse and reverse DNS on Refresh.")
            HStack {
                Button("Refresh") { model.refresh(full: true) }
                Button("Active scan") { model.activeScan() }.disabled(model.scanTarget == nil)
                Button("Traceroute") { model.traceroute() }
            }
            .disabled(model.fixed || model.busy != nil)
            .controlSize(.small)
            note(model.scanTarget.map { "Active scan sends one ping to each of the \($0.count) addresses of \(ActiveScan.targetDescription($0.net)), 50 per second, so every device that's on answers ARP and shows up, even ones that ignore pings." }
                 ?? "Active scan is unavailable: no IPv4 subnet to scan on the main interface.")
            note("Traceroute sends probes toward 1.1.1.1 to show the hops between your router and the internet.")
            if let b = model.busy, !b.isEmpty {
                HStack(spacing: 6) { ProgressView().controlSize(.small); note(b) }
            }
            if let st = model.status { Text(st).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.text).fixedSize(horizontal: false, vertical: true) }
            note("macOS may ask to let FlightDeck find devices on your local network; Bonjour and the active scan need that permission.")
        }
    }
}

extension ActiveScan {
    /// "192.168.1.0/24" for a /24 or smaller subnet; "the /24 around this Mac in 10.0.0.0/16" for larger ones.
    static func targetDescription(_ n: IPv4Net) -> String {
        n.prefix >= 24 ? n.cidr : "\(IPv4Net(address: n.address, prefix: 24).cidr) (only the /24 around this Mac of \(n.cidr))"
    }
}

/// Every device, sortable by clicking a column header. A custom list rather than a SwiftUI Table so the page also
/// renders off-screen.
struct DeviceListPanel: View {
    @Environment(\.palette) var p
    var devices: [NetDevice]
    @Binding var selected: String?
    @State private var sort: Column = .ip
    @State private var ascending = true

    enum Column: String, CaseIterable { case name = "Name", type = "Type", ip = "IP address", mac = "MAC", vendor = "Vendor", services = "Services", first = "First seen" }
    static let widths: [Column: CGFloat] = [.name: 190, .type: 120, .ip: 120, .mac: 150, .vendor: 150, .first: 90]

    var sorted: [NetDevice] {
        func key(_ d: NetDevice) -> String {
            switch sort {
            case .name: d.displayName.lowercased()
            case .type: d.kind.rawValue
            case .ip: String(format: "%010u", IPv4.parse(d.ipv4.first ?? "") ?? .max)
            case .mac: d.mac ?? "~"
            case .vendor: d.vendor.name?.lowercased() ?? "~"
            case .services: String(format: "%04d", 999 - d.services.count)
            case .first: String(format: "%015.0f", d.firstSeen.timeIntervalSince1970)
            }
        }
        let s = devices.sorted { (key($0), $0.id) < (key($1), $1.id) }
        return ascending ? s : s.reversed()
    }

    func cell(_ t: String, _ c: Column, dim: Bool = false) -> some View {
        Text(t).foregroundStyle(dim ? p.dim : p.text).lineLimit(1).truncationMode(.middle)
            .frame(width: Self.widths[c], alignment: .leading)
    }

    var body: some View {
        Panel(title: "Devices", trailing: "\(devices.count) seen · click a header to sort") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 18, height: 1)
                    ForEach(Column.allCases, id: \.self) { c in
                        Button {
                            if sort == c { ascending.toggle() } else { sort = c; ascending = true }
                        } label: {
                            Text(c.rawValue.uppercased() + (sort == c ? (ascending ? " ▲" : " ▼") : ""))
                                .font(.meterLabel).foregroundStyle(sort == c ? p.text : p.dim)
                                .frame(maxWidth: Self.widths[c] == nil ? .infinity : nil, alignment: .leading)
                                .frame(width: Self.widths[c], alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                ForEach(sorted) { d in
                    HStack(spacing: 8) {
                        Image(systemName: d.kind.icon).frame(width: 18).foregroundStyle(p.accent)
                        cell(d.displayName, .name)
                        cell(d.kind.rawValue, .type, dim: d.kind == .unknown)
                        cell(d.ipv4.first ?? d.ipv6.first ?? "—", .ip)
                        cell(d.mac ?? "unknown", .mac, dim: d.mac == nil)
                        cell(d.vendor.name ?? (d.vendor == .privateAddress ? "private address" : "unknown"), .vendor, dim: d.vendor.name == nil)
                        Text(d.services.isEmpty ? "—" : d.services.map(serviceLabel).joined(separator: ", "))
                            .foregroundStyle(d.services.isEmpty ? p.dim : p.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        cell(d.isThisMac ? "—" : d.firstSeen.formatted(date: .omitted, time: .shortened), .first, dim: d.isThisMac)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.vertical, 3).padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(selected == d.id ? p.accent.opacity(0.14) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selected = d.id }
                }
            }
        }
    }
}
