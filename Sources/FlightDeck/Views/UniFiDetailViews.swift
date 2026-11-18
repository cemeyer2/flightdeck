// UniFi detail panes (one device: health, ports, radios; one client: attachment, signal, traffic), the sortable client
// list and the "busiest clients" readout. Unknown values show as "—" or "not reported", never as 0.
import SwiftUI
import FlightDeckCore

struct UniFiDeviceDetail: View {
    @Environment(\.palette) var p
    var device: UniFiDevice
    var snapshot: UniFiSnapshot

    var body: some View {
        let d = device
        Panel(title: d.displayName, trailing: d.model) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { Readout(label: "State", value: d.state ?? d.online.map { $0 ? "online" : "offline" }, size: 13); Readout(label: "Uptime", value: d.uptime.map(Fmt.duration), size: 13) }
                GridRow { Readout(label: "IP", value: d.ip, size: 13); Readout(label: "Firmware", value: d.firmware, size: 13) }
                GridRow { Readout(label: "MAC", value: d.mac, size: 11); Readout(label: "Clients", value: d.clientCount.map(String.init), size: 13) }
            }
            meter("CPU", d.cpuPercent); meter("Memory", d.memoryPercent)
            if d.temperatures.isEmpty { fact("Temperatures not reported") }
            ForEach(d.temperatures, id: \.name) { t in fact("\(t.name) \(Fmt.temp(t.celsius))") }
            if let u = d.uplink, let parent = u.parentMAC {
                fact("Uplink: \(snapshot.device(mac: parent)?.displayName ?? parent)" + (u.parentPort.map { " port \($0)" } ?? "")
                     + (u.speedMbps.map { " · " + UniFiFmt.speed($0) } ?? ""))
            }
            if !d.radios.isEmpty {
                Text("RADIOS").font(.meterLabel).foregroundStyle(p.dim).padding(.top, 4)
                ForEach(Array(d.radios.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        fact([r.band ?? "band ?", r.channel.map { "ch \($0)" }, r.widthMHz.map { "\($0) MHz" }, r.standard,
                              r.clientCount.map { "\($0) clients" }, r.txPowerDbm.map { "\($0) dBm" }].compactMap { $0 }.joined(separator: " · "))
                        HStack { Text("Utilization").font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim).frame(width: 70, alignment: .leading)
                            VFDMeter(fraction: r.utilizationPercent.map { $0 / 100 }, segments: 20, height: 7)
                            Text(r.utilizationPercent.map { String(format: "%.0f%%", $0) } ?? "—").font(.system(size: 9, design: .monospaced)).frame(width: 32, alignment: .trailing) }
                    }
                }
            }
            if !d.ports.isEmpty {
                Text("PORTS").font(.meterLabel).foregroundStyle(p.dim).padding(.top, 4)
                ForEach(d.ports) { port in
                    let who = snapshot.clients(on: d.mac, port: port.index).map(\.displayName)
                        + snapshot.devices.filter { $0.uplink?.parentMAC == d.mac && $0.uplink?.parentPort == port.index }.map(\.displayName)
                    HStack(spacing: 6) {
                        Circle().fill(port.up == true ? p.accent : p.meterOff).frame(width: 6, height: 6)
                        Text("\(port.index)").frame(width: 18, alignment: .trailing)
                        Text(port.up == false ? "down" : port.speedMbps.map(UniFiFmt.speed) ?? "—").frame(width: 62, alignment: .leading)
                        Text(port.poeWatts.map { String(format: "PoE %.1f W", $0) } ?? (port.poeEnabled == true ? "PoE" : "")).frame(width: 70, alignment: .leading)
                        Text(who.isEmpty ? (port.name ?? "") : who.joined(separator: ", ")).foregroundStyle(p.text).lineLimit(1)
                    }
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                }
            }
        }
    }

    func meter(_ label: String, _ v: Double?) -> some View {
        HStack {
            Text(label.uppercased()).font(.meterLabel).foregroundStyle(p.dim).frame(width: 60, alignment: .leading)
            VFDMeter(fraction: v.map { $0 / 100 })
            Text(v.map { String(format: "%.0f%%", $0) } ?? "—").font(.system(size: 11, design: .monospaced)).frame(width: 36, alignment: .trailing)
        }
    }
    func fact(_ s: String) -> some View { Text(s).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim) }
}

struct UniFiClientDetail: View {
    @Environment(\.palette) var p
    var client: UniFiClient
    var snapshot: UniFiSnapshot

    var body: some View {
        let c = client
        let parent = c.parentMAC.flatMap { snapshot.device(mac: $0) }
        Panel(title: c.displayName, trailing: c.wired == nil ? "connection unknown" : c.wired! ? "wired" : "wireless") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { Readout(label: "IP", value: c.ip, size: 13); Readout(label: "MAC", value: c.mac, size: 11) }
                GridRow { Readout(label: "Hostname", value: c.hostname, size: 13); Readout(label: "Vendor", value: c.vendor, size: 13) }
                GridRow { Readout(label: c.wired == false ? "Access point" : "Switch", value: parent?.displayName ?? c.parentMAC, size: 13)
                          Readout(label: c.wired == false ? "SSID" : "Port", value: c.wired == false ? c.ssid : c.switchPort.map(String.init), size: 13) }
                if c.wired == false {
                    GridRow { Readout(label: "Signal", value: c.signalDbm.map(String.init), unit: "dBm", color: UniFiFmt.signalColor(c.signalDbm, p), size: 13)
                              Readout(label: "Channel", value: c.channel.map { "\($0)" + (c.band.map { " (\($0))" } ?? "") }, size: 13) }
                    GridRow { Readout(label: "Standard", value: c.wifiStandard, size: 12); Readout(label: "RSSI", value: c.rssi.map(String.init), unit: "dB", size: 13) }
                }
                GridRow { Readout(label: "Link", value: c.linkSpeedMbps.map(UniFiFmt.speed), size: 13); Readout(label: "Uptime", value: c.uptime.map(Fmt.duration), size: 13) }
                GridRow { Readout(label: "Down", value: c.downloadBps.map(Fmt.rate), size: 13); Readout(label: "Up", value: c.uploadBps.map(Fmt.rate), size: 13) }
                GridRow { Readout(label: "Downloaded", value: c.downloadBytes.map(Fmt.bytes), size: 13); Readout(label: "Uploaded", value: c.uploadBytes.map(Fmt.bytes), size: 13) }
            }
        }
    }
}

/// Sortable client list (Table needs AppKit, which off-screen renders can't draw, so this is a SwiftUI grid).
struct UniFiClientList: View {
    @Environment(\.palette) var p
    enum Sort: String, CaseIterable, Identifiable { case traffic = "Traffic", signal = "Signal", name = "Name"; var id: String { rawValue } }
    var snapshot: UniFiSnapshot
    @Binding var sort: Sort
    @Binding var selection: UniFiSelection?

    var sorted: [UniFiClient] {
        switch sort {
        // Unknown values sort last, so missing data never masquerades as "least busy" or "weakest".
        case .traffic: snapshot.clients.sorted { ($0.totalBps ?? -1) > ($1.totalBps ?? -1) }
        case .signal: snapshot.clients.sorted { ($0.signalDbm ?? -999) > ($1.signalDbm ?? -999) }
        case .name: snapshot.clients.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
    }

    var body: some View {
        Panel(title: "Clients", trailing: "\(snapshot.clients.count)") {
            HStack(spacing: 4) {
                Text("SORT").font(.meterLabel).foregroundStyle(p.dim)
                ForEach(Sort.allCases) { s in
                    Text(s.rawValue.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(sort == s ? p.accent.opacity(0.25) : .clear))
                        .foregroundStyle(sort == s ? p.accent : p.dim).contentShape(Capsule()).onTapGesture { sort = s }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow { ForEach(["NAME", "IP", "VIA", "SIGNAL", "LINK", "DOWN", "UP", "TOTAL"], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                ForEach(sorted) { c in
                    let via = c.parentMAC.flatMap { snapshot.device(mac: $0)?.displayName }.map { n in c.wired == false ? n + (c.ssid.map { " · \($0)" } ?? "") : n + (c.switchPort.map { " #\($0)" } ?? "") }
                    GridRow {
                        Text(c.displayName).foregroundStyle(selection == .client(c.mac) ? p.accent : p.text).lineLimit(1)
                        Text(c.ip ?? "—"); Text(via ?? "unknown").lineLimit(1)
                        Text(c.wired == false ? c.signalDbm.map { "\($0) dBm" } ?? "—" : "wired").foregroundStyle(c.wired == false ? UniFiFmt.signalColor(c.signalDbm, p) : p.dim)
                        Text(c.linkSpeedMbps.map(UniFiFmt.speed) ?? "—")
                        Text(c.downloadBps.map(Fmt.rate) ?? "—"); Text(c.uploadBps.map(Fmt.rate) ?? "—")
                        Text(c.downloadBytes.map { Fmt.bytes($0 + (c.uploadBytes ?? 0)) } ?? "—")
                    }
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                    .contentShape(Rectangle()).onTapGesture { selection = .client(c.mac) }
                }
            }
        }
    }
}

/// The five clients moving the most data right now, as VFD meters relative to the busiest.
struct UniFiBusiest: View {
    @Environment(\.palette) var p
    var snapshot: UniFiSnapshot
    var body: some View {
        let top = snapshot.clients.filter { ($0.totalBps ?? 0) > 0 }.sorted { $0.totalBps! > $1.totalBps! }.prefix(5)
        let maxBps = top.first?.totalBps ?? 1
        Panel(title: "Busiest clients", trailing: "now") {
            if top.isEmpty { Text(snapshot.clients.allSatisfy { $0.totalBps == nil } ? "Per-client rates aren't provided by this console's API." : "No client traffic right now.")
                .font(.system(size: 11)).foregroundStyle(p.dim) }
            ForEach(Array(top)) { c in
                HStack(spacing: 8) {
                    Text(c.displayName).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.text).frame(width: 150, alignment: .leading).lineLimit(1)
                    VFDMeter(fraction: c.totalBps! / maxBps, segments: 20, color: p.accent)
                    Text(Fmt.rate(c.totalBps!)).font(.system(size: 11, design: .monospaced)).frame(width: 84, alignment: .trailing)
                }
            }
        }
    }
}
