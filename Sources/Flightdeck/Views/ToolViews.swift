import SwiftUI
import FlightdeckCore

struct PowerView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @StateObject var freq = Loader { Frequency.clusters() }
    @StateObject var pm = Loader { Frequency.pmsetSettings().map { "\($0.0)\t\($0.1)" } }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                let pw = e.current?.power
                Panel(title: "Power state") {
                    HStack(spacing: 28) {
                        Readout(label: "Source", value: pw?.powerSource)
                        Readout(label: "System draw", value: pw?.systemWatts.value.map { String(format: "%.2f", $0) }, unit: "W")
                        Readout(label: "Low Power Mode", value: pw.map { $0.lowPowerMode ? "On" : "Off" })
                        Readout(label: "Thermal", value: pw.map { thermalName($0.thermalState) })
                        Readout(label: "Battery", value: pw?.battery.map { String(format: "%.0f%%", $0.percent) })
                        Spacer()
                    }
                }
                Panel(title: "Frequency (DVFS tables)", trailing: "live clock: unavailable without privileged IOReport access") {
                    ForEach(freq.value ?? [], id: \.name) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.name).foregroundStyle(p.text)
                                Spacer()
                                Text(String(format: "%.0f – %.0f MHz · %d steps", c.minMHz, c.maxMHz, c.steps.count)).foregroundStyle(p.dim)
                            }.font(.system(size: 12, design: .monospaced))
                            HStack(alignment: .bottom, spacing: 2) {
                                ForEach(Array(c.steps.enumerated()), id: \.offset) { _, f in
                                    RoundedRectangle(cornerRadius: 1.5).fill(p.accent.opacity(0.4 + 0.6 * f / max(c.maxMHz, 1)))
                                        .frame(height: max(4, 50 * f / max(c.maxMHz, 1))).help(String(format: "%.0f MHz", f))
                                }
                            }.frame(height: 52)
                        }
                    }
                    if (freq.value ?? []).isEmpty && !freq.loading { Text("Frequency tables are not exposed on this Mac.").foregroundStyle(p.dim) }
                    Text("Per-core utilization by cluster is shown under Performance › CPU › Clusters.").font(.system(size: 11)).foregroundStyle(p.dim)
                }
                Panel(title: "Power management settings (pmset)") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                        ForEach(pm.value ?? [], id: \.self) { line in
                            let parts = line.split(separator: "\t", maxSplits: 1)
                            GridRow { Text(String(parts[0])).foregroundStyle(p.dim); Text(parts.count > 1 ? String(parts[1]) : "") }
                        }
                    }.font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(16)
        }
        .onAppear { freq.load(); pm.load() }
    }
}

struct InstalledAppsView: View {
    @StateObject var loader = Loader { InstalledApps.scan() }
    @State private var filter = ""
    @State private var hideSystem = false
    @State private var sortOrder = [KeyPathComparator(\InstalledApp.name)]
    @State private var selection: InstalledApp.ID?
    @State private var sizes: [String: UInt64] = [:]
    var body: some View {
        let items = (loader.value ?? []).filter { (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.bundleID.localizedCaseInsensitiveContains(filter)) && (!hideSystem || !$0.isSystem) }
        VStack(spacing: 0) {
            HStack {
                TextField("Filter apps", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Hide system apps", isOn: $hideSystem).toggleStyle(.switch)
                Spacer()
                Text("\(items.count) apps").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button("Compute Sizes") { computeSizes(items) }
            }.padding(10)
            Table(items.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { a in HStack { Image(nsImage: IconCache.icon(a.path)).resizable().frame(width: 16, height: 16); Text(a.name) } }.width(min: 180, ideal: 240)
                TableColumn("Version", value: \.version).width(90)
                TableColumn("Vendor", value: \.vendor).width(100)
                TableColumn("Kind", value: \.architectures).width(80)
                TableColumn("Source") { a in Text(a.isSystem ? "System" : (a.isAppStore ? "App Store" : "Other")) }.width(80)
                TableColumn("Size") { a in Text(sizes[a.path].map(Fmt.bytes) ?? "—").monospacedDigit() }.width(80)
                TableColumn("Modified") { a in Text(a.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—") }.width(100)
                TableColumn("Bundle ID", value: \.bundleID)
            }
            .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
                if let id = ids.first {
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: id)) }
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(id, inFileViewerRootedAtPath: "") }
                }
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .onAppear { loader.load() }
    }
    func computeSizes(_ apps: [InstalledApp]) {
        for a in apps where sizes[a.path] == nil {
            let path = a.path
            Task.detached(priority: .utility) {
                let s = InstalledApps.size(of: path)
                await MainActor.run { sizes[path] = s }
            }
        }
    }
}

@MainActor
final class DiskScan: ObservableObject {
    @Published var path: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var entries: [DirEntry] = []
    @Published var scanning = false
    private var generation = 0

    func scan(_ newPath: String? = nil) {
        if let newPath { path = newPath }
        generation += 1; let gen = generation
        entries = []; scanning = true
        let target = path
        let isCurrent: @Sendable () -> Bool = { [weak self] in
            DispatchQueue.main.sync { self?.generation == gen }
        }
        Task.detached(priority: .utility) {
            DiskUsage.children(of: target, progress: { entry in
                DispatchQueue.main.async { if self.generation == gen { self.entries.append(entry); self.entries.sort { $0.size > $1.size } } }
            }, cancelled: { !isCurrent() })
            await MainActor.run { if self.generation == gen { self.scanning = false } }
        }
    }
}

struct DiskSpaceView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @StateObject var scan = DiskScan()
    var body: some View {
        VStack(spacing: 12) {
            Panel(title: "Volumes") {
                ForEach(e.current?.disk.volumes ?? DiskSampler.volumes()) { v in
                    VolumeRow(v: v).contentShape(Rectangle()).onTapGesture { scan.scan(v.path) }
                }
            }
            Panel(title: "Largest items", trailing: scan.scanning ? "scanning…" : "\(Fmt.bytes(scan.entries.reduce(0) { $0 + $1.size })) in \(scan.entries.count) items") {
                HStack {
                    Button { scan.scan((scan.path as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }.disabled(scan.path == "/")
                    Text(scan.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choose Folder…") {
                        let pnl = NSOpenPanel(); pnl.canChooseDirectories = true; pnl.canChooseFiles = false
                        if pnl.runModal() == .OK, let u = pnl.url { scan.scan(u.path) }
                    }
                    Button("Rescan") { scan.scan() }
                }
                let top = scan.entries.first?.size ?? 1
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(scan.entries) { d in
                            HStack {
                                Image(systemName: d.isDirectory ? "folder.fill" : "doc").foregroundStyle(p.accent).frame(width: 18)
                                Text(d.name).lineLimit(1).frame(width: 260, alignment: .leading)
                                GeometryReader { g in
                                    RoundedRectangle(cornerRadius: 2).fill(p.accent.opacity(0.55)).frame(width: g.size.width * Double(d.size) / Double(max(top, 1)))
                                }.frame(height: 10)
                                Text(Fmt.bytes(d.size)).frame(width: 90, alignment: .trailing)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { if d.isDirectory { scan.scan(d.path) } }
                            .contextMenu {
                                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(d.path, inFileViewerRootedAtPath: "") }
                                if d.isDirectory { Button("Open Here") { scan.scan(d.path) } }
                            }
                        }
                    }
                }
                Text("Double-click a folder to drill in. Folders without Full Disk Access permission are counted as 0.").font(.system(size: 10)).foregroundStyle(p.dim)
            }
        }
        .padding(16)
        .onAppear { if scan.entries.isEmpty { scan.scan() } }
    }
}

struct BenchmarksView: View {
    @Environment(\.palette) var p
    @State private var results: [String: BenchmarkResult] = [:]
    @State private var running: String?
    @AppStorage("benchHistory") private var historyData: Data = Data()
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Panel(title: "Benchmarks", trailing: Sysctl.string("machdep.cpu.brand_string")) {
                    Text("Short synthetic tests. Close other apps for repeatable numbers. Results stay on this Mac.")
                        .font(.system(size: 11)).foregroundStyle(p.dim)
                    HStack {
                        Button("Run All") { Task { for n in Benchmarks.names { await run(n) } } }.disabled(running != nil)
                        if let running { ProgressView().controlSize(.small); Text("Running \(running)…").font(.system(size: 11, design: .monospaced)) }
                    }
                }
                ForEach(Benchmarks.names, id: \.self) { n in
                    Panel(title: n) {
                        HStack {
                            Readout(label: "Score", value: results[n].map { String(format: "%.1f", $0.score) }, unit: results[n]?.unit ?? "")
                            Spacer()
                            Text(results[n]?.detail ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                            Button("Run") { Task { await run(n) } }.disabled(running != nil)
                        }
                        if let best = previousBest(n) {
                            Text(String(format: "Best on this Mac: %.1f", best)).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                        }
                    }
                }
            }.padding(16)
        }
    }
    func run(_ n: String) async {
        running = n
        let r = await Benchmarks.run(n)
        results[n] = r; running = nil
        var h = (try? JSONDecoder().decode([String: Double].self, from: historyData)) ?? [:]
        h[n] = max(h[n] ?? 0, r.score)
        historyData = (try? JSONEncoder().encode(h)) ?? Data()
    }
    func previousBest(_ n: String) -> Double? { ((try? JSONDecoder().decode([String: Double].self, from: historyData)) ?? [:])[n] }
}
