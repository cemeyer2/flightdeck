import SwiftUI
import MeterCore
import Combine

/// Loads data off the main thread and optionally refreshes it.
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

struct ViewHeader<Trailing: View>: View {
    @Environment(\.palette) var p
    var text: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack { Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim); Spacer(); trailing }.padding(10)
    }
}

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

struct StartupView: View {
    @StateObject var loader = Loader { Launchd.startupItems() }
    @State private var selection: StartupItem.ID?
    @State private var sortOrder = [KeyPathComparator(\StartupItem.label)]
    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(text: "Launch agents, launch daemons and login items that start automatically.") {
                Button("Refresh") { loader.load() }
            }
            Table((loader.value ?? []).sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.label) { Text($0.label).lineLimit(1) }.width(min: 200, ideal: 280)
                TableColumn("Kind", value: \.kind).width(160)
                TableColumn("Status") { i in Text(i.disabled ? "Disabled" : (i.loaded ? "Loaded" : "Not loaded")).foregroundStyle(i.loaded ? .primary : .secondary) }.width(90)
                TableColumn("Run at load") { Text($0.runAtLoad ? "Yes" : "No") }.width(80)
                TableColumn("Keep alive") { Text($0.keepAlive ? "Yes" : "No") }.width(80)
                TableColumn("Program", value: \.program) { Text($0.program).lineLimit(1).truncationMode(.middle) }
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

struct UsersView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @StateObject var loader = Loader { Connections.sessions() }
    struct Agg: Identifiable { var id: String { user }; var user: String; var procs: Int; var measured: Int; var cpu: Double; var mem: UInt64; var energy: Double }
    var body: some View {
        let aggs: [Agg] = Dictionary(grouping: e.current?.processes ?? [], by: \.user).map { u, all in
            let ps = all.filter { !$0.restricted }
            return Agg(user: u, procs: all.count, measured: ps.count, cpu: ps.reduce(0) { $0 + $1.cpu }, mem: ps.reduce(0) { $0 + $1.memory }, energy: ps.reduce(0) { $0 + ($1.energyWatts ?? 0) })
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
