import SwiftUI
import FlightDeckCore

/// First-run sheet: what FlightDeck does, what it records (locally), and the few choices that need consent.
struct WelcomeView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @Environment(\.dismiss) private var dismiss
    @AppStorage("alertsEnabled") private var alertsEnabled = true
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @State private var loginItem = LoginItem.isEnabled

    func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(p.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: (NSApp?.applicationIconImage) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to FlightDeck").font(.system(size: 22, weight: .bold))
                    Text("Every instrument for your Mac on one panel, and a black box for when something goes wrong.")
                        .font(.system(size: 12)).foregroundStyle(p.dim)
                }
            }
            row("light.beacon.max", "Master caution", "Lights on the Summary, in the menu bar and on the Dock icon tell you when something needs attention, and why, in plain English. Click any light to see the cause.")
            row("record.circle", "Black box (on)", "FlightDeck keeps the last 24 hours (every sample for the last hour), at most 50 MB, on this Mac only. Replay or save any moment from the Recorder menu or the Flight Log.")
            row("magnifyingglass", "Drill down", "Double-click any process for its inspector: history, files, sockets, threads, environment, signature and call stacks. The Processes filter understands queries like cpu>50 mem>1g.")
            row("lock.shield", "Private", "Nothing leaves this Mac. Network latency checks are off unless you turn them on in Settings.")
            Divider()
            Toggle("Notify me about problems that last (macOS will ask for permission)", isOn: $alertsEnabled)
            Toggle("Show in the menu bar and keep running when the window is closed", isOn: $menuBarEnabled)
            Toggle("Open at login (so the black box is always recording)", isOn: Binding(get: { loginItem }, set: { on in
                try? LoginItem.set(on); loginItem = LoginItem.isEnabled
            }))
            HStack {
                Text("You can change all of this later in Settings.").font(.caption).foregroundStyle(p.dim)
                Spacer()
                Button("Get Started") {
                    UserDefaults.standard.set(true, forKey: "welcomed")
                    if alertsEnabled { Alerts.shared.requestPermission() }
                    dismiss()
                }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
