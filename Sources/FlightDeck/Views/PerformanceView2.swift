import SwiftUI
import FlightDeckCore
// Performance tabs Disk, Network, Energy, Thermals and GPU (CPU and Memory are in PerformanceView.swift), plus the
// panels they embed: ConnectionQualityPanel, EnergyBudgetPanel (black box), DriveHealthPanel, ProcessMiniList and
// GPUAppRow. Like the other tabs they read `e.current` and `e.series`, so they also work during replay.

/// Disk tab: system-wide read/write rates (bytes/s), optional per-device graphs, NVMe health, volume capacity with the
/// Engine's "disk full in N days" forecast, and the processes doing the most disk I/O.
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
                            // Devices are matched by name in every frame; a frame without that device gives a gap.
                            GraphTrace(name: "r", values: e.series { s in s.disk.devices.first { $0.name == dev.name }?.readBps }, color: p.accent),
                            GraphTrace(name: "w", values: e.series { s in s.disk.devices.first { $0.name == dev.name }?.writeBps }, color: p.accent2)],
                                     minHeadroom: 1_048_576, format: Fmt.rate).frame(height: 120)
                    }
                }
            }
            DriveHealthPanel()
            // `diskFullDays` is nil unless the startup disk has a clear shrinking trend, which hides the forecast.
            Panel(title: "Capacity", trailing: e.diskFullDays.map { "startup disk full in ~\(max(Int($0.rounded()), 1)) days at the current rate" }) {
                ForEach(d?.volumes ?? []) { v in VolumeRow(v: v) }
            }
            Panel(title: "Top disk processes") {
                ProcessMiniList(metric: { $0.diskReadBps + $0.diskWriteBps }, format: Fmt.rate)
            }
        }
    }
}

/// One mounted volume: name, file system, used/capacity/free and a usage meter.
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

/// Top `count` processes by `metric` with a meter relative to the busiest. Restricted processes (other users' without
/// root) are left out, since their counters can't be read and would rank as 0.
struct ProcessMiniList: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var metric: (ProcessSample) -> Double
    /// Which processes have the metric at all (e.g. energy is only reported for some); others are left out, not shown as 0.
    var include: (ProcessSample) -> Bool = { _ in true }
    var format: (Double) -> String
    var count = 6
    var body: some View {
        let procs = (e.current?.processes ?? []).filter { !$0.restricted && include($0) }.sorted { metric($0) > metric($1) }.prefix(count)
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

/// Network tab: connection quality, total bandwidth (bits/s readouts; bytes/s graph scale), per-app traffic and
/// interfaces. Totals are interface counters since boot, unlike AppNetworkPanel's "since FlightDeck started".
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
                // Hide idle virtual interfaces (no traffic, no address), of which macOS has many (utun, awdl, bridge…).
                let ifs = (n?.interfaces ?? []).filter { $0.totalIn + $0.totalOut > 0 || !$0.addresses.isEmpty }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { ForEach(["Name", "Status", "Link", "↓ now", "↑ now", "↓ total", "↑ total", "Address", "MAC"], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                    ForEach(ifs) { i in
                        GridRow {
                            Text(i.name); Text(i.isUp ? "up" : "down").foregroundStyle(i.isUp ? p.accent : p.dim)
                            // Link speed is reported in bits/s; Fmt.bits expects bytes/s, hence the division.
                            Text(i.linkSpeed > 0 ? Fmt.bits(Double(i.linkSpeed) / 8) : "—")
                            Text(Fmt.rate(i.inBps)); Text(Fmt.rate(i.outBps))
                            Text(Fmt.bytes(i.totalIn)); Text(Fmt.bytes(i.totalOut))
                            // Prefer an IPv4 address for display; fall back to the first (IPv6) one.
                            Text(i.addresses.first { !$0.contains(":") } ?? i.addresses.first ?? "—").textSelection(.enabled)
                            Text(i.mac ?? "—").foregroundStyle(p.dim)
                        }.font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
    }
}

/// Energy tab: system power draw and battery flow (W), battery state and health, the black-box energy budget, and
/// the processes with the highest measured energy.
struct EnergyPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var body: some View {
        let pw = e.current?.power
        VStack(spacing: 12) {
            Panel(title: "Power", trailing: pw?.powerSource) {
                HStack(spacing: 28) {
                    Readout(label: "System draw", value: pw?.systemWatts.value.map { String(format: "%.2f", $0) }, unit: "W", color: p.accent)
                    // Battery flow is signed (+ charging, - discharging); the graph below plots its magnitude so both directions
                    // share the system-draw scale.
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
                                // `timeRemaining` is in minutes and nil while macOS is still estimating; 0 is treated the same way.
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
            ChargeDrainPanel()   // per-app shares since unplugged (daily log)
            Panel(title: "Top energy processes (measured energy)") {
                // Processes without an energy reading count as 0 W for ranking only.
                ProcessMiniList(metric: { $0.energyWatts ?? 0 }, include: { $0.energyWatts != nil }, format: { String(format: "%.2f W", $0) }, count: 10)
            }
        }
    }
}

/// Thermals tab: macOS thermal pressure state, the hottest sensor, fan speeds from the SMC, and a heatmap of every
/// temperature sensor (read via IOHIDEventSystemClient, which is slow, so refreshed only every `PowerSampler.sensorInterval` s).
struct ThermalPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var body: some View {
        let pw = e.current?.power
        VStack(spacing: 12) {
            // Only present when there is something to explain (fans above idle, or heat holding performance back).
            if let s = e.current, let why = FanExplainer.explain(s) { FanExplainerCard(explanation: why) }
            Panel(title: "Thermal pressure") {
                HStack(spacing: 28) {
                    Readout(label: "State", value: pw.map { thermalName($0.thermalState) }, color: (pw?.thermalState ?? 0) >= 2 ? p.crit : p.accent)
                    Readout(label: "Hotspot", value: pw?.hottest.value.map { String(format: "%.1f", $0) }, unit: "°C")
                    Readout(label: "Sensors", value: pw.map { "\($0.temperatures.count)" })
                    Spacer()
                }
                // Four-segment meter for thermal state 0–3 (nominal, fair, serious, critical); nominal lights one segment.
                VFDMeter(fraction: pw.map { Double($0.thermalState + 1) / 4 }, segments: 4, height: 12)
                HistoryGraph(traces: [GraphTrace(name: "hot", values: e.series { $0.power.hottest.value }, color: p.accent)],
                             maxValue: 110, format: { String(format: "%.0f °C", $0) }).frame(height: 180)
            }
            // Fanless Macs (e.g. MacBook Air) report no fans, so the panel is omitted rather than showing 0 RPM.
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

/// GPU tab: device/renderer/tiler utilisation, clocks, power and memory, P-state residency, per-app GPU time, CPU
/// cluster clocks and Metal device facts. Live detail comes from `Snapshot.gpuDetail` (IOAccelerator statistics plus
/// IOReport on Apple silicon); every field is optional and shows "—" where this Mac doesn't report it.
struct GPUPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    // Static facts about the GPU and its Metal device, gathered once on first use and never refreshed.
    static let info = GPUSampler.info()
    static let metal = MetalInfo.collect()

    var body: some View {
        let g = e.current?.gpuDetail
        let info = Self.info
        VStack(spacing: 12) {
            Panel(title: info.model, trailing: [info.cores.map { "\($0) GPU cores" }, info.frequencyRange.map { String(format: "%.0f–%.0f MHz", $0.min, $0.max) }].compactMap { $0 }.joined(separator: " · ")) {
                HStack(spacing: 24) {
                    // Some Macs only expose the coarse snapshot-level GPU utilisation, used as a fallback.
                    Readout(label: "Utilization", value: (g?.deviceUtilization ?? e.current?.gpu.value).map { String(format: "%.0f", $0) }, unit: "%", color: p.accent)
                    Readout(label: "Active", value: g?.activeResidency.map { String(format: "%.0f", $0) }, unit: "%")
                    Readout(label: "Frequency", value: g?.frequencyMHz.map { String(format: "%.0f", $0) }, unit: "MHz")
                    Readout(label: "Power", value: g?.powerWatts.map { String(format: "%.2f", $0) }, unit: "W", color: p.accent2)
                    Readout(label: "Memory in use", value: g?.memoryInUse.map { Fmt.bytes($0) })
                    Readout(label: "Recoveries", value: g?.recoveryCount.map(String.init), color: (g?.recoveryCount ?? 0) > 0 ? p.crit : nil)
                    Spacer()
                }
                HStack(spacing: 18) {
                    MiniGauge(label: "RENDERER", value: g?.rendererUtilization.map { $0 / 100 }, text: g?.rendererUtilization.map { String(format: "%.0f%%", $0) })
                    MiniGauge(label: "TILER", value: g?.tilerUtilization.map { $0 / 100 }, text: g?.tilerUtilization.map { String(format: "%.0f%%", $0) })
                    MiniGauge(label: "THERMAL CAP", value: g?.thermalLimited.map { $0 / 100 }, text: g?.thermalLimited.map { String(format: "%.0f%%", $0) })
                    // Fraction of Metal's recommended working-set size, the practical ceiling for GPU memory.
                    MiniGauge(label: "MEMORY", value: g?.memoryInUse.map { Double($0) / Double(max(Self.metal.workingSet ?? 1, 1)) },
                              text: Self.metal.workingSet.map { "of " + Fmt.bytes($0) })
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                Panel(title: "Utilization", trailing: "device · renderer") {
                    HistoryGraph(traces: [GraphTrace(name: "dev", values: e.series { $0.gpuDetail?.deviceUtilization ?? $0.gpu.value }, color: p.accent),
                                          GraphTrace(name: "ren", values: e.series { $0.gpuDetail?.rendererUtilization }, color: p.accent2, fill: false)],
                                 maxValue: 100, format: { String(format: "%.0f%%", $0) }).frame(height: 120)
                }
                Panel(title: "Frequency", trailing: "average while active") {
                    HistoryGraph(traces: [GraphTrace(name: "mhz", values: e.series { $0.gpuDetail?.frequencyMHz }, color: p.accent)],
                                 maxValue: info.frequencyRange?.max, minHeadroom: 100, format: { String(format: "%.0f MHz", $0) }).frame(height: 120)
                }
                Panel(title: "Power", trailing: "GPU energy (IOReport)") {
                    HistoryGraph(traces: [GraphTrace(name: "w", values: e.series { $0.gpuDetail?.powerWatts }, color: p.accent2)],
                                 minHeadroom: 2, format: { String(format: "%.1f W", $0) }).frame(height: 120)
                }
                Panel(title: "Memory", trailing: "in use by the GPU driver") {
                    HistoryGraph(traces: [GraphTrace(name: "m", values: e.series { $0.gpuDetail?.memoryInUse.map { Double($0) } }, color: p.accent)],
                                 minHeadroom: 268_435_456, format: Fmt.bytes).frame(height: 120)
                }
            }
            Panel(title: "Performance states", trailing: "share of the last sample spent at each clock") {
                // Bar heights are percentages drawn 1 pt per %, with a 1 pt minimum so empty states stay visible. The
                // first bar is time powered off (100% minus active residency); the rest are the DVFS states, labelled
                // with their MHz when known.
                if let r = g?.stateResidency, !r.isEmpty {
                    HStack(alignment: .bottom, spacing: 6) {
                        VStack(spacing: 3) {
                            Text(g?.activeResidency.map { String(format: "%.0f%%", 100 - $0) } ?? "—").font(.system(size: 10, design: .monospaced))
                            RoundedRectangle(cornerRadius: 2).fill(p.meterOff).frame(width: 34, height: max(CGFloat(100 - (g?.activeResidency ?? 100)) * 1.0, 1))
                            Text("off").font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim)
                        }
                        ForEach(Array(r.enumerated()), id: \.offset) { i, v in
                            VStack(spacing: 3) {
                                Text(String(format: "%.0f%%", v)).font(.system(size: 10, design: .monospaced))
                                RoundedRectangle(cornerRadius: 2).fill(p.accent.opacity(0.35 + 0.65 * Double(i + 1) / Double(r.count)))
                                    .frame(width: 34, height: max(CGFloat(v) * 1.0, 1))
                                Text(g?.stateMHz.flatMap { i < $0.count ? String(format: "%.0f", $0[i]) : nil } ?? "P\(i + 1)")
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim)
                            }
                        }
                        Spacer()
                    }.frame(height: 140, alignment: .bottom)
                    Text("Bars are labelled in MHz. Time at the lowest clocks is normal for light work; the GPU raises its clock under load and lowers it when hot (see Thermal cap).")
                        .font(.caption).foregroundStyle(p.dim)
                } else {
                    Text("Per-state residency isn't available on this Mac (needs Apple silicon IOReport GPU statistics).").foregroundStyle(p.dim)
                }
            }
            Panel(title: "GPU apps", trailing: "share of GPU time · total GPU time since each app started") {
                // Per-app share of GPU time (from the sampler) joined with IOAccelerator client records for cumulative
                // GPU time and the graphics APIs each process uses.
                let apps = AppUsage.aggregate(e.current?.processes ?? []).filter { $0.gpu != nil }.sorted { ($0.gpu ?? 0) > ($1.gpu ?? 0) }
                let clients = g?.clients ?? []
                if apps.isEmpty && clients.isEmpty { Text("No process is using the GPU right now (or per-process GPU time isn't exposed).").foregroundStyle(p.dim) }
                ForEach(apps.prefix(12)) { a in GPUAppRow(app: a, clients: clients) }
            }
            if let cl = g?.cpuClusters, !cl.isEmpty {
                Panel(title: "CPU clusters", trailing: "live clocks (IOReport)") {
                    HStack(spacing: 28) {
                        ForEach(cl) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                Readout(label: c.name, value: c.mhz.map { String(format: "%.0f", $0) }, unit: "MHz")
                                VFDMeter(fraction: c.mhz.map { $0 / max(c.maxMHz, 1) }, segments: 16, color: c.name.hasPrefix("E") ? p.eCore : p.pCore, height: 5).frame(width: 140)
                                Text(String(format: "active %.0f%% · max %.0f MHz", c.active, c.maxMHz)).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                            }
                        }
                        Spacer()
                    }
                }
            }
            Panel(title: "Device", trailing: "Metal") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(Self.metal.rows, id: \.0) { k, v in
                        GridRow { Text(k).foregroundStyle(p.dim); Text(v).foregroundStyle(p.text).textSelection(.enabled) }
                    }
                }.font(.system(size: 12, design: .monospaced))
            }
        }
    }
}

/// Wi-Fi link, router and DNS, and (opt-in) latency / loss to the router and the internet.
/// Data: `e.current.wifi` (CoreWLAN) and `e.current.latency` (pings, only when the user enables the probe in Settings;
/// off by default for privacy). The default route and DNS servers are re-read every 15 s on a detached task while the
/// panel is visible.
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
                    // Below -75 dBm RSSI or 20 dB SNR the link is usually unreliable, so those are highlighted.
                    Readout(label: "Wi-Fi signal", value: w.quality, color: w.rssi < -75 ? p.warn : p.accent)
                    Readout(label: "RSSI", value: "\(w.rssi)", unit: "dBm")
                    Readout(label: "Noise", value: "\(w.noise)", unit: "dBm")
                    Readout(label: "SNR", value: "\(w.snr)", unit: "dB", color: w.snr < 20 ? p.warn : nil)
                    Readout(label: "Link rate", value: String(format: "%.0f", w.txRate), unit: "Mbps")
                    Spacer()
                }
                // dBm values are negative; shifted by +100 so the graph's 0-based fill works (0…80 = -100…-20 dBm).
                HistoryGraph(traces: [GraphTrace(name: "rssi", values: e.series { $0.wifi.map { Double($0.rssi + 100) } }, color: p.accent),
                                      GraphTrace(name: "noise", values: e.series { $0.wifi.map { Double($0.noise + 100) } }, color: p.accent2, fill: false)],
                             maxValue: 80, format: { String(format: "%.0f dBm", $0 - 100) }).frame(height: 90)
                // macOS hides the SSID unless the app has Location permission, so say so instead of showing nothing.
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
                        // Warn above 50 ms to the router or 150 ms to the internet; a missing average also warns.
                        Readout(label: "\(r.role) latency", value: r.avgMs.map { String(format: "%.0f", $0) }, unit: "ms",
                                color: r.avgMs.map { $0 > (r.role == "Router" ? 50 : 150) } == true ? p.warn : nil)
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
                    Text("Latency and packet-loss measurement is off. When on, FlightDeck pings your router and one internet host (\(e.netProbeHost)) every 10 seconds. Nothing else is sent.")
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
/// Loaded once per chosen period (and when the panel appears) on a detached utility task: the 1 hour view uses the fine
/// black-box tier, longer periods the 10 s coarse tier. It doesn't refresh while open.
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
                // Bars are relative to the top app; the floor avoids dividing by zero when every app used ~0 Wh.
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
                if let u = b.unattributedWattHours, u > 0.01 {
                    // Energy the recorded apps don't explain: display, quieter processes, macOS itself.
                    HStack(spacing: 8) {
                        Image(systemName: "display").frame(width: 16, height: 16).foregroundStyle(p.dim)
                        Text("Display, system and others").lineLimit(1).frame(width: 200, alignment: .leading).foregroundStyle(p.dim)
                        VFDMeter(fraction: u / top, segments: 30, color: p.dim, height: 6)
                        Text(String(format: "%.2f Wh", u)).frame(width: 80, alignment: .trailing).foregroundStyle(p.dim)
                        Text("").frame(width: 90)
                    }.font(.system(size: 12, design: .monospaced))
                }
                if b.charge.count > 2 {
                    // Bucketed by time (240 slices), so periods with no recording (sleep) show as gaps.
                    HistoryGraph(traces: [GraphTrace(name: "charge", values: timeBuckets(b.charge, buckets: 240), color: p.accent)],
                                 maxValue: 100, format: { String(format: "%.0f%%", $0) }).frame(height: 70)
                    Text("Battery charge over the period").font(.caption).foregroundStyle(p.dim)
                }
                Text("Integrated from each process's measured energy (the busiest ~30 processes are recorded each sample), grouped by app.")
                    .font(.caption).foregroundStyle(p.dim)
            }
        }
        // Reload every minute while the panel is visible, so the budget keeps up with the black box.
        .task(id: hours) { while !Task.isCancelled { await load(); try? await Task.sleep(for: .seconds(60)) } }
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

/// NVMe SMART data per internal drive from `e.current.drives` (read by the sampler at most every 5 minutes). Hidden
/// entirely when no drive reports SMART data (e.g. external or non-NVMe disks).
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

/// Heatmap colour for a 0…1 heat fraction: cool blue → teal → amber → red, linearly interpolated between fixed stops.
/// The same colours are used in every theme.
func heatColor(_ f: Double) -> Color {
    let stops: [(Double, (Double, Double, Double))] = [(0, (0.12, 0.25, 0.45)), (0.45, (0.20, 0.55, 0.65)), (0.7, (0.95, 0.70, 0.20)), (1, (0.95, 0.25, 0.20))]
    var lo = stops[0], hi = stops[stops.count - 1]
    for i in 1..<stops.count where f <= stops[i].0 { lo = stops[i - 1]; hi = stops[i]; break }
    let t = hi.0 > lo.0 ? (f - lo.0) / (hi.0 - lo.0) : 0
    return Color(red: lo.1.0 + (hi.1.0 - lo.1.0) * t, green: lo.1.1 + (hi.1.1 - lo.1.1) * t, blue: lo.1.2 + (hi.1.2 - lo.1.2) * t)
}

/// One app in the GPU apps list: share of GPU time now (%), cumulative GPU time summed over its processes'
/// IOAccelerator clients, and which graphics APIs (Metal, OpenGL…) they use.
struct GPUAppRow: View {
    @Environment(\.palette) var p
    var app: AppUsage
    var clients: [GPUClient]
    var members: [GPUClient] {
        let pids = Set(app.pids)
        return clients.filter { pids.contains($0.pid) }
    }
    var body: some View {
        let m = members
        let total: Double = m.reduce(0) { $0 + $1.totalSeconds }
        let apis: String = Set(m.flatMap(\.apis)).sorted().joined(separator: ", ")
        HStack(spacing: 8) {
            AppIcon(path: app.iconPath.hasSuffix(".app") ? app.iconPath + "/" : app.iconPath).frame(width: 16, height: 16)
            Text(app.name).lineLimit(1).frame(width: 200, alignment: .leading)
            VFDMeter(fraction: (app.gpu ?? 0) / 100, segments: 30, height: 6)
            Text(String(format: "%.1f%%", app.gpu ?? 0)).frame(width: 60, alignment: .trailing)
            Text(Fmt.duration(total)).foregroundStyle(p.dim).frame(width: 90, alignment: .trailing)
            Text(apis).foregroundStyle(p.dim).frame(width: 70, alignment: .leading)
        }.font(.system(size: 12, design: .monospaced))
    }
}

/// "Why is the fan loud?": the explanation from `FanExplainer` (all logic is in core), a headline and supporting lines.
struct FanExplainerCard: View {
    @Environment(\.palette) var p
    let explanation: FanExplanation
    var body: some View {
        let x = explanation
        let color = x.severity == .warning ? p.crit : x.severity == .caution ? p.warn : p.accent
        Panel(title: x.hasFans ? "Why is the fan loud?" : "Why is it slowing down?") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: x.hasFans ? "fan" : "thermometer.high").font(.system(size: 20)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 6) {
                    Text(x.headline).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(x.details, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
