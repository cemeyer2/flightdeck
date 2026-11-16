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
            DriveHealthPanel()
            Panel(title: "Capacity", trailing: e.diskFullDays.map { "startup disk full in ~\(max(Int($0.rounded()), 1)) days at the current rate" }) {
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
                        Readout(label: b.isCharging ? "Time to full" : "Time remaining",
                                value: b.isCharging && b.percent >= 99 ? "Charged" : b.timeRemaining.flatMap { $0 > 0 ? "\($0 / 60)h \($0 % 60)m" : nil })
                        Readout(label: "Health", value: b.health.map { String(format: "%.0f", $0) }, unit: "%")
                        Readout(label: "Cycles", value: b.cycleCount.map(String.init))
                        Readout(label: "Temp", value: b.temperature.map { String(format: "%.1f", $0) }, unit: "°C")
                        Readout(label: "Voltage", value: b.voltage.map { String(format: "%.2f", $0) }, unit: "V")
                        Spacer()
                    }
                    VFDMeter(fraction: b.percent / 100, segments: 40, color: b.percent < 20 ? p.crit : p.accent)
                }
            }
            EnergyBudgetPanel()
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
            if let fans = pw?.fans, !fans.isEmpty {
                Panel(title: "Fans", trailing: "from the SMC") {
                    HStack(spacing: 28) {
                        ForEach(fans) { f in
                            VStack(alignment: .leading, spacing: 4) {
                                Readout(label: "Fan \(f.index + 1)", value: String(format: "%.0f", f.rpm), unit: "RPM")
                                VFDMeter(fraction: f.fraction, segments: 20, height: 6).frame(width: 160)
                                Text([f.minRPM.map { String(format: "min %.0f", $0) }, f.maxRPM.map { String(format: "max %.0f", $0) },
                                      f.targetRPM.map { String(format: "target %.0f", $0) }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                            }
                        }
                        Spacer()
                    }
                    HistoryGraph(traces: fans.map { f in
                        GraphTrace(name: "fan\(f.index)", values: e.series { $0.power.fans?.first { $0.index == f.index }?.rpm },
                                   color: f.index == 0 ? p.accent : p.accent2, fill: f.index == 0) },
                                 minHeadroom: 2000, format: { String(format: "%.0f rpm", $0) }).frame(height: 110)
                }
            }
            Panel(title: "Sensor heatmap", trailing: "\(pw?.temperatures.count ?? 0) sensors · refreshed every \(Int(PowerSampler.sensorInterval)) s") {
                let temps = (pw?.temperatures ?? []).sorted { $0.celsius > $1.celsius }
                if temps.isEmpty { Text("No temperature sensors are exposed on this Mac.").foregroundStyle(p.dim) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                    ForEach(temps) { t in
                        let heat = min(max((t.celsius - 30) / 70, 0), 1)   // 30 °C cool … 100 °C hot
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.1f °C", t.celsius)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                            Text(t.name).font(.system(size: 9, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                        .foregroundStyle(heat > 0.55 ? Color.black : p.text)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(heatColor(heat)))
                        .help(t.name)
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

/// Which apps used the most energy over the last hours, from the black box.
struct EnergyBudgetPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @AppStorage("energyBudgetHours") private var hours = 8
    @State private var budget: EnergyBudget?
    @State private var loading = false

    var body: some View {
        Panel(title: "Energy budget", trailing: budget.map { "recorded \(shortDuration($0.span))" }) {
            HStack {
                Picker("", selection: $hours) { Text("1 hour").tag(1); Text("8 hours").tag(8); Text("24 hours").tag(24) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                if let b = budget {
                    if let wh = b.systemWattHours { Text(String(format: "System used %.1f Wh", wh)).foregroundStyle(p.dim) }
                    if b.onBattery > 60 {
                        Text("· \(shortDuration(b.onBattery)) on battery" + (b.batteryDropPercent.map { String(format: ", %.0f%% charge used", $0) } ?? ""))
                            .foregroundStyle(p.dim)
                    }
                }
            }.font(.system(size: 11, design: .monospaced))
            if !e.blackBoxEnabled {
                Text("Turn on the black box (Settings) to see energy use over time.").foregroundStyle(p.dim)
            } else if let b = budget {
                if b.apps.isEmpty { Text("No energy measurements recorded in this period yet.").foregroundStyle(p.dim) }
                let top = max(b.apps.first?.wattHours ?? 1, 0.001)
                ForEach(b.apps.prefix(10)) { a in
                    HStack(spacing: 8) {
                        AppIcon(path: a.iconPath.hasSuffix(".app") ? a.iconPath + "/" : a.iconPath).frame(width: 16, height: 16)
                        Text(a.name).lineLimit(1).frame(width: 200, alignment: .leading)
                        VFDMeter(fraction: a.wattHours / top, segments: 30, height: 6)
                        Text(String(format: "%.2f Wh", a.wattHours)).frame(width: 80, alignment: .trailing)
                        Text(String(format: "avg %.2f W", a.averageWatts)).foregroundStyle(p.dim).frame(width: 90, alignment: .trailing)
                    }.font(.system(size: 12, design: .monospaced))
                }
                if b.charge.count > 2 {
                    let step = max(b.charge.count / 240, 1)
                    HistoryGraph(traces: [GraphTrace(name: "charge", values: stride(from: 0, to: b.charge.count, by: step).map { Optional(b.charge[$0].1) }, color: p.accent)],
                                 maxValue: 100, format: { String(format: "%.0f%%", $0) }).frame(height: 70)
                    Text("Battery charge over the period").font(.caption).foregroundStyle(p.dim)
                }
                Text("Integrated from each process's measured energy (the busiest ~30 processes are recorded each sample), grouped by app.")
                    .font(.caption).foregroundStyle(p.dim)
            }
        }
        .task(id: hours) { await load() }
    }

    func load() async {
        loading = true; defer { loading = false }
        let box = e.blackBox, h = hours
        budget = await Task.detached(priority: .utility) { () -> EnergyBudget? in
            let from = Date().addingTimeInterval(-Double(h) * 3600)
            let tier: BlackBox.Tier = h <= 1 ? .fine : .coarse
            return box.trace(tier, from: from).map(EnergyBudget.compute)
        }.value
    }
}

struct DriveHealthPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var body: some View {
        let drives = e.current?.drives ?? []
        if !drives.isEmpty {
            Panel(title: "Drive health", trailing: "NVMe SMART · refreshed every 5 min") {
                ForEach(drives) { d in
                    HStack(spacing: 24) {
                        Readout(label: d.model, value: d.healthy ? "Healthy" : "Attention", color: d.healthy ? p.accent : p.crit)
                        Readout(label: "Wear", value: "\(d.percentUsed)", unit: "%", color: d.percentUsed >= 80 ? p.warn : nil)
                        Readout(label: "Spare", value: "\(d.availableSpare)", unit: "%")
                        Readout(label: "Written", value: Fmt.bytes(d.bytesWritten))
                        Readout(label: "Read", value: Fmt.bytes(d.bytesRead))
                        Readout(label: "Power-on", value: "\(d.powerOnHours)", unit: "h")
                        Readout(label: "Temp", value: String(format: "%.0f", d.temperature), unit: "°C")
                        Spacer()
                    }
                    VFDMeter(fraction: Double(min(d.percentUsed, 100)) / 100, segments: 50, height: 6)
                    Text("\(d.powerCycles) power cycles · \(d.unsafeShutdowns) unsafe shutdowns · \(d.mediaErrors) media errors · \(d.errorLogEntries) error-log entries"
                         + (d.warnings.isEmpty ? "" : " · " + d.warnings.joined(separator: ", ")))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(d.warnings.isEmpty ? p.dim : p.crit)
                    Text("Wear is the drive's own estimate of its rated write endurance used; 100% is not a failure date, but plan a backup and replacement well before it.")
                        .font(.caption).foregroundStyle(p.dim)
                }
            }
        }
    }
}

/// Cool blue → amber → red for the heatmap; monochrome themes use the accent at varying strength.
func heatColor(_ f: Double) -> Color {
    let stops: [(Double, (Double, Double, Double))] = [(0, (0.12, 0.25, 0.45)), (0.45, (0.20, 0.55, 0.65)), (0.7, (0.95, 0.70, 0.20)), (1, (0.95, 0.25, 0.20))]
    var lo = stops[0], hi = stops[stops.count - 1]
    for i in 1..<stops.count where f <= stops[i].0 { lo = stops[i - 1]; hi = stops[i]; break }
    let t = hi.0 > lo.0 ? (f - lo.0) / (hi.0 - lo.0) : 0
    return Color(red: lo.1.0 + (hi.1.0 - lo.1.0) * t, green: lo.1.1 + (hi.1.1 - lo.1.1) * t, blue: lo.1.2 + (hi.1.2 - lo.1.2) * t)
}
