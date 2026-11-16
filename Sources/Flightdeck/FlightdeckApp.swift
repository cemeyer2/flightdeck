import SwiftUI
import FlightdeckCore

@main
struct FlightdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine = Engine()
    @AppStorage("theme") private var theme: ThemeID = .dark
    @AppStorage("dockMode") private var dockMode: DockMode = .cpuHistory
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true

    init() { IconRenderer.handleCommandLine() }

    var body: some Scene {
        Window("Flightdeck", id: "main") {
            ContentView()
                .environmentObject(engine)
                .environment(\.palette, Palette.of(theme))
                .preferredColorScheme(Palette.of(theme).scheme)
                .frame(minWidth: 980, minHeight: 640)
                .onOpenURL { engine.open($0) }
                .onChange(of: theme) { DockIconController.shared.refresh() }
                .onChange(of: dockMode) { DockIconController.shared.refresh() }
                .onReceive(NotificationCenter.default.publisher(for: .openTraceFile)) { n in
                    if let u = n.object as? URL { engine.open(u) }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Recorder") {
                Button(engine.recording ? "Stop Recording" : "Start Recording") {
                    engine.recording ? engine.stopRecording() : engine.startRecording()
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Open Trace…") { engine.openTrace() }.keyboardShortcut("o")
                Button("Exit Replay") { engine.exitReplay() }.disabled(engine.mode != .replay)
                Divider()
                Menu("Save from Black Box") {
                    ForEach(BlackBoxRange.allCases) { r in Button("Last \(r.title)…") { engine.saveBlackBox(minutes: r.minutes) } }
                }.disabled(!engine.blackBoxEnabled)
                Menu("Replay Black Box") {
                    ForEach(BlackBoxRange.allCases) { r in Button("Last \(r.title)") { engine.replayBlackBox(minutes: r.minutes) } }
                }.disabled(!engine.blackBoxEnabled)
                Button("Replay Last 10 Minutes") { engine.replayBlackBox(minutes: 10) }
                    .keyboardShortcut("b", modifiers: [.command, .shift]).disabled(!engine.blackBoxEnabled)
            }
            CommandMenu("Monitor") {
                Button(engine.paused ? "Resume Sampling" : "Pause Sampling") { engine.paused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Picker("Theme", selection: $theme) { ForEach(ThemeID.allCases) { Text($0.title).tag($0) } }
                Picker("Dock Icon", selection: $dockMode) { ForEach(DockMode.allCases) { Text($0.rawValue).tag($0) } }
            }
        }
        WindowGroup("Inspector", id: "inspector", for: ProcessIdentity.self) { $id in
            InspectorWindow(identity: id)
                .environmentObject(engine)
                .environment(\.palette, Palette.of(theme))
                .preferredColorScheme(Palette.of(theme).scheme)
        }
        .defaultSize(width: 900, height: 760)
        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarPanel().environmentObject(engine).environment(\.palette, Palette.of(theme))
        } label: {
            MenuBarLabel().environmentObject(engine)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView().environmentObject(engine).environment(\.palette, Palette.of(theme))
        }
    }
}

enum BlackBoxRange: Int, CaseIterable, Identifiable {
    case m5 = 5, m15 = 15, h1 = 60, h6 = 360, h24 = 1440
    var id: Int { rawValue }
    var minutes: Int { rawValue }
    var title: String { minutes < 60 ? "\(minutes) Minutes" : minutes == 60 ? "Hour" : "\(minutes / 60) Hours" }
}

extension Notification.Name { static let openTraceFile = Notification.Name("openTraceFile") }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Alerts.shared.start()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppActions.showMain() }
        return true
    }
    func application(_ app: NSApplication, open urls: [URL]) {
        urls.forEach { NotificationCenter.default.post(name: .openTraceFile, object: $0) }
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { DockIconController.shared.dockMenu() }
    func applicationWillTerminate(_ n: Notification) { NSApp.dockTile.contentView = nil; NSApp.dockTile.display() }
    /// With the menu bar item on, closing the window keeps Flightdeck running (black box and alerts continue).
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "menuBarEnabled") as? Bool ?? true)
    }
}

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @AppStorage("theme") private var theme: ThemeID = .dark
    @AppStorage("dockMode") private var dockMode: DockMode = .cpuHistory
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("menuBarStyle") private var menuBarStyle: MenuBarStyle = .gauges
    @AppStorage("alertsEnabled") private var alertsEnabled = true
    @AppStorage("alertMinSeverity") private var alertMinSeverity = 2
    @AppStorage("alertAfterMinutes") private var alertAfterMinutes = 2.0
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var blackBoxBytes: UInt64 = 0
    @State private var confirmClear = false
    var body: some View {
        Form {
            Picker("Theme", selection: $theme) { ForEach(ThemeID.allCases) { Text($0.title).tag($0) } }
            Picker("Dock icon", selection: $dockMode) { ForEach(DockMode.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Sample interval", selection: $engine.interval) {
                Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
            }
            Toggle("Include Flightdeck in measurements (self-monitoring)", isOn: $engine.includeSelf)
            Section("Menu bar and alerts") {
                Toggle("Show in menu bar (keeps running when the window is closed)", isOn: $menuBarEnabled)
                Picker("Menu bar shows", selection: $menuBarStyle) { ForEach(MenuBarStyle.allCases) { Text($0.rawValue).tag($0) } }
                    .disabled(!menuBarEnabled)
                Toggle("Open at login", isOn: Binding(get: { loginItem }, set: { on in
                    do { try LoginItem.set(on); loginItem = LoginItem.isEnabled } catch { loginError = error.localizedDescription }
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Notify me about sustained problems", isOn: $alertsEnabled)
                    .onChange(of: alertsEnabled) { if alertsEnabled { Alerts.shared.requestPermission() } }
                Picker("Notify for", selection: $alertMinSeverity) { Text("Cautions and warnings").tag(2); Text("Warnings only").tag(3) }
                    .disabled(!alertsEnabled)
                Picker("After it lasts", selection: $alertAfterMinutes) {
                    Text("1 minute").tag(1.0); Text("2 minutes").tag(2.0); Text("5 minutes").tag(5.0); Text("10 minutes").tag(10.0)
                }.disabled(!alertsEnabled)
                Picker("An app is \"busy\" above", selection: $engine.appCPUThreshold) {
                    Text("50% of a core").tag(50.0); Text("80% of a core").tag(80.0); Text("1.5 cores").tag(150.0); Text("3 cores").tag(300.0)
                }
            }
            Section("Black box") {
                Toggle("Always-on black box recorder", isOn: $engine.blackBoxEnabled)
                Text("Keeps every sample for the last hour and one sample every 10 s for 24 hours (at most 50 MB), so you can save or replay what happened after the fact.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Using \(Fmt.bytes(blackBoxBytes))").font(.caption).monospacedDigit()
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([engine.blackBox.dir]) }
                    Button("Clear…") { confirmClear = true }
                }
            }
            Text("Flightdeck sends no data anywhere. All measurements stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 480)
        .task { while !Task.isCancelled { blackBoxBytes = engine.blackBox.diskUsage; try? await Task.sleep(for: .seconds(5)) } }
        .confirmationDialog("Delete all black box data?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) { engine.clearBlackBox(); blackBoxBytes = 0 }
        }
    }
}
