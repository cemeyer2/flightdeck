import SwiftUI
import FlightDeckCore

// UPnP destination: the devices that answer UPnP discovery on the local network, as a map grouped by type with a
// details pane, plus the router's UPnP port mappings ("which apps opened ports through my router"). Scans when shown
// and on Refresh; see UPnPModel.

struct UPnPView: View {
    @Environment(\.palette) var p
    @StateObject var model = UPnPModel()

    var body: some View {
        MaybeScroll {
            VStack(spacing: 12) {
                header
                if let s = model.scan { content(s) } else { ProgressView("Searching for UPnP devices…").padding(30) }
            }.padding(16)
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    var header: some View {
        HStack {
            Text("Devices that answer UPnP discovery (SSDP) on this network, read-only. Unknown fields are shown as not reported.")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
            Spacer()
            if !Demo.isEnabled {
                Text(model.listenError.map { "not listening: \($0)" } ?? "listening · \(model.heard) announcements")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).help("Passive NOTIFY listener, only while this page is open")
            }
            if model.scanning { ProgressView().controlSize(.small) }
            Button("Refresh") { model.refresh() }.disabled(model.scanning)
        }
    }

    /// Taller for busy networks, so the rings of nodes have room for their labels.
    static func mapHeight(_ n: Int) -> CGFloat { n > 24 ? 700 : n > 12 ? 580 : 460 }

    @ViewBuilder func content(_ s: UPnPScan) -> some View {
        if let e = s.error { Text("Discovery failed: \(e).").foregroundStyle(.orange).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading) }
        let hosts = s.byHost
        let gwIP = s.gateway.flatMap { g in s.devices.first { $0.id == g.deviceID }?.ip }
        Panel(title: "UPnP map", trailing: "\(hosts.count) hosts · \(s.devices.count) root devices · scanned \(s.finished.formatted(date: .omitted, time: .shortened))") {
            if hosts.isEmpty {
                Text(s.error == nil ? "No device answered within 3 seconds. Either nothing on this network speaks UPnP, or the network blocks multicast (common on guest and corporate Wi-Fi)." : "Nothing to show.")
                    .font(.system(size: 11)).foregroundStyle(p.dim)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    UPnPMapView(hosts: hosts, gatewayIP: gwIP, selection: $model.selection).frame(minWidth: 420).frame(height: Self.mapHeight(hosts.count))
                    UPnPHostDetails(host: hosts.first { $0.id == model.selection } ?? hosts.first { $0.ip == gwIP } ?? hosts[0])
                        .frame(width: 310, alignment: .topLeading)
                }
            }
        }
        UPnPMappingsPanel(scan: s)
    }
}

/// Everything known about one host: each root device's description, services and embedded devices.
struct UPnPHostDetails: View {
    @Environment(\.palette) var p
    var host: UPnPHostGroup
    @State private var showSerial = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: UPnPMapView.symbol(host.category)).foregroundStyle(p.accent)
                Text(host.displayName).font(.system(size: 14, weight: .semibold, design: .monospaced)).lineLimit(1)
            }
            Text("\(host.ip) · \(host.category.rawValue.lowercased())").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim).textSelection(.enabled)
            ForEach(host.roots) { r in root(r) }
            if host.roots.contains(where: { $0.description?.serialNumber != nil }) {
                Toggle("Show serial numbers", isOn: $showSerial).toggleStyle(.checkbox).font(.system(size: 11))
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(p.background.opacity(0.5)))
    }

    @ViewBuilder func root(_ r: UPnPRootDevice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if let d = r.description {
                device(d, depth: 0)
            } else {
                fact("Description", "not read: \(r.descriptionError ?? "unknown reason")")
            }
            fact("Server", r.server ?? "not reported")
            fact("Location", r.location)
        }
    }

    func device(_ d: UPnPDevice, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 3) {
            Text(d.friendlyName ?? "unnamed device").font(.system(size: 12, weight: .semibold, design: .monospaced))
            fact("Type", d.shortType.isEmpty ? "not reported" : d.shortType)
            if depth == 0 || d.manufacturer != nil { fact("Maker", d.manufacturer ?? "not reported", link: d.manufacturerURL) }
            if depth == 0 || d.modelName != nil {
                fact("Model", [d.modelName, d.modelNumber].compactMap { $0 }.joined(separator: " ").nonEmpty ?? "not reported", link: d.modelURL)
            }
            if let m = d.modelDescription { fact("About", m) }
            if let s = d.serialNumber { fact("Serial", showSerial ? s : "hidden (identifying)") }
            if let u = d.presentationURL { fact("Web page", u, link: u) }
            if !d.services.isEmpty {
                Text("SERVICES").font(.meterLabel).foregroundStyle(p.dim).padding(.top, 2)
                ForEach(d.services) { s in
                    Text("· \(s.shortName)").font(.system(size: 11, design: .monospaced))
                        .help([s.serviceType, s.controlURL.map { "control: \($0)" }, s.scpdURL.map { "SCPD: \($0)" }].compactMap { $0 }.joined(separator: "\n"))
                }
            }
            ForEach(d.embedded) { e in device(e, depth: depth + 1) }
        }.padding(.leading, depth == 0 ? 0 : 12)
         .overlay(alignment: .leading) { if depth > 0 { Rectangle().fill(p.grid).frame(width: 1) } })
    }

    /// Label: value, with the value a link when one is given (http/https only, never anything else the device says).
    @ViewBuilder func fact(_ label: String, _ value: String, link: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label.uppercased()).font(.meterLabel).foregroundStyle(p.dim).frame(width: 70, alignment: .leading)
            if let link, let u = URL(string: link), u.scheme == "http" || u.scheme == "https" {
                Link(value, destination: u).font(.system(size: 11, design: .monospaced)).lineLimit(2)
            } else {
                Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(value.hasPrefix("not ") || value.hasPrefix("hidden") ? p.dim : p.text)
                    .lineLimit(3).textSelection(.enabled)
            }
        }
    }
}

/// The router's UPnP port mappings: which LAN address each forwards to, with mappings to this Mac flagged.
struct UPnPMappingsPanel: View {
    @Environment(\.palette) var p
    var scan: UPnPScan

    var body: some View {
        let g = scan.gateway
        Panel(title: "Router port mappings (UPnP IGD)", trailing: g.map { "\($0.mappings.count) mappings" + ($0.truncated ? " (first 256)" : "") }) {
            if let g {
                HStack(spacing: 24) {
                    Readout(label: "External IP", value: g.externalIP, size: 16)
                    Readout(label: "Mappings", value: "\(g.mappings.count)", size: 16)
                    Readout(label: "To this Mac", value: "\(g.mappings.filter { scan.localAddresses.contains($0.internalClient ?? "") }.count)", size: 16)
                    Spacer()
                }
                if let e = g.externalIPError { note("External IP unknown: \(e).") }
                if let e = g.mappingsError { note("The list may be incomplete: \(e).").foregroundStyle(.orange) }
                if g.mappings.isEmpty {
                    note("The router reports no UPnP port mappings: no app on this network has opened a port through it.")
                } else {
                    table(g.mappings)
                    note("Each mapping lets anyone on the internet reach that LAN device on that port. They're created by apps (games, torrent clients, media servers, consoles) without asking. FlightDeck only reads them; remove unwanted ones in the router's settings or by quitting the app.")
                }
            } else {
                note(scan.devices.contains { $0.category == .gateway }
                     ? "A router answered, but it offers no WANIPConnection or WANPPPConnection service FlightDeck could query, so its port mappings are unknown."
                     : "No UPnP Internet Gateway Device answered, so port mappings are unknown. Either the router has UPnP turned off (safer: apps can't open ports through it) or it doesn't support it.")
            }
        }
    }

    func note(_ s: String) -> Text { Text(s).font(.system(size: 11)).foregroundColor(p.dim) }

    func table(_ ms: [UPnPPortMapping]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow { ForEach(["Proto", "External", "Forwards to", "Device", "Description", "Lease", "State"], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
            ForEach(ms) { m in
                let mine = scan.localAddresses.contains(m.internalClient ?? "")
                GridRow {
                    Text(m.proto)
                    Text(verbatim: "\(m.externalPort)" + (m.remoteHost.map { " from \($0)" } ?? "")).monospacedDigit()
                    Text(verbatim: (m.internalClient ?? "?") + ":" + (m.internalPort.map { "\($0)" } ?? "?")).textSelection(.enabled)
                    Group {
                        if mine { Label("This Mac", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        else { Text(m.internalClient.flatMap { scan.hostNames[$0] } ?? "unknown").foregroundStyle(m.internalClient.flatMap { scan.hostNames[$0] } == nil ? p.dim : p.text) }
                    }
                    Text(m.description ?? "no description").foregroundStyle(m.description == nil ? p.dim : p.text).lineLimit(1)
                    Text(m.leaseSeconds.map { $0 == 0 ? "permanent" : Self.duration($0) } ?? "not reported")
                    Text(m.enabled.map { $0 ? "enabled" : "disabled" } ?? "not reported").foregroundStyle(m.enabled == false ? p.dim : p.text)
                }.font(.system(size: 11, design: .monospaced))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    static func duration(_ s: Int) -> String { s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min left" : "\(s / 60) min left" }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
