import SwiftUI
import MeterCore

@main
struct MeterlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine = Engine()
    @AppStorage("theme") private var theme: ThemeID = .dark

    var body: some Scene {
        WindowGroup("Meterline") {
            ContentView()
                .environmentObject(engine)
                .environment(\.palette, Palette.of(theme))
                .preferredColorScheme(Palette.of(theme).scheme)
                .frame(minWidth: 980, minHeight: 640)
                .onOpenURL { engine.open($0) }
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
            }
            CommandMenu("Monitor") {
                Button(engine.paused ? "Resume Sampling" : "Pause Sampling") { engine.paused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Picker("Theme", selection: $theme) { ForEach(ThemeID.allCases) { Text($0.title).tag($0) } }
            }
        }
        Settings {
            SettingsView().environmentObject(engine).environment(\.palette, Palette.of(theme))
        }
    }
}

extension Notification.Name { static let openTraceFile = Notification.Name("openTraceFile") }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ app: NSApplication, open urls: [URL]) {
        urls.forEach { NotificationCenter.default.post(name: .openTraceFile, object: $0) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @AppStorage("theme") private var theme: ThemeID = .dark
    var body: some View {
        Form {
            Picker("Theme", selection: $theme) { ForEach(ThemeID.allCases) { Text($0.title).tag($0) } }
            Picker("Sample interval", selection: $engine.interval) {
                Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
            }
            Toggle("Include Meterline in measurements (self-monitoring)", isOn: $engine.includeSelf)
            Text("Meterline sends no data anywhere. All measurements stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 440)
    }
}
