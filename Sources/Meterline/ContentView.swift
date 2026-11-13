import SwiftUI
import MeterCore

enum Destination: String, CaseIterable, Identifiable, Hashable {
    case summary = "Summary", performance = "Performance", processes = "Processes", systemInfo = "System Info",
         startup = "Startup Apps", users = "Users", services = "Services", power = "Power & Freq",
         connections = "Connections", apps = "Installed Apps", diskSpace = "Disk Space", benchmarks = "Benchmarks"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .summary: "gauge.with.dots.needle.50percent"
        case .performance: "waveform.path.ecg"
        case .processes: "list.bullet.indent"
        case .systemInfo: "info.circle"
        case .startup: "power"
        case .users: "person.2"
        case .services: "gearshape.2"
        case .power: "bolt"
        case .connections: "network"
        case .apps: "square.grid.2x2"
        case .diskSpace: "internaldrive"
        case .benchmarks: "speedometer"
        }
    }
    var isLive: Bool { [.summary, .performance, .processes, .power].contains(self) }
}

struct ContentView: View {
    @Environment(\.palette) var p
    @SceneStorage("destination") private var selection: Destination = .summary
    @AppStorage("theme") private var theme: ThemeID = .dark

    var body: some View {
        NavigationSplitView {
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
        .onAppear {
            // Debug/automation hook: `open Meterline.app --args -destination "Processes"`
            if let d = UserDefaults.standard.string(forKey: "destination").flatMap(Destination.init(rawValue:)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selection = d }
            }
        }
    }

    @ViewBuilder var detail: some View {
        switch selection {
        case .summary: SummaryView()
        case .performance: PerformanceView()
        case .processes: ProcessesView()
        case .systemInfo: SystemInfoView()
        case .startup: StartupView()
        case .users: UsersView()
        case .services: ServicesView()
        case .power: PowerView()
        case .connections: ConnectionsView()
        case .apps: InstalledAppsView()
        case .diskSpace: DiskSpaceView()
        case .benchmarks: BenchmarksView()
        }
    }

}

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
                .help("Open a .mltrace recording")
            Menu {
                Picker("Theme", selection: $theme) { ForEach(ThemeID.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline)
            } label: { Label("Theme", systemImage: "paintpalette") }
    }
}

struct ErrorAlert: ViewModifier {
    @EnvironmentObject var engine: Engine
    func body(content: Content) -> some View {
        content.alert("Meterline", isPresented: Binding(get: { engine.lastError != nil }, set: { if !$0 { engine.lastError = nil } })) {
            Button("OK") { engine.lastError = nil }
        } message: { Text(engine.lastError ?? "") }
    }
}

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

struct ReplayBar: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.palette) var p
    var body: some View {
        if let t = engine.trace {
            HStack(spacing: 12) {
                Image(systemName: "film").foregroundStyle(p.accent)
                Text("REPLAY · \(t.host)").font(.system(size: 11, weight: .bold, design: .monospaced))
                Button { engine.togglePlay() } label: { Image(systemName: engine.playing ? "pause.fill" : "play.fill") }
                Button { engine.replayIndex = max(0, engine.replayIndex - 1) } label: { Image(systemName: "backward.frame.fill") }
                Button { engine.replayIndex = min(t.frames.count - 1, engine.replayIndex + 1) } label: { Image(systemName: "forward.frame.fill") }
                Slider(value: Binding(get: { Double(engine.replayIndex) }, set: { engine.replayIndex = Int($0) }),
                       in: 0...Double(max(t.frames.count - 1, 1)))
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
