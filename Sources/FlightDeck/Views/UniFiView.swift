// The UniFi destination: WAN/health instruments with a WAN rate graph for the visible session, the busiest clients,
// the topology tree with a detail pane, and the sortable client list. Polls only while on screen (UniFiModel). In demo
// mode it shows UniFiDemo's invented network.
import SwiftUI
import FlightDeckCore

struct UniFiView: View {
    @ObservedObject var model = UniFiModel.shared
    @Environment(\.palette) var p
    /// Off-screen renders (UIBench) show the model's current data and must not start polling or detection.
    @Environment(\.offscreen) private var offscreen
    @State private var selection: UniFiSelection?
    @State private var sort: UniFiClientList.Sort = .traffic

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let s = model.snapshot { content(s) }
                else if model.isConfigured { ProgressView(model.lastError == nil ? "Reading the console…" : "Waiting for a successful read…").padding(30) }
                else { setup }
            }.padding(16)
        }
        .onAppear { if !offscreen { model.viewAppeared() } }
        .onDisappear { if !offscreen { model.viewDisappeared() } }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(headline).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await model.refresh() } }.disabled(!model.isConfigured || model.loading)
            }
            // The cached snapshot stays on screen after a failed poll; the error says why it isn't updating.
            if let e = model.lastError {
                Text(model.untrustedFingerprint != nil ? "\(e)\nCompare it with your console's certificate, then trust it in Settings › UniFi." : e)
                    .font(.system(size: 11)).foregroundStyle(p.crit).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var headline: String {
        guard let s = model.snapshot else { return model.config.map { "UniFi console \($0.host)" } ?? "UniFi" }
        let api = switch s.source {
        case .demo: "demo network (invented)"; case .classic: "classic API"; case .integration: "Integration API"; case .integrationAndClassic: "Integration + classic API"
        }
        let site = s.site?.description ?? s.site?.name ?? "site ?"
        return "\(model.config?.host ?? "Demo console") · \(site) · \(api) · \(s.devices.count) devices · \(s.clients.count) clients · updated \(s.time.formatted(date: .omitted, time: .standard))"
    }

    var setup: some View {
        Panel(title: "Connect a UniFi console") {
            Text("FlightDeck can read your UniFi network (gateway, switches, access points, clients and WAN health) from a UniFi OS console (Dream Machine, Dream Router, Cloud Gateway, Cloud Key) or a self-hosted UniFi Network application. It's off until you configure it in Settings › UniFi, and it only reads.")
                .font(.system(size: 11)).foregroundStyle(p.text).fixedSize(horizontal: false, vertical: true)
            if let s = model.suggestion {
                Text("Suggested: \(s.host). \(s.reason)").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.accent)
            }
            Text("Recommended: create an API key in UniFi Network › Settings › Control Plane › Integrations. Or use a local read-only account.")
                .font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            SettingsLink { Text("Open Settings…") }
        }
    }

    @ViewBuilder func content(_ s: UniFiSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            wan(s).frame(maxWidth: .infinity)
            UniFiBusiest(snapshot: s).frame(width: 400)
        }
        HStack(alignment: .top, spacing: 12) {
            Panel(title: "Topology", trailing: "gateway → switches → access points → clients") {
                UniFiTopologyView(topology: s.topology, selection: $selection)
            }.frame(maxWidth: .infinity)
            detail(s).frame(width: 340)
        }
        UniFiClientList(snapshot: s, sort: $sort, selection: $selection)
        if !s.notes.isEmpty {
            Panel(title: "Not provided by this console") {
                ForEach(s.notes, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    @ViewBuilder func detail(_ s: UniFiSnapshot) -> some View {
        switch selection {
        case .device(let mac)?: if let d = s.device(mac: mac) { UniFiDeviceDetail(device: d, snapshot: s) } else { gone }
        case .client(let mac)?: if let c = s.clients.first(where: { $0.mac == mac }) { UniFiClientDetail(client: c, snapshot: s) } else { gone }
        case nil: if let g = s.gateway ?? s.devices.first { UniFiDeviceDetail(device: g, snapshot: s) } else { gone }
        }
    }
    var gone: some View { Panel(title: "Details") { Text("No longer on the network.").font(.system(size: 11)).foregroundStyle(p.dim) } }

    func wan(_ s: UniFiSnapshot) -> some View {
        let h = s.health
        return Panel(title: "WAN", trailing: h.subsystems["wan"].map { "status \($0)" }) {
            HStack(alignment: .top, spacing: 18) {
                Readout(label: "Down", value: h.wanRxBps.map(Fmt.bits), color: p.accent)
                Readout(label: "Up", value: h.wanTxBps.map(Fmt.bits), color: p.accent2)
                Readout(label: "Latency", value: h.latencyMs.map { String(format: "%.0f", $0) }, unit: "ms")
                Readout(label: "Loss", value: h.packetLossPercent.map { String(format: "%.1f", $0) }, unit: "%")
                Readout(label: "Uptime", value: h.wanUptime.map(Fmt.duration), size: 16)
            }
            HistoryGraph(traces: [GraphTrace(name: "Down", values: model.wanRx, color: p.accent),
                                  GraphTrace(name: "Up", values: model.wanTx, color: p.accent2, fill: false)],
                         minHeadroom: 125_000, format: Fmt.bits).frame(height: 90)
            Legend(items: [("Down", p.accent, h.wanRxBps.map(Fmt.bits) ?? "—"), ("Up", p.accent2, h.wanTxBps.map(Fmt.bits) ?? "—"),
                           ("Samples", p.dim, "\(model.wanRx.count) × 15 s, this session")])
            HStack(spacing: 18) {
                Readout(label: "WAN IP", value: h.wanIP, size: 13)
                Readout(label: "ISP", value: h.isp, size: 13)
                Readout(label: "Speed test", value: h.speedTest.map { t in
                    [t.downloadMbps.map { String(format: "↓%.0f", $0) }, t.uploadMbps.map { String(format: "↑%.0f Mbps", $0) }].compactMap { $0 }.joined(separator: " ")
                }, size: 13)
                Readout(label: "Tested", value: h.speedTest?.time.map { $0.formatted(.relative(presentation: .named)) }, size: 13)
            }
            if !h.subsystems.isEmpty {
                Text(h.subsystems.sorted { $0.key < $1.key }.map { "\($0.key.uppercased()) \($0.value)" }.joined(separator: "  ·  "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
            }
        }
    }
}
