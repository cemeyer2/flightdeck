import SwiftUI
import FlightDeckCore
// Processes destination: the live process list (ProcessOutline, an AppKit NSOutlineView wrapper in Components) with
// filter, tree/apps/flat views, context menus and a detail bar for the selection. Also defines AppIcon and IconCache,
// which every view showing app icons uses, and BarCell.

/// Lists `e.current.processes` (so during replay it shows the recorded processes). Actions go through
/// `ProcessSampler.send`, which re-checks PID + start time, so a replayed or stale row can never signal a recycled PID.
struct ProcessesView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @State private var filter = ""
    @AppStorage("procView") private var view = "tree"   // tree | apps | flat
    @AppStorage("procMineOnly") private var mineOnly = false
    /// Selected row by identity, not PID, so the selection doesn't jump to a new process that reuses the PID.
    @State private var selection: ProcessIdentity?
    /// Pending confirmation for Quit / Force Quit: (process, signal, verb).
    @State private var confirm: (ProcessSample, Int32, String)?
    @State private var error: String?
    /// App-level quit awaiting confirmation (the app, and whether it's a force quit).
    @State private var confirmApp: (NSRunningApplication, Bool)?

    /// The processes handed to the outline, optionally only the current user's.
    var visibleProcesses: [ProcessSample] {
        let procs = e.current?.processes ?? []
        return mineOnly ? procs.filter { $0.uid == getuid() } : procs
    }

    /// The running app behind an app-group row (synthetic rows have negative PIDs).
    func runningApp(_ s: ProcessSample) -> NSRunningApplication? {
        guard let b = AppUsage.bundle(of: s.path) else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path }
    }

    /// AppKit context menu for a row (ProcessOutline is an NSOutlineView, so it needs an NSMenu rather than SwiftUI).
    /// App-group rows act on the whole app through NSRunningApplication; process rows send identity-checked signals.
    func nsMenu(_ s: ProcessSample) -> NSMenu {
        let m = NSMenu()
        // App rows quit immediately, as the Dock's Quit does: the app itself can still prompt to save.
        if s.pid < 0 {   // app group row
            let app = runningApp(s)
            // Same confirmation as per-process Quit: quitting an app group can lose unsaved work in any of its windows.
            m.addItem(ClosureMenuItem("Quit App…", enabled: app != nil) { if let app { confirmApp = (app, false) } })
            m.addItem(ClosureMenuItem("Force Quit App…", enabled: app != nil) { if let app { confirmApp = (app, true) } })
            m.addItem(ClosureMenuItem("Reveal in Finder") { NSWorkspace.shared.selectFile(AppUsage.bundle(of: s.path), inFileViewerRootedAtPath: "") })
            return m
        }
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
        // Looked up fresh from the current snapshot so the detail bar reflects the latest sample of the selection.
        let selected = e.current?.processes.first { $0.identity == selection }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // The filter mini-language (cpu>50, user:root, kind:intel, hung…) is parsed in ProcessOutline/ProcessQuery.
                TextField("Filter: name, PID, or cpu>50 mem>1g user:root app:chrome kind:intel gpu>0 sleep hung", text: $filter)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                    .help("Space-separated terms, all must match. cpu>50 · gpu>0 · mem>1g · disk>10m · net>100k · threads>100 · wakeups>500 · user:root · app:chrome · kind:intel · sleep · hung · restricted · or any text")
                Picker("", selection: $view) { Text("Tree").tag("tree"); Text("Apps").tag("apps"); Text("Flat").tag("flat") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    .help("Tree: by parent process · Apps: helpers grouped under their app · Flat: every process")
                Toggle("My processes", isOn: $mineOnly).toggleStyle(.switch)
                Spacer()
                if let c = e.current {
                    Text("\(c.processes.count) processes · \(c.processes.reduce(0) { $0 + $1.threads }) threads")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                }
            }.padding(10)
            // Double-click opens the inspector, except on synthetic app-group rows (negative PIDs).
            ProcessOutline(frameTime: e.current?.time, processes: visibleProcesses, tree: view == "tree", byApp: view == "apps", filter: filter, palette: p, selection: $selection, menu: nsMenu,
                           onOpen: { if $0.pid > 0 { AppActions.openInspector?($0.identity) } },
                           tabLabels: e.mode == .live ? e.chromeTabs : [:])   // live tabs never label replayed rows
            if let selected, selected.pid > 0 { ProcessDetailBar(s: selected, actions: { AnyView(actions(selected)) }) }
        }
        .alert("\(confirm?.2 ?? "") “\(confirm?.0.name ?? "")”?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm?.2 ?? "OK", role: .destructive) { if let c = confirm { send(c.1, c.0) }; confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {   // a renderer's live tabs close with it (never named while replaying)
            Text("PID \(confirm?.0.pid ?? 0). Unsaved work in this process may be lost."
                 + ((e.mode == .live ? confirm.flatMap { e.chromeTabs[$0.0.identity] } : nil).flatMap(ChromeTabText.killWarning).map { "\n\($0)" } ?? ""))
        }
        .alert("\(confirmApp?.1 == true ? "Force Quit" : "Quit") “\(confirmApp?.0.localizedName ?? "")”?",
               isPresented: Binding(get: { confirmApp != nil }, set: { if !$0 { confirmApp = nil } })) {
            Button(confirmApp?.1 == true ? "Force Quit" : "Quit", role: .destructive) {
                if let (app, force) = confirmApp { _ = force ? app.forceTerminate() : app.terminate() }
                confirmApp = nil
            }
            Button("Cancel", role: .cancel) { confirmApp = nil }
        } message: { Text(confirmApp?.1 == true ? "Unsaved work in all of its windows will be lost." : "The app will ask to save any unsaved work.") }
        .alert("Action failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    /// The detail bar's Actions menu (SwiftUI equivalent of the row context menu, plus Select Parent).
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
        // Switches to tree view and clears the filter so the parent row is guaranteed to be visible.
        Button("Select Parent") { filter = ""; view = "tree"; selection = e.current?.processes.first { $0.pid == s.ppid }?.identity }
    }

    func send(_ sig: Int32, _ s: ProcessSample) {
        do { try ProcessSampler.send(sig, to: s.identity) } catch { self.error = error.localizedDescription }
    }
}

/// Text over a level-coloured background bar filled to `fraction` (clamped to 0…1); used for numeric table cells.
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

/// Icon of the `.app` bundle a path lives in (the outermost "X.app/" match), or a generic gear for non-app processes.
/// Callers pass bundle paths with a trailing "/" so the bundle itself matches.
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

/// NSWorkspace icon lookups hit the disk, and the process list re-renders every sample, so icons are cached forever
/// by bundle path. Main-thread only (SwiftUI body), hence the unchecked `nonisolated(unsafe)` static.
enum IconCache {
    nonisolated(unsafe) static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path); cache[path] = i; return i
    }
}

/// Bottom bar for the selected process: identity, CPU time, start time, lifetime disk totals ("—" when restricted)
/// and buttons for the inspector (⌘I) and actions.
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
