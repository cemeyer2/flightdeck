import SwiftUI
import FlightDeckCore
import Combine
// Inventory destinations that list things on demand rather than every sample: System Info, Startup Apps, Users,
// Services (launchd) and Connections. Each owns a `Loader` that runs a FlightDeckCore collector off the main thread
// when the view appears, so none of this costs anything while the page isn't open.

/// Loads data off the main thread and optionally refreshes it.
/// Publishes the result on the main actor. `load()` is ignored while a load is already running, so repeated
/// Refresh clicks or timer ticks never stack up concurrent collectors. `value` stays nil until the first load ends.
@MainActor
final class Loader<T: Sendable>: ObservableObject {
    @Published var value: T?
    @Published var loading = false
    private let work: @Sendable () -> T
    init(_ work: @escaping @Sendable () -> T) { self.work = work }
    func load() {
        guard !loading else { return }
        loading = true
        let w = work
        Task.detached { let v = w(); await MainActor.run { self.value = v; self.loading = false } }
    }
}

/// The dim one-line description bar across the top of a table page, with trailing controls (e.g. Refresh).
struct ViewHeader<Trailing: View>: View {
    @Environment(\.palette) var p
    var text: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack { Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim); Spacer(); trailing }.padding(10)
    }
}

/// System Info: hardware/OS facts from `SystemInfo.collect()` (sysctl, IORegistry), grouped into panels by section
/// in the order the collector produced them. Keys with no value are omitted by the collector rather than shown empty.
struct SystemInfoView: View {
    @Environment(\.palette) var p
    @StateObject var loader = Loader { SystemInfo.collect() }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                let items = loader.value ?? []
                let sections = items.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
                ForEach(sections, id: \.self) { sec in
                    Panel(title: sec) {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            ForEach(items.filter { $0.section == sec }) { i in
                                GridRow {
                                    Text(i.key).foregroundStyle(p.dim).frame(width: 200, alignment: .leading)
                                    Text(i.value).foregroundStyle(p.text).textSelection(.enabled)
                                }
                            }
                        }.font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if loader.loading && items.isEmpty { ProgressView() }
                HStack {
                    Spacer()
                    // Tab-separated so the copy pastes cleanly into a spreadsheet.
                    Button("Copy All") {
                        let text = items.map { "\($0.section)\t\($0.key)\t\($0.value)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }.padding(16)
        }
        .onAppear { loader.load() }
    }
}

/// Startup Apps: launch agents/daemons from the user and system LaunchAgents/LaunchDaemons folders, with their
/// loaded state, signer and whether the program they point at still exists ("orphaned" leftovers of removed apps).
struct StartupView: View {
    @StateObject var loader = Loader { Launchd.startupItems() }
    @State private var selection: StartupItem.ID?
    @State private var sortOrder = [KeyPathComparator(\StartupItem.label)]
    var body: some View {
        VStack(spacing: 0) {
            // Header counts: items not signed by Apple (signer known), unsigned programs, and orphans.
            let items = loader.value ?? []
            let orphans = items.filter(\.orphaned).count
            let unsigned = items.filter { $0.signer?.hasPrefix("Not signed") == true }.count
            let thirdParty = items.filter { $0.signer != nil && !$0.signedByApple }.count
            ViewHeader(text: "Launch agents, launch daemons and login items that start automatically."
                       + (items.isEmpty ? "" : " \(items.count) items · \(thirdParty) not from Apple"
                          + (unsigned > 0 ? " · \(unsigned) unsigned" : "") + (orphans > 0 ? " · \(orphans) point to missing programs (leftovers from removed apps)" : ""))) {
                Button("Refresh") { loader.load() }
            }
            // Row IDs are plist paths, so the context menu's "Reveal in Finder" selects the plist itself.
            Table((loader.value ?? []).sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.label) { Text($0.label).lineLimit(1) }.width(min: 200, ideal: 280)
                TableColumn("Kind", value: \.kind).width(160)
                TableColumn("Status") { i in Text(i.disabled ? "Disabled" : (i.loaded ? "Loaded" : "Not loaded")).foregroundStyle(i.loaded ? .primary : .secondary) }.width(90)
                TableColumn("Run at load") { Text($0.runAtLoad ? "Yes" : "No") }.width(80)
                TableColumn("Keep alive") { Text($0.keepAlive ? "Yes" : "No") }.width(80)
                TableColumn("Signed by") { i in
                    Text(i.signer ?? "—").lineLimit(1)
                        .foregroundStyle(i.signer?.hasPrefix("Not signed") == true ? Color.orange : (i.signedByApple ? .secondary : .primary))
                        .help(i.signer ?? "")
                }.width(min: 140, ideal: 220)
                TableColumn("Program", value: \.program) { i in
                    Text(i.orphaned ? "missing: " + i.program : i.program).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(i.orphaned ? Color.red : .primary).help(i.program)
                }
            }
            .contextMenu(forSelectionType: StartupItem.ID.self) { ids in
                if let id = ids.first {
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(id, inFileViewerRootedAtPath: "") }
                    Button("Open Login Items Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                }
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .onAppear { loader.load() }
    }
}

/// Users: login sessions (utmpx, loaded once on appear) and per-user resource totals summed live from `e.current`.
/// Processes of other users are usually `restricted` without root, so totals only include readable processes, and a
/// user with none readable shows "—" instead of a misleading 0.
struct UsersView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @StateObject var loader = Loader { Connections.sessions() }
    /// Per-user totals: `procs` is every process, `measured` the readable ones that the CPU/memory/energy sums cover.
    struct Agg: Identifiable { var id: String { user }; var user: String; var procs: Int; var measured: Int; var cpu: Double; var mem: UInt64; var energy: Double }
    var body: some View {
        let aggs: [Agg] = Dictionary(grouping: e.current?.processes ?? [], by: \.user).map { u, all in
            let ps = all.filter { !$0.restricted }
            return Agg(user: u, procs: all.count, measured: ps.count, cpu: ps.reduce(0) { $0 + $1.cpu }, mem: ps.reduce(0) { $0 + $1.memory }, energy: ps.reduce(0) { $0 + ($1.energyWatts ?? 0) })
        // Users with nothing readable sort to the bottom rather than ranking as 0% CPU.
        }.sorted { ($0.measured > 0 ? $0.cpu : -1) > ($1.measured > 0 ? $1.cpu : -1) }
        ScrollView {
            VStack(spacing: 12) {
                Panel(title: "Sessions") {
                    ForEach(loader.value ?? []) { s in
                        HStack {
                            Image(systemName: "person.crop.circle")
                            Text(s.user).frame(width: 140, alignment: .leading)
                            Text(s.tty).foregroundStyle(p.dim).frame(width: 100, alignment: .leading)
                            Text(s.host.isEmpty ? "local" : s.host).foregroundStyle(p.dim)
                            Spacer()
                            Text("since " + s.loginTime.formatted(date: .abbreviated, time: .shortened))
                        }.font(.system(size: 12, design: .monospaced))
                    }
                }
                Panel(title: "Resource use by user", trailing: "other users' processes need root to measure") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow { ForEach(["User", "Processes", "CPU", "", "Memory", "Energy"], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                        ForEach(aggs) { a in
                            GridRow {
                                let ok = a.measured > 0
                                Text(a.user); Text(a.measured == a.procs ? "\(a.procs)" : "\(a.procs) (\(a.measured) readable)")
                                Text(ok ? Fmt.pct(a.cpu) : "—")
                                // Process CPU is % of one core, so the meter is scaled against all logical cores.
                                VFDMeter(fraction: ok ? min(a.cpu / Double(100 * ProcessInfo.processInfo.activeProcessorCount), 1) : nil, segments: 20, height: 6).frame(width: 140)
                                Text(ok ? Fmt.bytes(a.mem) : "—"); Text(ok ? String(format: "%.2f W", a.energy) : "—")
                            }.font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }.padding(16)
        }
        .onAppear { loader.load() }
    }
}

/// Services: the jobs `launchctl list` shows for the user's GUI domain, filterable, with PID, running state and last
/// exit status (non-zero exits highlighted, often a crash-looping agent).
struct ServicesView: View {
    @StateObject var loader = Loader { Launchd.services() }
    @State private var filter = ""
    @State private var runningOnly = false
    @State private var sortOrder = [KeyPathComparator(\ServiceItem.label)]
    @State private var selection: ServiceItem.ID?
    var body: some View {
        let items = (loader.value ?? []).filter { (filter.isEmpty || $0.label.localizedCaseInsensitiveContains(filter)) && (!runningOnly || $0.isRunning) }
        VStack(spacing: 0) {
            HStack {
                TextField("Filter services", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Toggle("Running only", isOn: $runningOnly).toggleStyle(.switch)
                Spacer()
                Text("\(items.count) launchd jobs in your GUI domain").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button("Refresh") { loader.load() }
            }.padding(10)
            Table(items.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Label", value: \.label) { Text($0.label) }.width(min: 260, ideal: 420)
                TableColumn("PID") { Text($0.pid.map(String.init) ?? "—").monospacedDigit() }.width(70)
                TableColumn("Status") { s in Text(s.isRunning ? "Running" : "Stopped").foregroundStyle(s.isRunning ? .green : .secondary) }.width(80)
                TableColumn("Last exit") { s in Text(s.lastExit.map(String.init) ?? "—").foregroundStyle((s.lastExit ?? 0) != 0 ? .orange : .secondary) }.width(70)
                TableColumn("Domain", value: \.domain).width(120)
            }
            .contextMenu(forSelectionType: ServiceItem.ID.self) { ids in
                if let id = ids.first {
                    Button("Copy Label") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string) }
                    // Restarts the job in the user's GUI domain, then reloads the list to pick up its new PID.
                    Button("Restart (kickstart -k)") {
                        _ = Shell.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(id)"]); loader.load()
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .onAppear { loader.load() }
    }
}

/// Connections: sockets of the user's own processes from `lsof -i` (other users' need root), refreshed every 3 s
/// while "Auto refresh" is on. The timer only lives as long as this view, so a closed page stops polling.
struct ConnectionsView: View {
    @StateObject var loader = Loader { Connections.list() }
    @State private var filter = ""
    @State private var sortOrder = [KeyPathComparator(\ConnectionItem.process)]
    @State private var auto = true
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    var body: some View {
        let items = (loader.value ?? []).filter { filter.isEmpty || "\($0.process) \($0.remote) \($0.local) \($0.pid)".localizedCaseInsensitiveContains(filter) }
        VStack(spacing: 0) {
            HStack {
                TextField("Filter by process, address or port", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Toggle("Auto refresh", isOn: $auto).toggleStyle(.switch)
                Spacer()
                let est = items.filter { $0.state == "ESTABLISHED" }.count
                let listen = items.filter { $0.state == "LISTEN" }.count
                Text("\(items.count) sockets · \(est) established · \(listen) listening (your processes)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button("Refresh") { loader.load() }
            }.padding(10)
            Table(items.sorted(using: sortOrder), sortOrder: $sortOrder) {
                TableColumn("Process", value: \.process).width(min: 120, ideal: 160)
                TableColumn("PID", value: \.pid) { Text("\($0.pid)").monospacedDigit() }.width(60)
                TableColumn("Proto", value: \.proto).width(50)
                TableColumn("Local", value: \.local) { Text($0.local).textSelection(.enabled) }.width(min: 160, ideal: 220)
                TableColumn("Remote", value: \.remote) { Text($0.remote.isEmpty ? "—" : $0.remote).textSelection(.enabled) }.width(min: 160, ideal: 240)
                TableColumn("State", value: \.state) { c in Text(c.state).foregroundStyle(c.state == "ESTABLISHED" ? .green : (c.state == "LISTEN" ? .blue : .secondary)) }.width(100)
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .onAppear { loader.load() }
        .onReceive(timer) { _ in if auto { loader.load() } }
    }
}
