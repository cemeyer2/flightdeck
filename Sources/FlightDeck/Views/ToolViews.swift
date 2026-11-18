import SwiftUI
import FlightDeckCore
// Tool destinations: Power & Freq (DVFS tables and pmset settings), Installed Apps, Disk Space (largest items) and
// Benchmarks. Like the inventory views, each gathers its data on demand off the main thread, so nothing runs
// while the page isn't open.

/// Power & Freq: current power state from `e.current.power`, each cluster's DVFS frequency table (read once on appear
/// from the IORegistry `pmgr` node, or Intel sysctls) with the live clock highlighted, and `pmset -g` settings.
struct PowerView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @StateObject var freq = Loader { Frequency.clusters() }
    // Flattened to "key\tvalue" strings so the loaded value is Sendable and Hashable for ForEach.
    @StateObject var pm = Loader { Frequency.pmsetSettings().map { "\($0.0)\t\($0.1)" } }
    /// Live clock for a DVFS table: the matching CPU cluster average, or the GPU's.
    func liveMHz(_ table: String) -> Double? {
        guard let g = e.current?.gpuDetail else { return nil }
        if table == "GPU" { return g.frequencyMHz }
        // DVFS tables are named after their cluster kind ("Efficiency…", "Performance…", "GPU"); live clocks come
        // from IOReport via `gpuDetail.cpuClusters` and are only present on Apple silicon.
        let kind = table.hasPrefix("Efficiency") ? "E" : "P"
        let m = g.cpuClusters.filter { $0.name.hasPrefix(kind) }.compactMap(\.mhz)
        return m.isEmpty ? nil : m.max()
    }

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
                Panel(title: "Frequency (DVFS tables)", trailing: "live clocks from IOReport") {
                    ForEach(freq.value ?? [], id: \.name) { c in
                        let live = liveMHz(c.name)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.name).foregroundStyle(p.text)
                                if let live { Text(String(format: "now %.0f MHz", live)).foregroundStyle(p.accent) }
                                Spacer()
                                Text(String(format: "%.0f – %.0f MHz · %d steps", c.minMHz, c.maxMHz, c.steps.count)).foregroundStyle(p.dim)
                            }.font(.system(size: 12, design: .monospaced))
                            HStack(alignment: .bottom, spacing: 2) {
                                // Steps at or below the live clock are lit (1 MHz tolerance for rounding); with no
                                // live clock every step is drawn lit. Bar height scales with frequency.
                                ForEach(Array(c.steps.enumerated()), id: \.offset) { _, f in
                                    let lit = live.map { f <= $0 + 1 } ?? true
                                    RoundedRectangle(cornerRadius: 1.5).fill(lit ? p.accent.opacity(0.4 + 0.6 * f / max(c.maxMHz, 1)) : p.meterOff)
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

/// Installed Apps: bundles found by `InstalledApps.scan()` with version, vendor, architectures and source. Sizes are
/// opt-in ("Compute Sizes") because walking every bundle is slow; until computed a size shows "—", not 0.
struct InstalledAppsView: View {
    @StateObject var loader = Loader { InstalledApps.scan() }
    @State private var filter = ""
    @State private var hideSystem = false
    @State private var sortOrder = [KeyPathComparator(\InstalledApp.name)]
    @State private var selection: InstalledApp.ID?
    /// Allocated bytes per app path, filled in as each background size walk finishes.
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
                TableColumn("Size") { a in Text(sizes[a.path].map(Fmt.storage) ?? "—").monospacedDigit() }.width(80)
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
    /// Starts one detached utility task per app not yet sized (all at once); each result lands on the main actor.
    func computeSizes(_ apps: [InstalledApp]) {
        // At most 4 bundle walks at a time: hundreds in parallel would thrash the disk and the thread pool.
        let paths = apps.filter { sizes[$0.path] == nil }.map(\.path)
        Task.detached(priority: .utility) {
            await withTaskGroup(of: (String, UInt64).self) { group in
                var next = paths.makeIterator()
                for _ in 0..<4 { if let p = next.next() { group.addTask { (p, InstalledApps.size(of: p)) } } }
                while let (p, s) = await group.next() {
                    await MainActor.run { sizes[p] = s }
                    if let n = next.next() { group.addTask { (n, InstalledApps.size(of: n)) } }
                }
            }
        }
    }
}

/// Disk Space scanner: sizes the immediate children of `path` recursively on a detached task, streaming each finished
/// child into `entries` (kept sorted, largest first).
@MainActor
final class DiskScan: ObservableObject {
    @Published var path: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var entries: [DirEntry] = []
    @Published var scanning = false
    /// False until the user starts the first scan; the page then shows an explanation and Scan buttons instead.
    @Published var started = false
    /// Bumped on every new scan. Results and the cancellation check compare against it, so navigating to another folder
    /// abandons the old scan and its late results are dropped instead of mixing into the new list.
    private var generation = 0
    /// The current generation, readable from the scanning thread without blocking on the main thread.
    private let liveGeneration = GenerationBox()

    func scan(_ newPath: String? = nil) {
        if let newPath { path = newPath }
        started = true
        generation += 1; let gen = generation
        liveGeneration.set(gen)
        entries = []; scanning = true
        let target = path
        let live = liveGeneration
        // A constant weak box rather than `[weak self]`: a weak capture is a `var`, which Swift won't share safely with
        // the background closure. It is only dereferenced on the main thread.
        let owner = WeakBox(self)
        Task.detached(priority: .utility) {
            DiskUsage.children(of: target, progress: { entry in
                DispatchQueue.main.async {
                    guard let self = owner.value, self.generation == gen else { return }
                    // Insert in size order instead of re-sorting the whole list for every streamed result.
                    let i = self.entries.firstIndex { $0.size < entry.size } ?? self.entries.endIndex
                    self.entries.insert(entry, at: i)
                }
            }, cancelled: { live.get() != gen })
            await MainActor.run { if let self = owner.value, self.generation == gen { self.scanning = false } }
        }
    }
}

/// Holds a weak reference that background work can carry; read `value` only on the thread that owns the object.
final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}

/// A lock-protected integer shared with background work (here: "is this scan still the current one?").
final class GenerationBox: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Disk Space: mounted volumes (click one to scan it) and a drill-down list of the largest items in the scanned folder,
/// starting at the home folder. Without Full Disk Access protected folders can't be read and count as 0 bytes, which
/// the footer states.
struct DiskSpaceView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @StateObject var scan = DiskScan()
    @AppStorage("diskSpaceMode") var mode: DiskSpaceMode = .usage
    var body: some View {
        VStack(spacing: 12) {
            // "What's using my disk" (DiskUsageOverview.swift) or the folder scanner below.
            Picker("", selection: $mode) { ForEach(DiskSpaceMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            if mode == .usage { DiskUsageOverview() } else {
            Panel(title: "Volumes") {
                // Falls back to a direct volume query before the first sample arrives.
                // Scanning is always an explicit button press: a scan reads every file under the folder, which is heavy
                // and makes macOS ask for access to Desktop, Documents, Downloads, Photos and so on.
                ForEach(e.current?.disk.volumes ?? DiskSampler.volumes()) { v in
                    HStack(spacing: 10) {
                        VolumeRow(v: v)
                        Button("Scan") { scan.scan(v.path) }.controlSize(.small).disabled(scan.scanning)
                            .help("Find the largest folders and files on \(v.name)")
                    }
                }
            }
            Panel(title: "Largest items", trailing: scan.scanning ? "scanning…" : scan.started ? "\(Fmt.storage(scan.entries.reduce(0) { $0 + $1.size })) in \(scan.entries.count) items" : nil) {
                if !scan.started {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing scanned yet.").font(.system(size: 13, weight: .semibold))
                        Text("A scan measures every folder and file under the place you pick, to find what takes the space. It reads a lot of the disk, and macOS may ask you to allow FlightDeck to access folders such as Desktop, Documents, Downloads and Photos; any you don't allow are counted as 0.")
                            .font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Scan Home Folder") { scan.scan(FileManager.default.homeDirectoryForCurrentUser.path) }
                            Button("Choose Folder…") { chooseFolder() }
                        }
                    }
                } else {
                HStack {
                    Button { scan.scan((scan.path as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }.disabled(scan.path == "/")
                    Text(scan.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choose Folder…") { chooseFolder() }
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
                                Text(Fmt.storage(d.size)).frame(width: 90, alignment: .trailing)
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
            }
        }
        .padding(16)
        // No scan on appear: opening the page (or clicking it by accident) must not start a full scan.
    }

    func chooseFolder() {
        let pnl = NSOpenPanel(); pnl.canChooseDirectories = true; pnl.canChooseFiles = false
        if pnl.runModal() == .OK, let u = pnl.url { scan.scan(u.path) }
    }
}

/// Benchmarks: short synthetic CPU/memory/disk tests from FlightDeckCore/Benchmarks.swift, each run on a detached task.
/// Only one runs at a time (all buttons disable while one is running) so they don't skew each other.
struct BenchmarksView: View {
    @Environment(\.palette) var p
    @State private var results: [String: BenchmarkResult] = [:]
    @State private var running: String?
    /// Best score per benchmark ever seen on this Mac, as JSON-encoded [name: score] in user defaults.
    @AppStorage("benchHistory") private var historyData: Data = Data()
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Panel(title: "Benchmarks", trailing: Engine.chipName) {
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
    /// Runs one benchmark, shows its result and updates the stored best score.
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
