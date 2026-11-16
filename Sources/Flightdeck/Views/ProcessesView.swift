import SwiftUI
import FlightdeckCore

struct ProcessesView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @State private var filter = ""
    @AppStorage("procTree") private var tree = true
    @AppStorage("procMineOnly") private var mineOnly = false
    @State private var selection: ProcessIdentity?
    @State private var confirm: (ProcessSample, Int32, String)?
    @State private var error: String?

    var visibleProcesses: [ProcessSample] {
        let procs = e.current?.processes ?? []
        return mineOnly ? procs.filter { $0.uid == getuid() } : procs
    }

    func nsMenu(_ s: ProcessSample) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem("Inspect…") { AppActions.openInspector?(s.identity) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Quit") { confirm = (s, SIGTERM, "Quit") })
        m.addItem(ClosureMenuItem("Force Quit") { confirm = (s, SIGKILL, "Force Quit") })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Suspend") { send(SIGSTOP, s) })
        m.addItem(ClosureMenuItem("Resume") { send(SIGCONT, s) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Reveal in Finder", enabled: !s.path.isEmpty) { NSWorkspace.shared.selectFile(s.path, inFileViewerRootedAtPath: "") })
        m.addItem(ClosureMenuItem("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.path, forType: .string) })
        return m
    }

    var body: some View {
        let selected = e.current?.processes.first { $0.identity == selection }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Filter by name, PID, user or path", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Toggle("Tree", isOn: $tree).toggleStyle(.switch)
                Toggle("My processes", isOn: $mineOnly).toggleStyle(.switch)
                Spacer()
                if let c = e.current {
                    Text("\(c.processes.count) processes · \(c.processes.reduce(0) { $0 + $1.threads }) threads")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                }
            }.padding(10)
            ProcessOutline(frameTime: e.current?.time, processes: visibleProcesses, tree: tree, filter: filter, palette: p, selection: $selection, menu: nsMenu,
                           onOpen: { AppActions.openInspector?($0.identity) })
            if let selected { ProcessDetailBar(s: selected, actions: { AnyView(actions(selected)) }) }
        }
        .alert("\(confirm?.2 ?? "") “\(confirm?.0.name ?? "")”?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm?.2 ?? "OK", role: .destructive) { if let c = confirm { send(c.1, c.0) }; confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: { Text("PID \(confirm?.0.pid ?? 0). Unsaved work in this process may be lost.") }
        .alert("Action failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    @ViewBuilder func actions(_ s: ProcessSample) -> some View {
        Button("Inspect…") { AppActions.openInspector?(s.identity) }
        Divider()
        Button("Quit") { confirm = (s, SIGTERM, "Quit") }
        Button("Force Quit") { confirm = (s, SIGKILL, "Force Quit") }
        Divider()
        Button("Suspend") { send(SIGSTOP, s) }
        Button("Resume") { send(SIGCONT, s) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(s.path, inFileViewerRootedAtPath: "") }.disabled(s.path.isEmpty)
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.path, forType: .string) }
        Button("Select Parent") { filter = ""; tree = true; selection = e.current?.processes.first { $0.pid == s.ppid }?.identity }
    }

    func send(_ sig: Int32, _ s: ProcessSample) {
        do { try ProcessSampler.send(sig, to: s.identity) } catch { self.error = error.localizedDescription }
    }
}

struct BarCell: View {
    @Environment(\.palette) var p
    var text: String
    var fraction: Double
    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 2).fill(p.level(fraction).opacity(0.28)).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
            Text(text).monospacedDigit().padding(.leading, 3)
        }
    }
}

struct AppIcon: View {
    var path: String
    var body: some View {
        if let app = path.range(of: ".app/") {
            Image(nsImage: IconCache.icon(String(path[..<app.lowerBound]) + ".app"))
                .resizable()
        } else {
            Image(systemName: "gearshape").resizable().foregroundStyle(.secondary).padding(1)
        }
    }
}

enum IconCache {
    nonisolated(unsafe) static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path); cache[path] = i; return i
    }
}

struct ProcessDetailBar: View {
    @Environment(\.palette) var p
    var s: ProcessSample
    var actions: () -> AnyView
    var body: some View {
        HStack(spacing: 20) {
            AppIcon(path: s.path).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 13, weight: .semibold))
                Text(s.path.isEmpty ? "path unavailable" : s.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }.frame(maxWidth: 360, alignment: .leading)
            Readout(label: "PID / PPID", value: "\(s.pid) / \(s.ppid)", size: 13)
            Readout(label: "CPU time", value: Fmt.duration(s.cpuTime), size: 13)
            Readout(label: "Started", value: s.startDate.formatted(date: .omitted, time: .standard), size: 13)
            Readout(label: "Disk R/W total", value: s.restricted ? nil : "\(Fmt.bytes(s.diskRead)) / \(Fmt.bytes(s.diskWritten))", size: 13)
            Spacer()
            Button("Inspect") { AppActions.openInspector?(s.identity) }.keyboardShortcut("i")
            Menu("Actions") { actions() }.frame(width: 90)
        }
        .padding(10).background(p.panel).overlay(alignment: .top) { Divider() }
    }
}
