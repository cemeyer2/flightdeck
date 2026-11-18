// The UniFi topology: gateway → switches (with the port each downstream device is on) → APs → clients, drawn as an
// indented tree of instrument cards with link speeds. Pure SwiftUI (no AppKit controls), so headless renders show it.
// Clicking a device or client selects it for the detail pane.
import SwiftUI
import FlightDeckCore

/// What the detail pane shows: a device or a client, by normalized MAC.
enum UniFiSelection: Hashable { case device(String), client(String) }

struct UniFiTopologyView: View {
    @Environment(\.palette) var p
    var topology: UniFiTopology
    @Binding var selection: UniFiSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(topology.roots) { NodeView(node: $0, selection: $selection) }
            if !topology.unattached.isEmpty {
                Text("NOT ATTRIBUTED TO AN AP OR SWITCH (\(topology.unattached.count))").font(.meterLabel).foregroundStyle(p.dim).padding(.top, 6)
                ClientChips(clients: topology.unattached, selection: $selection)
            }
        }
    }
}

/// One device, its port-attached clients, its other clients and its child devices, with a guide line on the left.
private struct NodeView: View {
    @Environment(\.palette) var p
    var node: UniFiTopology.Node
    @Binding var selection: UniFiSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            DeviceCard(node: node, selected: selection == .device(node.device.mac)).onTapGesture { selection = .device(node.device.mac) }
            VStack(alignment: .leading, spacing: 5) {
                // Wired clients by port, in port order.
                ForEach(node.portClients.keys.sorted(), id: \.self) { port in
                    HStack(alignment: .top, spacing: 6) {
                        PortTag(text: "PORT \(port)", speed: node.device.ports.first { $0.index == port }?.speedMbps)
                        ClientChips(clients: node.portClients[port] ?? [], selection: $selection)
                    }
                }
                if !node.clients.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        if node.device.kind == .accessPoint { PortTag(text: "WI-FI", speed: nil) } else { PortTag(text: "PORT ?", speed: nil) }
                        ClientChips(clients: node.clients, selection: $selection)
                    }
                }
                ForEach(node.children) { NodeView(node: $0, selection: $selection) }
            }
            .padding(.leading, 22)
            .overlay(alignment: .leading) { Rectangle().fill(p.accent.opacity(0.35)).frame(width: 2).padding(.leading, 9) }
        }
    }
}

private struct PortTag: View {
    @Environment(\.palette) var p
    var text: String
    var speed: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
            if let speed { Text(UniFiFmt.speed(speed)).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.accent) }
        }
        .frame(width: 58, alignment: .leading).padding(.top, 4)
    }
}

/// A device card: icon, name, model, IP, state, the port it hangs off and the link speed, client count.
private struct DeviceCard: View {
    @Environment(\.palette) var p
    var node: UniFiTopology.Node
    var selected: Bool

    var body: some View {
        let d = node.device
        HStack(spacing: 10) {
            Image(systemName: UniFiFmt.icon(d.kind)).font(.system(size: 16)).foregroundStyle(d.online == false ? p.crit : p.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.displayName).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(p.text)
                    Text(d.model ?? "model unknown").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                }
                Text([d.ip ?? "IP unknown", d.online == false ? (d.state ?? "offline").uppercased() : nil,
                      d.clientCount.map { "\($0) clients" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(d.online == false ? p.crit : p.dim)
            }
            Spacer(minLength: 8)
            if d.uplink?.parentMAC != nil {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(d.uplink?.wireless == true ? "MESH" : node.parentPort.map { "ON PORT \($0)" } ?? "PORT UNKNOWN")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
                    Text(node.linkMbps.map(UniFiFmt.speed) ?? "speed unknown").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.accent)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(p.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? p.accent : p.panelBorder, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}

/// Clients as small chips: name, and signal (wireless) or link speed (wired), plus the current total rate.
struct ClientChips: View {
    @Environment(\.palette) var p
    var clients: [UniFiClient]
    @Binding var selection: UniFiSelection?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 5, alignment: .leading)], alignment: .leading, spacing: 5) {
            ForEach(clients) { c in
                let sel = selection == .client(c.mac)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.displayName).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(p.text).lineLimit(1)
                    HStack(spacing: 5) {
                        if c.wired == false {
                            Text(c.signalDbm.map { "\($0) dBm" } ?? "signal ?").foregroundStyle(UniFiFmt.signalColor(c.signalDbm, p))
                            if let ch = c.channel { Text("ch \(ch)") }
                        } else if let s = c.linkSpeedMbps { Text(UniFiFmt.speed(s)) }
                        Spacer(minLength: 0)
                        Text(c.totalBps.map(Fmt.rate) ?? "—")
                    }
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim)
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.panel))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(sel ? p.accent : p.panelBorder))
                .contentShape(Rectangle())
                .onTapGesture { selection = .client(c.mac) }
            }
        }
    }
}

/// Formatting shared by the UniFi views.
enum UniFiFmt {
    static func speed(_ mbps: Int) -> String { mbps >= 1000 ? (mbps % 1000 == 0 ? "\(mbps / 1000) Gbps" : String(format: "%.1f Gbps", Double(mbps) / 1000)) : "\(mbps) Mbps" }
    static func icon(_ k: UniFiDeviceKind) -> String {
        switch k {
        case .gateway: "globe"; case .switch: "rectangle.connected.to.line.below"; case .accessPoint: "wifi.router"; case .other: "shippingbox"
        }
    }
    /// Signal quality colours: better than −60 dBm is good, −60…−70 fair, worse than −70 poor (common Wi-Fi guidance).
    static func signalColor(_ dbm: Int?, _ p: Palette) -> Color {
        guard let dbm else { return p.dim }
        return dbm >= -60 ? p.accent : dbm >= -70 ? p.warn : p.crit
    }
}
