import SwiftUI
import FlightdeckCore

enum PerfTab: String, CaseIterable, Identifiable { case cpu = "CPU", memory = "Memory", disk = "Disk", network = "Network", energy = "Energy", thermals = "Thermals", gpu = "GPU"; var id: String { rawValue } }

struct PerformanceView: View {
    @SceneStorage("perfTab") var tab: PerfTab = .cpu
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(PerfTab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(12).frame(maxWidth: 640)
            ScrollView {
                Group {
                    switch tab {
                    case .cpu: CPUPerf()
                    case .memory: MemoryPerf()
                    case .disk: DiskPerf()
                    case .network: NetworkPerf()
                    case .energy: EnergyPerf()
                    case .thermals: ThermalPerf()
                    case .gpu: GPUPerf()
                    }
                }.padding([.horizontal, .bottom], 16)
            }
        }
        .onAppear {   // automation hook: -perfTab Network
            if let t = UserDefaults.standard.string(forKey: "perfTab").flatMap(PerfTab.init(rawValue:)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { tab = t }
            }
        }
    }
}

// MARK: CPU
enum CPUMode: String, CaseIterable, Identifiable { case overall = "Overall", logical = "Logical Processors", clusters = "Clusters"; var id: String { rawValue } }

struct CPUPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @AppStorage("cpuMode") var mode: CPUMode = .logical

    var body: some View {
        let s = e.current?.cpu
        VStack(spacing: 12) {
            Panel(title: "Processor", trailing: Sysctl.string("machdep.cpu.brand_string")) {
                HStack(spacing: 28) {
                    Readout(label: "Utilization", value: s?.total.value.map { String(format: "%.1f", $0) }, unit: "%")
                    Readout(label: "User", value: s?.user.value.map { String(format: "%.1f", $0) }, unit: "%", color: p.accent)
                    Readout(label: "System", value: s?.system.value.map { String(format: "%.1f", $0) }, unit: "%", color: p.accent2)
                    Readout(label: "Load avg (1/5/15)", value: s.map { String(format: "%.2f  %.2f  %.2f", $0.loadAverage[0], $0.loadAverage[1], $0.loadAverage[2]) })
                    Readout(label: "Processes", value: e.current.map { "\($0.processes.count)" })
                    Readout(label: "Threads", value: e.current.map { "\($0.processes.reduce(0) { $0 + $1.threads })" })
                    Spacer()
                }
                Picker("", selection: $mode) { ForEach(CPUMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 380)
            }
            switch mode {
            case .overall:
                Panel(title: "History") {
                    HistoryGraph(traces: [GraphTrace(name: "user", values: e.series { $0.cpu.user.value }, color: p.accent),
                                          GraphTrace(name: "system", values: e.series { $0.cpu.system.value }, color: p.accent2)], maxValue: 100).frame(height: 260)
                    Legend(items: [("User", p.accent, s?.user.value.map(Fmt.pct) ?? "—"), ("System", p.accent2, s?.system.value.map(Fmt.pct) ?? "—")])
                }
            case .logical:
                let n = s?.cores.count ?? e.current.map { _ in 0 } ?? 0
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(0..<n, id: \.self) { i in CoreTile(index: i) }
                }
                CoreLegend()
            case .clusters:
                ForEach([CoreKind.efficiency, .performance], id: \.self) { kind in
                    let idx = (s?.cores ?? []).filter { $0.kind == kind }.map(\.index)
                    if !idx.isEmpty {
                        let avg: (Snapshot) -> Double? = { snap in
                            let v = idx.compactMap { $0 < snap.cpu.cores.count ? snap.cpu.cores[$0].total : nil }
                            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
                        }
                        let prefix = kind == .performance ? "P" : "E"
                        let mhz: (Snapshot) -> Double? = { snap in
                            snap.gpuDetail?.cpuClusters.filter { $0.name.hasPrefix(prefix) }.compactMap(\.mhz).max()
                        }
                        Panel(title: kind == .performance ? "Performance cores (\(idx.count))" : "Efficiency cores (\(idx.count))",
                              trailing: [e.current.flatMap(avg).map(Fmt.pct), e.current.flatMap(mhz).map { String(format: "%.0f MHz", $0) }]
                                .compactMap { $0 }.joined(separator: " · ")) {
                            VFDMeter(fraction: e.current.flatMap(avg).map { $0 / 100 }, segments: 40, color: kind == .performance ? p.pCore : p.eCore)
                            HistoryGraph(traces: [GraphTrace(name: kind.rawValue, values: e.series(avg), color: kind == .performance ? p.pCore : p.eCore)], maxValue: 100).frame(height: 160)
                            if e.series(mhz).contains(where: { $0 != nil }) {
                                let top = (e.current?.gpuDetail?.cpuClusters.first { $0.name.hasPrefix(prefix) }?.maxMHz) ?? 0
                                HistoryGraph(traces: [GraphTrace(name: "mhz", values: e.series(mhz), color: p.accent2, fill: false)],
                                             maxValue: top > 0 ? top : nil, minHeadroom: 500, format: { String(format: "%.0f MHz", $0) }).frame(height: 70)
                                Text("Clock (average while active)").font(.caption).foregroundStyle(p.dim)
                            }
                        }
                    }
                }
                if (s?.cores ?? []).allSatisfy({ $0.kind == .unknown }) {
                    Text("This Mac has a single core type; cluster view is unavailable.").foregroundStyle(p.dim)
                }
            }
        }
    }
}

struct CoreTile: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var index: Int
    var body: some View {
        let core = e.current.flatMap { index < $0.cpu.cores.count ? $0.cpu.cores[index] : nil }
        let kind = e.cpuKind(index)
        let c = kind == .efficiency ? p.eCore : p.pCore
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("CPU \(index)").font(.meterLabel).foregroundStyle(p.dim)
                Text(kind == .efficiency ? "E" : kind == .performance ? "P" : "").font(.meterLabel).foregroundStyle(c)
                Spacer()
                Text(core.map { Fmt.pct($0.total) } ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(p.text)
            }
            VFDMeter(fraction: core.map { $0.total / 100 }, segments: 20, color: c, height: 6)
            HistoryGraph(traces: [GraphTrace(name: "c", values: e.series { index < $0.cpu.cores.count ? $0.cpu.cores[index].total : nil }, color: c)],
                         maxValue: 100, showGrid: false).frame(height: 54)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(c.opacity(0.25)))
    }
}

struct CoreLegend: View {
    @Environment(\.palette) var p
    var body: some View {
        HStack(spacing: 16) {
            Label("Performance core", systemImage: "square.fill").foregroundStyle(p.pCore)
            Label("Efficiency core", systemImage: "square.fill").foregroundStyle(p.eCore)
            Spacer()
        }.font(.system(size: 11, design: .monospaced))
    }
}

// MARK: Memory
struct MemoryPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var body: some View {
        let m = e.current?.memory
        VStack(spacing: 12) {
            Panel(title: "Memory", trailing: m.map { Fmt.bytes($0.total) + " installed" }) {
                HStack(spacing: 28) {
                    Readout(label: "Used", value: m.map { Fmt.bytes($0.used) })
                    Readout(label: "App", value: m.map { Fmt.bytes($0.app) })
                    Readout(label: "Wired", value: m.map { Fmt.bytes($0.wired) })
                    Readout(label: "Compressed", value: m.map { Fmt.bytes($0.compressed) })
                    Readout(label: "Cached files", value: m.map { Fmt.bytes($0.cached) })
                    Readout(label: "Free", value: m.map { Fmt.bytes($0.free) })
                    Spacer()
                }
                if let m { CompositionBar(m: m) }
            }
            HStack(spacing: 12) {
                Panel(title: "Pressure", trailing: m.map { ["", "Normal", "Warning", "", "Critical"][min($0.pressureLevel, 4)] }) {
                    VFDMeter(fraction: m?.pressure.value.map { $0 / 100 }, segments: 30)
                    HistoryGraph(traces: [GraphTrace(name: "p", values: e.series { $0.memory.pressure.value }, color: p.accent)], maxValue: 100).frame(height: 150)
                }
                Panel(title: "Swap", trailing: m?.swapUsed.value.map { Fmt.bytes($0) + " of " + (m?.swapTotal.value.map(Fmt.bytes) ?? "—") }) {
                    HistoryGraph(traces: [GraphTrace(name: "s", values: e.series { $0.memory.swapUsed.value }, color: p.accent2)], minHeadroom: 1_073_741_824, format: Fmt.bytes).frame(height: 172)
                }
            }
            Panel(title: "Composition trend") {
                HistoryGraph(traces: [
                    GraphTrace(name: "used", values: e.series { Double($0.memory.used) }, color: p.accent),
                    GraphTrace(name: "compressed", values: e.series { Double($0.memory.compressed) }, color: p.accent2, fill: false),
                    GraphTrace(name: "wired", values: e.series { Double($0.memory.wired) }, color: p.eCore, fill: false),
                ], maxValue: m.map { Double($0.total) }, format: Fmt.bytes).frame(height: 160)
                Legend(items: [("Used", p.accent, m.map { Fmt.bytes($0.used) } ?? "—"), ("Compressed", p.accent2, m.map { Fmt.bytes($0.compressed) } ?? "—"), ("Wired", p.eCore, m.map { Fmt.bytes($0.wired) } ?? "—")])
            }
            Panel(title: "Paging and swap", trailing: "per second") {
                let swapOut = e.rateSeries { s in s.memory.swapOuts.flatMap { v in s.memory.pageSize.map { Double(v * $0) } } }
                let swapIn = e.rateSeries { s in s.memory.swapIns.flatMap { v in s.memory.pageSize.map { Double(v * $0) } } }
                let comp = e.rateSeries { s in s.memory.pageSize.map { Double(s.memory.compressions * $0) } }
                HStack(spacing: 28) {
                    Readout(label: "Swap out", value: (swapOut.last ?? nil).map(Fmt.rate), color: (swapOut.last ?? nil).map { $0 > 20e6 ? p.crit : p.accent } ?? p.accent)
                    Readout(label: "Swap in", value: (swapIn.last ?? nil).map(Fmt.rate), color: p.accent2)
                    Readout(label: "Compressing", value: (comp.last ?? nil).map(Fmt.rate))
                    Spacer()
                }
                HistoryGraph(traces: [GraphTrace(name: "out", values: swapOut, color: p.accent), GraphTrace(name: "in", values: swapIn, color: p.accent2, fill: false),
                                      GraphTrace(name: "comp", values: comp, color: p.eCore, fill: false)], minHeadroom: 1_048_576, format: Fmt.rate).frame(height: 110)
                Text("Swap traffic is the clearest sign memory is short: macOS is writing memory to disk and reading it back. Compression is cheaper and normal.")
                    .font(.caption).foregroundStyle(p.dim)
            }
            Panel(title: "Memory by app", trailing: "helpers grouped into their app") {
                let total = Double(max(m?.total ?? 1, 1))
                ForEach(AppUsage.aggregate(e.current?.processes ?? []).sorted { $0.memory > $1.memory }.prefix(12)) { a in
                    HStack(spacing: 8) {
                        AppIcon(path: a.iconPath.hasSuffix(".app") ? a.iconPath + "/" : a.iconPath).frame(width: 16, height: 16)
                        Text(a.name).lineLimit(1).frame(width: 220, alignment: .leading)
                        VFDMeter(fraction: Double(a.memory) / total, segments: 40, height: 6)
                        Text(Fmt.bytes(a.memory)).frame(width: 80, alignment: .trailing)
                        Text(String(format: "%.1f%%", Double(a.memory) / total * 100)).foregroundStyle(p.dim).frame(width: 50, alignment: .trailing)
                        Text("\(a.processes)").foregroundStyle(p.dim).frame(width: 34, alignment: .trailing)
                    }.font(.system(size: 12, design: .monospaced))
                }
            }
            Panel(title: "Paging (since boot)") {
                HStack(spacing: 28) {
                    Readout(label: "Page ins", value: m.map { "\($0.pageIns)" }, size: 16)
                    Readout(label: "Page outs", value: m.map { "\($0.pageOuts)" }, size: 16)
                    Readout(label: "Compressions", value: m.map { "\($0.compressions)" }, size: 16)
                    Readout(label: "Decompressions", value: m.map { "\($0.decompressions)" }, size: 16)
                    Spacer()
                }
            }
        }
    }
}

struct CompositionBar: View {
    @Environment(\.palette) var p
    var m: MemorySample
    var body: some View {
        let total = Double(max(m.total, 1))
        let parts: [(String, Double, Color)] = [("App", Double(m.app), p.accent), ("Wired", Double(m.wired), p.eCore),
                                                ("Compressed", Double(m.compressed), p.accent2), ("Cached", Double(m.cached), p.dim.opacity(0.6))]
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(parts, id: \.0) { part in
                    Rectangle().fill(part.2).frame(width: max(0, g.size.width * part.1 / total)).help("\(part.0): \(Fmt.bytes(part.1))")
                }
                Rectangle().fill(p.meterOff)
            }
        }
        .frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
