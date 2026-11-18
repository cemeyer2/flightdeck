// The main window: a sidebar of destinations, the selected destination's view below the replay bar, the toolbar, the
// first-run welcome sheet, and handling of `Engine.navigationRequest` (how findings, menus and notifications jump to a
// screen).
import SwiftUI
import FlightDeckCore

/// Sidebar destinations. The raw value is the visible title and also the navigation key used by
/// `Engine.navigationRequest`, finding destinations, notification payloads and the `-destination` launch argument,
/// so renaming a case changes those strings too.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case summary = "Summary", stressMap = "Stress Map", flightLog = "Flight Log", rules = "Rules", performance = "Performance", processes = "Processes", systemInfo = "System Info",
         startup = "Startup Apps", users = "Users", services = "Services", power = "Power & Freq", sleep = "Sleep & Wake",
         connections = "Connections", apps = "Installed Apps", diskSpace = "Disk Space", benchmarks = "Benchmarks",
         launches = "Launches", console = "Console", trends = "Trends", checkup = "Checkup", peripherals = "Peripherals",
         unifi = "UniFi"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .summary: "gauge.with.dots.needle.50percent"
        case .stressMap: "circle.hexagongrid"
        case .flightLog: "list.bullet.clipboard"
        case .rules: "bolt.badge.automatic"
        case .performance: "waveform.path.ecg"
        case .processes: "list.bullet.indent"
        case .systemInfo: "info.circle"
        case .startup: "power"
        case .users: "person.2"
        case .services: "gearshape.2"
        case .power: "bolt"
        case .sleep: "moon.zzz"
        case .connections: "network"
        case .apps: "square.grid.2x2"
        case .diskSpace: "internaldrive"
        case .benchmarks: "speedometer"
        case .launches: "arrow.triangle.2.circlepath"
        case .console: "exclamationmark.bubble"
        case .trends: "chart.xyaxis.line"
        case .checkup: "checkmark.shield"
        case .peripherals: "cable.connector.horizontal"
        case .unifi: "wifi.router"
        }
    }
}

/// Main window content. Selection and Performance tab are per-window scene storage, so they survive relaunches.
struct ContentView: View {
    @Environment(\.palette) var p
    @SceneStorage("destination") private var selection: Destination = .summary
    @SceneStorage("perfTab") private var perfTab: PerfTab = .cpu
    @EnvironmentObject var engine: Engine
    @Environment(\.openWindow) private var openWindow
    // Shown on first launch until WelcomeView sets "welcomed"; "skipWelcome" lets automation suppress it.
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: "welcomed") && !UserDefaults.standard.bool(forKey: "skipWelcome")

    var body: some View {
        NavigationSplitView {
            // The binding ignores nil so clicking empty sidebar space can't deselect everything.
            List(Destination.allCases, selection: Binding(get: { selection }, set: { if let v = $0 { selection = v } })) { d in
                Label(d.rawValue, systemImage: d.icon).tag(d)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            VStack(spacing: 0) {
                ReplayBar()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(p.background)
            }
            .navigationTitle(selection.rawValue)
        }
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { ToolbarControls() } }
        .modifier(ErrorAlert())
        .modifier(PowerToolsOverlay())   // command palette (⌘K) and Capture Diagnostics sheet
        .sheet(isPresented: $showWelcome) { WelcomeView().environmentObject(engine).environment(\.palette, p) }
        // Requests look like "Processes" or "Performance:GPU". Cleared immediately so the same request can be made again.
        .onChange(of: engine.navigationRequest) {
            guard let r = engine.navigationRequest else { return }
            engine.navigationRequest = nil
            let parts = r.split(separator: ":").map(String.init)
            if let d = Destination(rawValue: parts[0]) { selection = d }
            if parts.count > 1, let t = PerfTab(rawValue: parts[1]) { perfTab = t }
        }
        .onAppear {
            if Demo.isEnabled && engine.demoSleep == nil { Demo.start(engine) }   // screenshot mode: synthetic data only
            // The inspector WindowGroup is opened by value (a ProcessIdentity), which only a SwiftUI view can do.
            // (Not in demo mode: demo PIDs are invented and could match real processes, whose details must not be shown.)
            AppActions.openInspector = Demo.isEnabled ? nil : { openWindow(id: "inspector", value: $0) }
            // automation hook: `-inspectPID 123` opens the inspector for that process
            let ipid = UserDefaults.standard.integer(forKey: "inspectPID")
            if ipid > 0, let id = ProcessSampler.identity(of: Int32(ipid)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { openWindow(id: "inspector", value: id) }
            }
            // Fallback in case the menu bar item (which normally installs this) is turned off.
            if Alerts.shared.onOpen == nil { Alerts.shared.onOpen = { [engine] d in AppActions.showMain(navigate: d, engine: engine) } }
            // Debug/automation hook: `open FlightDeck.app --args -destination "Processes"`
            if let d = UserDefaults.standard.string(forKey: "destination").flatMap(Destination.init(rawValue:)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selection = d }
            }
        }
    }

    @ViewBuilder var detail: some View {
        switch selection {
        case .summary: SummaryView()
        case .stressMap: StressMapView()
        case .flightLog: FlightLogView()
        case .rules: RulesView()
        case .performance: PerformanceView()
        case .processes: ProcessesView()
        case .systemInfo: SystemInfoView()
        case .startup: StartupView()
        case .users: UsersView()
        case .services: ServicesView()
        case .power: PowerView()
        case .sleep: SleepView()
        case .connections: ConnectionsView()
        case .apps: InstalledAppsView()
        case .diskSpace: DiskSpaceView()
        case .benchmarks: BenchmarksView()
        case .launches: LaunchesView()
        case .console: ConsoleView()
        case .trends: TrendsView()
        case .checkup: CheckupView()
        case .peripherals: PeripheralsView()
        case .unifi: UniFiView()
        }
    }

}

/// Toolbar: pause/resume, sample interval, Flight Recorder record/stop, open trace, theme. Pause is disabled in replay
/// (live sampling keeps running there regardless).
struct ToolbarControls: View {
    @EnvironmentObject var engine: Engine
    @AppStorage("theme") private var theme: ThemeID = .dark
    var body: some View {
            Button { engine.paused.toggle() } label: {
                Label(engine.paused ? "Resume" : "Pause", systemImage: engine.paused ? "play.fill" : "pause.fill")
            }.help(engine.paused ? "Resume sampling" : "Pause sampling (graphs will show a gap)")
            .disabled(engine.mode == .replay)
            Picker("Interval", selection: $engine.interval) {
                Text("0.5s").tag(0.5); Text("1s").tag(1.0); Text("2s").tag(2.0); Text("5s").tag(5.0)
            }.pickerStyle(.menu).frame(width: 70).help("Sample interval")
            Button {
                engine.recording ? engine.stopRecording() : engine.startRecording()
            } label: {
                Label(engine.recording ? "Stop" : "Record", systemImage: engine.recording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(engine.recording ? .red : .primary)
            }.help("Flight Recorder: record all telemetry panels")
            Button { engine.openTrace() } label: { Label("Open Trace", systemImage: "folder") }
                .help("Open a .flightlog recording")
            Menu {
                Picker("Theme", selection: $theme) { ForEach(ThemeID.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline)
            } label: { Label("Theme", systemImage: "paintpalette") }
    }
}

/// Presents `engine.lastError` as an alert; dismissing it clears the error.
struct ErrorAlert: ViewModifier {
    @EnvironmentObject var engine: Engine
    func body(content: Content) -> some View {
        content.alert("FlightDeck", isPresented: Binding(get: { engine.lastError != nil }, set: { if !$0 { engine.lastError = nil } })) {
            Button("OK") { engine.lastError = nil }
        } message: { Text(engine.lastError ?? "") }
    }
}

/// Bottom of the sidebar: recording frame count and the LIVE / PAUSED / REPLAY state.
struct SidebarFooter: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if engine.recording {
                HStack { Circle().fill(.red).frame(width: 8, height: 8); Text("REC \(engine.recorded.count) frames") }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            Text(engine.mode == .replay ? "REPLAY" : (engine.paused ? "PAUSED" : "LIVE · \(engine.interval, specifier: "%.1f")s"))
                .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
}

/// Transport controls shown above the detail view only while a trace is loaded. Changing `replayIndex` makes the
/// Engine rebuild `frames`/`current`, so every view shows the replayed moment.
struct ReplayBar: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.palette) var p
    var body: some View {
        if let t = engine.trace {
            HStack(spacing: 12) {
                Image(systemName: "film").foregroundStyle(p.accent)
                Text("REPLAY · \(t.host)").font(.system(size: 11, weight: .bold, design: .monospaced))
                if engine.replayAnalyzing {
                    // findings for the recording are being computed in the background; scrubbing already works
                    ProgressView().controlSize(.small)
                    Text("analysing…").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                }
                Button { engine.togglePlay() } label: { Image(systemName: engine.playing ? "pause.fill" : "play.fill") }
                Button { engine.replayIndex = max(0, engine.replayIndex - 1) } label: { Image(systemName: "backward.frame.fill") }
                Button { engine.replayIndex = min(t.frames.count - 1, engine.replayIndex + 1) } label: { Image(systemName: "forward.frame.fill") }
                // The upper bound is at least 1 because a closed range needs distinct ends; Engine clamps the index.
                if t.frames.count > 1 {
                    Slider(value: Binding(get: { Double(engine.replayIndex) }, set: { engine.replayIndex = Int($0) }),
                           in: 0...Double(t.frames.count - 1))
                } else { Spacer() }   // a one-frame recording has nothing to scrub
                Text("\(engine.replayIndex + 1)/\(t.frames.count)").font(.system(size: 11, design: .monospaced)).monospacedDigit()
                if let c = engine.current {
                    Text(c.time.formatted(date: .abbreviated, time: .standard)).font(.system(size: 11, design: .monospaced))
                }
                Button("Exit Replay") { engine.exitReplay() }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(p.panel)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
