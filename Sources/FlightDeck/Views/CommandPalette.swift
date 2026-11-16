// The command palette (⌘K): a Spotlight-style overlay in the main window. Type to fuzzy-match destinations (including
// Performance tabs), running processes and apps, and commands; arrows move, Return acts (or opens a process's actions),
// Esc goes back or closes. Every action calls existing code (Engine methods, AppActions, ProcessSampler.send); the
// destructive ones ask for the same confirmation as the Processes view.
import SwiftUI
import AppKit
import FlightDeckCore

/// One action on a process or app ("Inspect…", "Quit…"). `confirm` holds the alert text for destructive actions.
struct PaletteAction: Identifiable {
    struct Confirmation { var title: String; var message: String; var button: String }
    var id: String { title }
    var title: String
    var icon: String
    var enabled = true
    var confirm: Confirmation? = nil
    var run: () -> Void
}

/// One palette row. Destinations and commands have a direct `run`; processes and apps have `actions` instead.
struct PaletteItem: Identifiable {
    enum Kind: Int { case command = 0, destination = 1, app = 2, process = 3
        var label: String { ["Command", "Go to", "App", "Process"][rawValue] }
    }
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String = ""
    var icon: String
    /// For apps and processes: the executable path, so the row can show the app's icon.
    var iconPath: String? = nil
    var enabled = true
    var run: (() -> Void)? = nil
    var actions: [PaletteAction] = []
    /// Extra text matched at a lower rank than the title (PID, user, path).
    var keywords: String = ""
}

/// Palette state. Items are collected once when the palette opens (a stable list to arrow through, rather than one
/// that reshuffles every sample); queries are then ranked with FuzzyMatch.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { refilter() } }
    @Published private(set) var results: [PaletteItem] = []
    @Published var selection = 0
    /// Non-nil while showing one item's actions (second level).
    @Published var focused: PaletteItem?
    @Published var pendingConfirm: PaletteAction?
    private(set) var items: [PaletteItem] = []

    /// Rows currently listed: the results, or the focused item's actions turned into rows.
    var rows: [PaletteItem] {
        guard let f = focused else { return results }
        return f.actions.map { a in PaletteItem(id: f.id + a.title, kind: f.kind, title: a.title, icon: a.icon, enabled: a.enabled) }
    }

    func load(_ items: [PaletteItem]) { self.items = items; refilter() }

    /// Ranks items: title matches first; keyword matches (PID, path) count but rank below any title match. With an
    /// empty query, commands and destinations come first, then the busiest processes (the list is pre-sorted by CPU).
    func refilter() {
        selection = 0
        if focused != nil { focused = nil }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { results = Array(items.prefix(80)); return }
        var scored: [(Int, Int, PaletteItem)] = []
        for (i, it) in items.enumerated() {
            let t = FuzzyMatch.score(q, it.title)
            let k = it.keywords.isEmpty ? nil : FuzzyMatch.score(q, it.keywords).map { $0 / 4 }
            guard let s = [t, k].compactMap({ $0 }).max() else { continue }
            scored.append((s, i, it))
        }
        // Stable for equal scores: original order (kind, then CPU for processes).
        results = scored.sorted { ($0.0, -$0.1) > ($1.0, -$1.1) }.prefix(80).map(\.2)
    }

    func move(_ d: Int) {
        let n = rows.count
        guard n > 0 else { return }
        selection = (selection + d + n) % n
    }

    /// Return: run the selected command, open an item's actions, or run (or confirm) the selected action.
    /// Returns true when the palette should close.
    func activate(_ index: Int? = nil) -> Bool {
        let i = index ?? selection
        if let f = focused {
            guard i < f.actions.count, f.actions[i].enabled else { return false }
            let a = f.actions[i]
            if a.confirm != nil { pendingConfirm = a; return false }
            perform(a.run); return true
        }
        guard i < results.count, results[i].enabled else { return false }
        let it = results[i]
        if let run = it.run { perform(run); return true }
        if !it.actions.isEmpty { focused = it; selection = 0 }
        return false
    }

    /// Esc: back from an item's actions, else close (returns true).
    func back() -> Bool {
        if focused != nil { focused = nil; selection = 0; return false }
        return true
    }

    /// Runs an action on the next run-loop turn, after the palette has closed, so actions that show a modal panel
    /// (open/save) or a new window don't fight the overlay for focus.
    func perform(_ run: @escaping () -> Void) {
        PowerTools.shared.paletteVisible = false
        DispatchQueue.main.async { run() }
    }

    // MARK: Building the item list

    /// Collects every item from the engine's current state. `openSettings`/`openWindow` come from the view's environment.
    static func items(engine e: Engine, openSettings: @escaping () -> Void, openCompare: @escaping () -> Void) -> [PaletteItem] {
        var out: [PaletteItem] = []
        // Commands, reusing the same Engine methods as the menus and toolbar.
        func cmd(_ title: String, _ icon: String, enabled: Bool = true, keywords: String = "", _ run: @escaping () -> Void) {
            out.append(PaletteItem(id: "cmd:" + title, kind: .command, title: title, icon: icon, enabled: enabled, run: run, keywords: keywords))
        }
        cmd(e.recording ? "Stop Recording" : "Start Recording", e.recording ? "stop.circle" : "record.circle", keywords: "flight recorder") {
            e.recording ? e.stopRecording() : e.startRecording()
        }
        cmd("Save Last 10 Minutes from Black Box…", "square.and.arrow.down", enabled: e.blackBoxEnabled, keywords: "export flightlog") { e.saveBlackBox(minutes: 10) }
        cmd("Replay Black Box (Last 10 Minutes)", "film", enabled: e.blackBoxEnabled) { AppActions.showMain(); e.replayBlackBox(minutes: 10) }
        cmd("Open Flight Log File…", "folder", keywords: "open trace recording flightlog") { e.openTrace() }
        if e.mode == .replay { cmd("Exit Replay", "xmark.circle") { e.exitReplay() } }
        cmd(e.paused ? "Resume Sampling" : "Pause Sampling", e.paused ? "play" : "pause", enabled: e.mode == .live) { e.paused.toggle() }
        cmd("Capture Diagnostics…", "stethoscope", enabled: PowerTools.captureAvailable, keywords: "sysdiagnose report support") { PowerTools.shared.showCapture() }
        cmd("Export Flight Report (PDF)…", "doc.richtext") { e.exportReport() }
        cmd("Compare Recordings…", "rectangle.split.2x1") { openCompare() }
        cmd("Open Settings", "gearshape", keywords: "preferences") { openSettings() }

        // Destinations, then Performance tabs, through the same navigation request the Go menu uses.
        for d in Destination.allCases {
            out.append(PaletteItem(id: "dest:" + d.rawValue, kind: .destination, title: d.rawValue, icon: d.icon,
                                   run: { AppActions.showMain(navigate: d.rawValue, engine: e) }))
        }
        for t in PerfTab.allCases {
            out.append(PaletteItem(id: "perf:" + t.rawValue, kind: .destination, title: "Performance › \(t.rawValue)", icon: Destination.performance.icon,
                                   run: { AppActions.showMain(navigate: "Performance:\(t.rawValue)", engine: e) }))
        }

        // Running apps (not in demo mode: they would be this Mac's real apps).
        let demo = Demo.isEnabled
        if !demo {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let name = app.localizedName else { continue }
                let id = ProcessSampler.identity(of: app.processIdentifier)
                var actions = processActions(name: name, identity: id, path: app.bundleURL?.path ?? "", demo: false, engine: e)
                // App-level quit goes through the app (it can ask to save), as in the Processes view's app rows; it
                // replaces the signal-based Quit / Force Quit.
                actions.removeAll { $0.title.hasPrefix("Quit") || $0.title.hasPrefix("Force Quit") }
                actions.append(PaletteAction(title: "Quit App…", icon: "xmark.circle",
                                             confirm: .init(title: "Quit “\(name)”?", message: "The app will ask to save any unsaved work.", button: "Quit")) { _ = app.terminate() })
                actions.append(PaletteAction(title: "Force Quit App…", icon: "xmark.octagon",
                                             confirm: .init(title: "Force Quit “\(name)”?", message: "Unsaved work in all of its windows will be lost.", button: "Force Quit")) { _ = app.forceTerminate() })
                out.append(PaletteItem(id: "app:\(app.processIdentifier)", kind: .app, title: name,
                                       subtitle: "App · PID \(app.processIdentifier)" + (app.bundleIdentifier.map { " · \($0)" } ?? ""),
                                       icon: "app", iconPath: app.bundleURL.map { $0.path + "/" }, actions: actions,
                                       keywords: "\(app.processIdentifier) \(app.bundleIdentifier ?? "")"))
            }
        }

        // Processes from the latest live sample (the inspector is about processes running now, even during replay).
        let procs = (e.liveSnapshot?.processes ?? []).filter { $0.pid > 0 }.sorted { $0.cpu > $1.cpu }
        for s in procs {
            out.append(PaletteItem(id: "proc:\(s.pid)-\(s.identity.startTime)", kind: .process, title: s.name,
                                   subtitle: "PID \(s.pid) · \(s.user) · \(String(format: "%.0f%%", s.cpu)) CPU · \(s.restricted ? "—" : Fmt.bytes(s.memory))",
                                   icon: "gearshape", iconPath: s.path, actions: processActions(name: s.name, identity: s.identity, path: s.path, demo: demo, engine: e),
                                   keywords: "\(s.pid) \(s.user) \(s.path)"))
        }
        return out
    }

    /// Inspect, sample stacks, reveal, quit and force quit for one process. Disabled in demo mode (the PIDs are
    /// invented and could match real processes), as `AppActions.openInspector` is. Signals go through
    /// ProcessSampler.send, which re-checks PID + start time; failures land in the main window's error alert.
    static func processActions(name: String, identity: ProcessIdentity?, path: String, demo: Bool, engine: Engine) -> [PaletteAction] {
        let live = !demo && identity != nil
        let inspect = AppActions.openInspector
        func send(_ sig: Int32) {
            guard let identity else { return }
            do { try ProcessSampler.send(sig, to: identity) } catch { engine.lastError = error.localizedDescription }
        }
        let pid = identity.map { "\($0.pid)" } ?? "?"
        return [
            PaletteAction(title: "Inspect…", icon: "info.circle", enabled: live && inspect != nil) { if let identity { inspect?(identity) } },
            PaletteAction(title: "Sample Stacks (3 s)", icon: "waveform.path", enabled: live && inspect != nil) {
                guard let identity else { return }
                PowerTools.shared.stackRequest = identity; inspect?(identity)
            },
            PaletteAction(title: "Reveal in Finder", icon: "folder", enabled: !demo && !path.isEmpty) {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            },
            PaletteAction(title: "Quit…", icon: "xmark.circle", enabled: live,
                          confirm: .init(title: "Quit “\(name)”?", message: "PID \(pid). Unsaved work in this process may be lost.", button: "Quit")) { send(SIGTERM) },
            PaletteAction(title: "Force Quit…", icon: "xmark.octagon", enabled: live,
                          confirm: .init(title: "Force Quit “\(name)”?", message: "PID \(pid). Unsaved work in this process may be lost.", button: "Force Quit")) { send(SIGKILL) },
        ]
    }
}

/// The overlay: a dimmed backdrop and a centred panel with the search field and results.
struct CommandPaletteView: View {
    let engine: Engine
    @Environment(\.palette) var p
    @Environment(\.offscreen) private var offscreen
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = PaletteModel()
    /// Lets UIBench render the palette with a query typed in.
    var initialQuery = ""

    func close() { PowerTools.shared.paletteVisible = false }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.3).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let f = model.focused {
                        Text(f.title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(p.accent.opacity(0.2)))
                    } else {
                        Image(systemName: "magnifyingglass").foregroundStyle(p.dim)
                    }
                    PaletteField(text: $model.query, placeholder: model.focused == nil ? "Go to, find a process or app, or run a command" : "Choose an action",
                                 onMove: { model.move($0) }, onSubmit: { if model.activate() { close() } }, onCancel: { if model.back() { close() } })
                        .frame(height: 24)
                }
                .padding(12)
                Divider()
                list
                Divider()
                Text(Demo.isEnabled ? "Demo mode: process actions are disabled." : "↑↓ to move · ⏎ to open or run · esc to go back")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).padding(.vertical, 6)
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 12).fill(p.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.panelBorder))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            .padding(.top, 70)
        }
        .onAppear {
            model.load(PaletteModel.items(engine: engine, openSettings: { openSettings() }, openCompare: { openWindow(id: "compare") }))
            if !initialQuery.isEmpty { model.query = initialQuery }
        }
        .alert(model.pendingConfirm?.confirm?.title ?? "", isPresented: Binding(get: { model.pendingConfirm != nil }, set: { if !$0 { model.pendingConfirm = nil } })) {
            Button(model.pendingConfirm?.confirm?.button ?? "OK", role: .destructive) {
                if let a = model.pendingConfirm { model.perform(a.run) }
                model.pendingConfirm = nil
            }
            Button("Cancel", role: .cancel) { model.pendingConfirm = nil }
        } message: { Text(model.pendingConfirm?.confirm?.message ?? "") }
    }

    /// Up to 80 rows; scrolls to keep the selection visible. Off-screen renders draw a plain stack (ScrollView renders
    /// empty in ImageRenderer).
    @ViewBuilder var list: some View {
        let rows = model.rows
        if rows.isEmpty {
            Text("No matches").foregroundStyle(p.dim).frame(maxWidth: .infinity).padding(20)
        } else if offscreen {
            VStack(spacing: 0) { ForEach(Array(rows.prefix(12).enumerated()), id: \.element.id) { i, r in row(r, i) } }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in row(r, i).id(i) } }
                }
                .frame(maxHeight: 420)
                .onChange(of: model.selection) { proxy.scrollTo(model.selection) }
            }
        }
    }

    func row(_ r: PaletteItem, _ i: Int) -> some View {
        let selected = i == model.selection
        return HStack(spacing: 10) {
            if let path = r.iconPath, model.focused == nil { AppIcon(path: path).frame(width: 18, height: 18) }
            else { Image(systemName: r.icon).frame(width: 18).foregroundStyle(p.accent) }
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).foregroundStyle(r.enabled ? p.text : p.dim).lineLimit(1)
                if !r.subtitle.isEmpty { Text(r.subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1) }
            }
            Spacer()
            if model.focused == nil {
                Text(r.kind.label + (r.actions.isEmpty ? "" : " ›")).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(p.dim)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(selected ? p.accent.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = i; if model.activate(i) { close() } }
    }
}

/// An AppKit text field, because it reliably reports arrow keys, Return and Esc (as `moveUp:`, `insertNewline:`,
/// `cancelOperation:`) through its delegate while keeping normal text editing. Takes focus when it appears.
struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
        f.font = .systemFont(ofSize: 16)
        f.delegate = context.coordinator
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }
    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        f.placeholderString = placeholder
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField
        init(_ p: PaletteField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
