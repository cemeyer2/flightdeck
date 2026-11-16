import SwiftUI
import FlightdeckCore

struct DiskPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @AppStorage("diskPerDevice") var perDevice = false
    var body: some View {
        let d = e.current?.disk
        VStack(spacing: 12) {
            Panel(title: "Disk activity") {
                HStack(spacing: 28) {
                    Readout(label: "Read", value: d?.readBps.value.map(Fmt.rate), color: p.accent)
                    Readout(label: "Write", value: d?.writeBps.value.map(Fmt.rate), color: p.accent2)
                    Spacer()
                    Toggle("Per device", isOn: $perDevice).toggleStyle(.switch)
                }
                if !perDevice {
                    HistoryGraph(traces: [GraphTrace(name: "r", values: e.series { $0.disk.readBps.value }, color: p.accent),
                                          GraphTrace(name: "w", values: e.series { $0.disk.writeBps.value }, color: p.accent2)],
                                 minHeadroom: 1_048_576, format: Fmt.rate).frame(height: 220)
                }
            }
            if perDevice {
                ForEach(d?.devices ?? []) { dev in
                    Panel(title: dev.name, trailing: "total R \(Fmt.bytes(dev.totalRead)) · W \(Fmt.bytes(dev.totalWritten))") {
                        HistoryGraph(traces: [
                            GraphTrace(name: "r", values: e.series { s in s.disk.devices.first { $0.name == dev.name }?.readBps }, color: p.accent),
                            GraphTrace(name: "w", values: e.series { s in s.disk.devices.first { $0.name == dev.name }?.writeBps }, color: p.accent2)],
                                     minHeadroom: 1_048_576, format: Fmt.rate).frame(height: 120)
                    }
                }
            }
            Panel(title: "Capacity") {
                ForEach(d?.volumes ?? []) { v in VolumeRow(v: v) }
            }
            Panel(title: "Top disk processes") {
                ProcessMiniList(metric: { $0.diskReadBps + $0.diskWriteBps }, format: Fmt.rate)
            }
        }
    }
}

struct VolumeRow: View {
    @Environment(\.palette) var p
    var v: VolumeInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: v.isInternal ? "internaldrive" : "externaldrive")
                Text(v.name).foregroundStyle(p.text)
                Text(v.fileSystem).foregroundStyle(p.dim)
                Spacer()
                Text("\(Fmt.bytes(v.used)) used of \(Fmt.bytes(v.capacity)) · \(Fmt.bytes(v.available)) free").foregroundStyle(p.dim)
            }.font(.system(size: 12, design: .monospaced))
            VFDMeter(fraction: Double(v.used) / Double(max(v.capacity, 1)), segments: 50, height: 8)
        }
    }
}

struct ProcessMiniList: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var metric: (ProcessSample) -> Double
    var format: (Double) -> String
    var count = 6
    var body: some View {
        let procs = (e.current?.processes ?? []).filter { !$0.restricted }.sorted { metric($0) > metric($1) }.prefix(count)
        let top = procs.first.map(metric) ?? 1
        VStack(spacing: 5) {
            ForEach(Array(procs)) { pr in
                HStack {
                    Text(pr.name).lineLimit(1).frame(width: 200, alignment: .leading)
                    Text("\(pr.pid)").foregroundStyle(p.dim).frame(width: 60, alignment: .trailing)
                    VFDMeter(fraction: top > 0 ? metric(pr) / top : 0, segments: 30, height: 6)
                    Text(format(metric(pr))).frame(width: 100, alignment: .trailing)
                }.font(.system(size: 12, design: .monospaced))
            }
            if procs.isEmpty { Text("—").foregroundStyle(p.dim) }
        }
    }
}

struct NetworkPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var body: some View {
        let n = e.current?.network
        VStack(spacing: 12) {
            ConnectionQualityPanel()
            Panel(title: "Bandwidth") {
                HStack(spacing: 28) {
                    Readout(label: "Receive", value: n?.inBps.value.map(Fmt.bits), color: p.accent)
                    Readout(label: "Send", value: n?.outBps.value.map(Fmt.bits), color: p.accent2)
                    Readout(label: "Received (boot)", value: n.map { Fmt.bytes($0.totalIn) })
                    Readout(label: "Sent (boot)", value: n.map { Fmt.bytes($0.totalOut) })
                    Spacer()
                }
                HistoryGraph(traces: [GraphTrace(name: "in", values: e.series { $0.network.inBps.value }, color: p.accent),
                                      GraphTrace(name: "out", values: e.series { $0.network.outBps.value }, color: p.accent2)],
                             minHeadroom: 65_536, format: Fmt.rate).frame(height: 220)
            }
            AppNetworkPanel()
            Panel(title: "Interfaces") {
                let ifs = (n?.interfaces ?? []).filter { $0.totalIn + $0.totalOut > 0 || !$0.addresses.isEmpty }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { ForEach(["Name", "Status", "Link", "↓ now", "↑ now", "↓ total", "↑ total", "Address", "MAC"], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                    ForEach(ifs) { i in
                        GridRow {
                            Text(i.name); Text(i.isUp ? "up" : "down").foregroundStyle(i.isUp ? p.accent : p.dim)
                            Text(i.linkSpeed > 0 ? Fmt.bits(Double(i.linkSpeed) / 8) : "—")
                            Text(Fmt.rate(i.inBps)); Text(Fmt.rate(i.outBps))
                            Text(Fmt.bytes(i.totalIn)); Text(Fmt.bytes(i.totalOut))
                            Text(i.addresses.first { !$0.contains(":") } ?? i.addresses.first ?? "—").textSelection(.enabled)
                            Text(i.mac ?? "—").foregroundStyle(p.dim)
                        }.font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
    }
}

struct EnergyPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var body: some View {
        let pw = e.current?.power
        VStack(spacing: 12) {
            Panel(title: "Power", trailing: pw?.powerSource) {
                HStack(spacing: 28) {
                    Readout(label: "System draw", value: pw?.systemWatts.value.map { String(format: "%.2f", $0) }, unit: "W", color: p.accent)
                    Readout(label: "Battery flow", value: pw?.batteryWatts.value.map { String(format: "%+.2f", $0) }, unit: "W", color: p.accent2)
                    Readout(label: "Low Power Mode", value: pw.map { $0.lowPowerMode ? "On" : "Off" })
                    Readout(label: "Adapter", value: pw?.battery?.adapterWatts.map { "\($0) W" })
                    Spacer()
                }
                HistoryGraph(traces: [GraphTrace(name: "sys", values: e.series { $0.power.systemWatts.value }, color: p.accent),
                                      GraphTrace(name: "bat", values: e.series { $0.power.batteryWatts.value.map(abs) }, color: p.accent2, fill: false)],
                             minHeadroom: 10, format: { String(format: "%.0f W", $0) }).frame(height: 200)
            }
            if let b = pw?.battery {
                Panel(title: "Battery") {
                    HStack(spacing: 28) {
                        Readout(label: "Charge", value: String(format: "%.0f", b.percent), unit: "%")
                        Readout(label: "State", value: b.isCharging ? "Charging" : (b.externalConnected ? "On AC" : "Discharging"))
                        Readout(label: "Time remaining", value: b.timeRemaining.map { "\($0 / 60)h \($0 % 60)m" })
                        Readout(label: "Health", value: b.health.map { String(format: "%.0f", $0) }, unit: "%")
                        Readout(label: "Cycles", value: b.cycleCount.map(String.init))
                        Readout(label: "Temp", value: b.temperature.map { String(format: "%.1f", $0) }, unit: "°C")
                        Readout(label: "Voltage", value: b.voltage.map { String(format: "%.2f", $0) }, unit: "V")
                        Spacer()
                    }
                    VFDMeter(fraction: b.percent / 100, segments: 40, color: b.percent < 20 ? p.crit : p.accent)
                }
            }
            Panel(title: "Top energy processes (measured energy)") {
                ProcessMiniList(metric: { $0.energyWatts ?? 0 }, format: { String(format: "%.2f W", $0) }, count: 10)
            }
        }
    }
}

struct ThermalPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var body: some View {
        let pw = e.current?.power
        VStack(spacing: 12) {
            Panel(title: "Thermal pressure") {
                HStack(spacing: 28) {
                    Readout(label: "State", value: pw.map { thermalName($0.thermalState) }, color: (pw?.thermalState ?? 0) >= 2 ? p.crit : p.accent)
                    Readout(label: "Hotspot", value: pw?.hottest.value.map { String(format: "%.1f", $0) }, unit: "°C")
                    Readout(label: "Sensors", value: pw.map { "\($0.temperatures.count)" })
                    Spacer()
                }
                VFDMeter(fraction: pw.map { Double($0.thermalState + 1) / 4 }, segments: 4, height: 12)
                HistoryGraph(traces: [GraphTrace(name: "hot", values: e.series { $0.power.hottest.value }, color: p.accent)],
                             maxValue: 110, format: { String(format: "%.0f °C", $0) }).frame(height: 180)
            }
            Panel(title: "Sensors", trailing: "refreshed every \(Int(PowerSampler.sensorInterval)) s") {
                let temps = pw?.temperatures ?? []
                if temps.isEmpty { Text("No temperature sensors are exposed on this Mac.").foregroundStyle(p.dim) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 6) {
                    ForEach(temps) { t in
                        HStack {
                            Text(t.name).lineLimit(1).foregroundStyle(p.text)
                            Spacer()
                            VFDMeter(fraction: t.celsius / 110, segments: 12, height: 6).frame(width: 80)
                            Text(String(format: "%.1f °C", t.celsius)).frame(width: 64, alignment: .trailing)
                        }.font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }
}

struct GPUPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var body: some View {
        VStack(spacing: 12) {
            Panel(title: "GPU", trailing: SystemInfo.gpuInfo().first) {
                Readout(label: "Utilization", value: e.current?.gpu.value.map { String(format: "%.0f", $0) }, unit: "%")
                VFDMeter(fraction: e.current?.gpu.value.map { $0 / 100 }, segments: 40)
                HistoryGraph(traces: [GraphTrace(name: "g", values: e.series { $0.gpu.value }, color: p.accent)], maxValue: 100).frame(height: 220)
            }
        }
    }
}

/// Wi-Fi link, router and DNS, and (opt-in) latency / loss to the router and the internet.
struct ConnectionQualityPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @State private var route: (gateway: String, interface: String)?
    @State private var dns: [String] = []

    var body: some View {
        let s = e.current
        Panel(title: "Connection quality", trailing: route.map { "via \($0.interface)" }) {
            if let w = s?.wifi {
                HStack(spacing: 24) {
                    Readout(label: "Wi-Fi signal", value: w.quality, color: w.rssi < -75 ? p.warn : p.accent)
                    Readout(label: "RSSI", value: "\(w.rssi)", unit: "dBm")
                    Readout(label: "Noise", value: "\(w.noise)", unit: "dBm")
                    Readout(label: "SNR", value: "\(w.snr)", unit: "dB", color: w.snr < 20 ? p.warn : nil)
                    Readout(label: "Link rate", value: String(format: "%.0f", w.txRate), unit: "Mbps")
                    Spacer()
                }
                HistoryGraph(traces: [GraphTrace(name: "rssi", values: e.series { $0.wifi.map { Double($0.rssi + 100) } }, color: p.accent),
                                      GraphTrace(name: "noise", values: e.series { $0.wifi.map { Double($0.noise + 100) } }, color: p.accent2, fill: false)],
                             maxValue: 80, format: { String(format: "%.0f dBm", $0 - 100) }).frame(height: 90)
                Text([w.phy, w.band, w.width, w.channel.map { "channel \($0)" }, w.security, "network name: " + (w.ssid ?? "hidden by macOS (needs Location permission)")]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
            } else {
                Text("Not on Wi-Fi (or Wi-Fi is off).").foregroundStyle(p.dim)
            }
            Text("Router \(route?.gateway ?? "—") · DNS \(dns.isEmpty ? "—" : dns.joined(separator: ", "))")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim).textSelection(.enabled)
            Divider()
            if e.netProbeEnabled {
                let lat = s?.latency ?? []
                HStack(spacing: 24) {
                    ForEach(lat) { r in
                        Readout(label: "\(r.role) latency", value: r.avgMs.map { String(format: "%.0f", $0) }, unit: "ms",
                                color: (r.avgMs ?? 999) > (r.role == "Router" ? 50 : 150) ? p.warn : nil)
                        Readout(label: "Jitter", value: r.jitterMs.map { String(format: "%.1f", $0) }, unit: "ms")
                        Readout(label: "Loss", value: String(format: "%.0f", r.loss), unit: "%", color: r.loss >= 5 ? p.crit : nil)
                    }
                    if lat.isEmpty { Text("Measuring…").foregroundStyle(p.dim) }
                    Spacer()
                }
                HistoryGraph(traces: [
                    GraphTrace(name: "router", values: e.series { $0.latency?.first { $0.role == "Router" }?.avgMs }, color: p.accent),
                    GraphTrace(name: "internet", values: e.series { $0.latency?.first { $0.role == "Internet" }?.avgMs }, color: p.accent2, fill: false)],
                             minHeadroom: 20, format: { String(format: "%.0f ms", $0) }).frame(height: 90)
                Text("Pinging your router and \(e.netProbeHost) every 10 s (5 small packets each). Router trouble means Wi-Fi or local network; internet-only trouble means your provider.")
                    .font(.caption).foregroundStyle(p.dim)
            } else {
                HStack {
                    Text("Latency and packet-loss measurement is off. When on, Flightdeck pings your router and one internet host (\(e.netProbeHost)) every 10 seconds. Nothing else is sent.")
                        .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Turn On") { e.netProbeEnabled = true }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                let r = await Task.detached { (NetworkConfig.defaultRoute(), NetworkConfig.dnsServers()) }.value
                route = r.0; dns = r.1
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}
