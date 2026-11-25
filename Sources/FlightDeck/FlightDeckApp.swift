// App entry point: declares every scene (main window, process inspector windows, Compare Recordings, the menu bar
// extra and Settings), the app menus, the AppDelegate, and the Settings form. The single Engine created here is shared
// with all scenes through the environment.
import SwiftUI
import FlightDeckCore

/// Before any scene is built, `init` gives the command-line modes (icon rendering, CLI, UI bench) a chance to run and
/// exit, so they never start the GUI or the Engine's sampling (the @StateObject is only created when `body` is first used).
@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    /// The one Engine for the whole app; all windows and the menu bar extra observe the same instance.
    /// In demo mode (`-demo YES`, for screenshots) the engine is headless and fed only synthetic data: nothing on this
    /// Mac is sampled, read from its logs, or written.
    @StateObject private var engine = Engine(headless: Demo.isEnabled)
    @AppStorage("theme") private var theme: ThemeID = .dark
    @AppStorage("dockMode") private var dockMode: DockMode = .cpuHistory
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true

    init() { IconRenderer.handleCommandLine(); CLI.handle() }

    var body: some Scene {
        // The main window is a single `Window` (not a WindowGroup), so there is only ever one; reopening focuses it.
        Window("FlightDeck", id: "main") {
            ContentView()
                .environmentObject(engine)
                .themed(theme)
                .frame(minWidth: 980, minHeight: 640)
                .onOpenURL { engine.open($0) }
                // The Dock tile is drawn by AppKit outside SwiftUI, so it must be told to redraw on theme/mode changes.
                .onChange(of: theme) { DockIconController.shared.refresh() }
                .onChange(of: dockMode) { DockIconController.shared.refresh() }
                // Files opened from Finder arrive at the AppDelegate, which forwards them here as notifications.
                .onReceive(NotificationCenter.default.publisher(for: .openTraceFile)) { n in
                    if let u = n.object as? URL { engine.open(u) }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // No "New Window": there is one main window and documents are traces opened for replay.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) { Button("About FlightDeck") { AboutPanel.show() } }
            CommandMenu("Go") {
                // Every destination, grouped as in the sidebar; ⌘1…⌘9 jump to the first nine in sidebar order.
                let shortcut = Dictionary(uniqueKeysWithValues: SidebarSection.ordered.prefix(9).enumerated().map { ($1, $0 + 1) })
                ForEach(SidebarSection.allCases) { section in
                    if !section.members.isEmpty {
                        Section(section.rawValue) {
                            ForEach(section.members) { d in
                                if let n = shortcut[d] {
                                    Button(d.rawValue) { AppActions.showMain(navigate: d.rawValue, engine: engine) }
                                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                                } else {
                                    Button(d.rawValue) { AppActions.showMain(navigate: d.rawValue, engine: engine) }
                                }
                            }
                        }
                    }
                }
                Divider()
                ForEach(PerfTab.allCases) { t in
                    Button("Performance › \(t.rawValue)") { AppActions.showMain(navigate: "Performance:\(t.rawValue)", engine: engine) }
                }
            }
            CommandMenu("Recorder") {
                Button(engine.recording ? "Stop Recording" : "Start Recording") {
                    engine.recording ? engine.stopRecording() : engine.startRecording()
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Open Trace…") { engine.openTrace() }.keyboardShortcut("o")
                Button("Exit Replay") { engine.exitReplay() }.disabled(engine.mode != .replay)
                OpenCompareButton()
                Divider()
                Menu("Save from Black Box") {
                    ForEach(BlackBoxRange.allCases) { r in Button("Last \(r.title)…") { engine.saveBlackBox(minutes: r.minutes) } }
                }.disabled(!engine.blackBoxEnabled)
                Menu("Replay Black Box") {
                    ForEach(BlackBoxRange.allCases) { r in Button("Last \(r.title)") { engine.replayBlackBox(minutes: r.minutes) } }
                }.disabled(!engine.blackBoxEnabled)
                Button("Replay Last 10 Minutes") { engine.replayBlackBox(minutes: 10) }
                    .keyboardShortcut("b", modifiers: [.command, .shift]).disabled(!engine.blackBoxEnabled)
                Divider()
                Button("Export Flight Report (PDF)…") { engine.exportReport() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export System Metrics (CSV)…") { engine.exportCSV(processes: false) }
                Button("Export Process Metrics (CSV)…") { engine.exportCSV(processes: true) }
                Text(engine.mode == .replay ? "Exports cover the replayed recording" : "Exports cover the last hour of the black box")
            }
            CommandMenu("Monitor") {
                Button(engine.paused ? "Resume Sampling" : "Pause Sampling") { engine.paused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Picker("Theme", selection: $theme) { ForEach(ThemeID.allCases) { Text($0.title).tag($0) } }
                Picker("Dock Icon", selection: $dockMode) { ForEach(DockMode.allCases) { Text($0.rawValue).tag($0) } }
            }
        }
        .commands { PowerToolsCommands() }   // View › Command Palette (⌘K), Help › Capture Diagnostics
        .commands { AmbientCommands(engine: engine) }   // View › Ambient Mode (⌃⌘A), Ambient Mode on Display
        // One inspector window per process identity (PID + start time), so reopening for the same process reuses its
        // window and a recycled PID gets a new one.
        WindowGroup("Inspector", id: "inspector", for: ProcessIdentity.self) { $id in
            InspectorWindow(identity: id)
                .environmentObject(engine)
                .themed(theme)
        }
        .defaultSize(width: 900, height: 760)
        Window("Compare Recordings", id: "compare") {
            CompareView().themed(theme)
        }
        .defaultSize(width: 980, height: 820)
        // The menu bar extra uses the `.window` style (a panel, not a menu) and can be turned off in Settings.
        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarPanel().environmentObject(engine).themed(theme)
        } label: {
            MenuBarLabel().environmentObject(engine)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView().environmentObject(engine).themed(theme)
        }
    }
}

/// Black-box time ranges offered in the Recorder menu; the raw value is the length in minutes.
enum BlackBoxRange: Int, CaseIterable, Identifiable {
    case m5 = 5, m15 = 15, h1 = 60, h6 = 360, h24 = 1440
    var id: Int { rawValue }
    var minutes: Int { rawValue }
    var title: String { minutes < 60 ? "\(minutes) Minutes" : minutes == 60 ? "Hour" : "\(minutes / 60) Hours" }
}

/// Posted by the AppDelegate for each file opened via Finder/Dock; the object is the file URL.
extension Notification.Name { static let openTraceFile = Notification.Name("openTraceFile") }

/// Handles app-lifecycle events SwiftUI doesn't expose: activation, Dock reopen and Dock menu, opening files, quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        // Activation policy is set explicitly so the app gets a Dock icon and menus even when launched as a bare binary.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !Demo.isEnabled { Alerts.shared.start() }   // demo mode never posts notifications
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppActions.showMain() }
        return true
    }
    func application(_ app: NSApplication, open urls: [URL]) {
        urls.forEach { NotificationCenter.default.post(name: .openTraceFile, object: $0) }
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { DockIconController.shared.dockMenu() }
    // Remove the custom Dock tile view on quit so the Dock doesn't keep showing a stale live graph after we exit.
    func applicationWillTerminate(_ n: Notification) { NSApp.dockTile.contentView = nil; NSApp.dockTile.display() }
    /// With the menu bar item on, closing the window keeps FlightDeck running (black box and alerts continue).
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        // Reads UserDefaults directly (the delegate has no @AppStorage); the default matches `menuBarEnabled` above.
        !(UserDefaults.standard.object(forKey: "menuBarEnabled") as? Bool ?? true)
    }
}

/// The Settings window (⌘,). Most options are @AppStorage keys read elsewhere (Engine, Alerts, DockIconController,
/// MenuBarLabel); a few bind straight to Engine properties whose didSet applies the change.
struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @AppStorage("theme") private var theme: ThemeID = .dark
    @AppStorage("dockMode") private var dockMode: DockMode = .cpuHistory
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("animationsEnabled") private var animationsEnabled = true
    /// Stored only once chosen; until then TemperatureUnit.current follows the Mac's region.
    @AppStorage(TemperatureUnit.defaultsKey) private var temperatureUnit: TemperatureUnit = TemperatureUnit.current
    @AppStorage("menuBarStyle") private var menuBarStyle: MenuBarStyle = .gauges
    @AppStorage("alertsEnabled") private var alertsEnabled = true
    @AppStorage("alertMinSeverity") private var alertMinSeverity = 2
    @AppStorage("alertAfterMinutes") private var alertAfterMinutes = 2.0
    // Login item state is read from the system (SMAppService), not stored, so it reflects changes made in System Settings.
    @State private var loginItem = LoginItem.isEnabled
    @State private var mutedCount = 0
    @AppStorage("autoEvidence") private var autoEvidence = true
    @State private var loginError: String?
    @State private var blackBoxBytes: UInt64 = 0
    @State private var confirmClear = false

    /// One Settings tab: a grouped form that scrolls when its content is taller than the window.
    func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }.formStyle(.grouped)
    }

    var body: some View {
        // Tabs, as macOS Settings windows do: the single form had grown taller than most screens.
        TabView {
            tab { 
                Picker("Theme", selection: $theme) { ForEach(ThemeID.allCases) { Text($0.title).tag($0) } }
                Picker("Dock icon", selection: $dockMode) { ForEach(DockMode.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Sample interval", selection: $engine.interval) {
                    Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
                }
                Toggle("Include FlightDeck in measurements (self-monitoring)", isOn: $engine.includeSelf)
                // Read by animated views (the Stress Map); macOS's Reduce Motion also turns them off.
                Toggle("Animate the Stress Map", isOn: $animationsEnabled)
                // Display only: recordings, CSV and Prometheus exports always use °C.
                Picker("Temperature unit", selection: $temperatureUnit) { ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0) } }
                Picker("When no window is open, sample every", selection: $engine.backgroundInterval) {
                    Text("1 s (same as visible)").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
                }
                Text("Keeps FlightDeck light in the background. The black box, findings and alerts keep running.")
                    .font(.caption).foregroundStyle(.secondary)
                Section("Menu bar") {
                    Toggle("Show in menu bar (keeps running when the window is closed)", isOn: $menuBarEnabled)
                    Picker("Menu bar shows", selection: $menuBarStyle) { ForEach(MenuBarStyle.allCases) { Text($0.rawValue).tag($0) } }
                        .disabled(!menuBarEnabled)
                    MenuBarTemperatureSettings().disabled(!menuBarEnabled)
                    Toggle("Open at login", isOn: Binding(get: { loginItem }, set: { on in
                        do { try LoginItem.set(on); loginItem = LoginItem.isEnabled } catch { loginError = error.localizedDescription }
                    }))
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }
            tab {
                Section("Alerts") {
                    Toggle("Notify me about sustained problems", isOn: $alertsEnabled)
                        .onChange(of: alertsEnabled) { if alertsEnabled { Alerts.shared.requestPermission() } }
                    Picker("Notify for", selection: $alertMinSeverity) { Text("Cautions and warnings").tag(2); Text("Warnings only").tag(3) }
                        .disabled(!alertsEnabled)
                    Picker("After it lasts", selection: $alertAfterMinutes) {
                        Text("1 minute").tag(1.0); Text("2 minutes").tag(2.0); Text("5 minutes").tag(5.0); Text("10 minutes").tag(10.0)
                    }.disabled(!alertsEnabled)
                    HStack {
                        Text("Muted alerts: \(mutedCount)").font(.caption)
                        Spacer()
                        // `muted` holds finding keys the user silenced from a finding's context menu.
                        Button("Unmute All") { Alerts.shared.muted = []; mutedCount = 0 }.disabled(mutedCount == 0)
                    }.onAppear { mutedCount = Alerts.shared.muted.count }
                    Toggle("Capture call stacks automatically when an app hangs or hogs the CPU", isOn: $autoEvidence)
                    Text("Right-click any finding to mute its alerts, inspect the responsible process or quit its app.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("An app is \"busy\" above", selection: $engine.appCPUThreshold) {
                        Text("50% of a core").tag(50.0); Text("80% of a core").tag(80.0); Text("1.5 cores").tag(150.0); Text("3 cores").tag(300.0)
                    }
                }
                TemperatureAlertsSection()
                CameraMicAlertsSection()
                DestinationAlertsSection()
                WeeklyReportSettingsSection()
            }
            .tabItem { Label("Alerts", systemImage: "bell.badge") }
            tab {
                Section("Black box") {
                    Toggle("Always-on black box recorder", isOn: $engine.blackBoxEnabled)
                    Text("Keeps every sample for the last hour and one sample every 10 s for 24 hours (at most 50 MB), so you can save or replay what happened after the fact.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("Using \(Fmt.bytes(blackBoxBytes))").font(.caption).monospacedDigit()
                        if let err = engine.blackBox.lastWriteError {
                            Text("Can't write: \(err)").font(.caption).foregroundStyle(.red).lineLimit(2).help(err)
                        }
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([engine.blackBox.dir]) }
                        Button("Clear…") { confirmClear = true }
                    }
                }
            }
            .tabItem { Label("Recording", systemImage: "record.circle") }
            tab {
                Section("Network quality") {
                    Toggle("Measure latency and packet loss", isOn: $engine.netProbeEnabled)
                    TextField("Internet host to ping", text: $engine.netProbeHost).disabled(!engine.netProbeEnabled)
                    Text("Off by default. When on, FlightDeck pings your router and this host every 10 seconds (5 small ICMP packets each) to tell Wi-Fi problems from internet-provider problems.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                UniFiSettingsSection()
                SpeedTestSettingsSection()
                FleetSettingsSection()
                // Kept honest as features are added: list every way FlightDeck itself touches the network.
                Text("FlightDeck sends no data off this Mac. It only uses the network when you ask: latency pings (if on above), "
                     + "device discovery while the Network or UPnP page is open, scans and traceroutes you start there, and your "
                     + "UniFi console once you've set it up, and speed tests you run or schedule (against Apple's test servers). The metrics and MCP servers listen on this Mac only. "
                     + "Fleet (if you share this Mac or pair with one) talks only to your paired Macs on the local network."
                     + " Update checks, if on in Settings › About, ask GitHub once a day for the latest release; Check Now there asks once when clicked, even with them off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Network", systemImage: "network") }
            tab {
                MetricsExportSection()
                MCPSection()
            }
            .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            tab { AboutSettingsSection() }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 560)
        // Poll black box disk usage while Settings is open; it changes as samples are written.
        .task { while !Task.isCancelled { blackBoxBytes = engine.blackBox.diskUsage; try? await Task.sleep(for: .seconds(5)) } }
        .confirmationDialog("Delete all black box data?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) { engine.clearBlackBox(); blackBoxBytes = 0 }
        }
    }
}

/// Opens the Compare Recordings window; a separate view because `openWindow` is only available from the environment.
struct OpenCompareButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Compare Recordings…") { openWindow(id: "compare") } }
}

/// FlightDeck › About: the standard macOS About panel, with the version from the bundle (stamped from the git tag by
/// scripts/bundle.sh and the release workflow), the author, and a credit to Claude, which helped build it.
enum AboutPanel {
    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        let body = NSFont.systemFont(ofSize: 11), bold = NSFont.boldSystemFont(ofSize: 11)
        let centered = NSMutableParagraphStyle(); centered.alignment = .center; centered.paragraphSpacing = 4
        func line(_ s: String, _ f: NSFont, _ c: NSColor = .labelColor) -> NSAttributedString {
            NSAttributedString(string: s + "\n", attributes: [.font: f, .foregroundColor: c, .paragraphStyle: centered])
        }
        let credits = NSMutableAttributedString()
        credits.append(line("By Charlie Meyer", bold))
        credits.append(line("Built with Claude, by Anthropic", body, .secondaryLabelColor))
        credits.append(line("A flight deck for your Mac: every instrument on one panel, and a black box for when something goes wrong.", body, .secondaryLabelColor))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "FlightDeck",
            .applicationVersion: version,
            .version: build,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© \(Calendar.current.component(.year, from: Date())) Charlie Meyer",
        ])
    }
}
