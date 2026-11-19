// Camera & Mic settings (Settings › Alerts) and the menu bar panel's live indicator, kept here so the shared Settings
// form and MenuBarPanel each gain a single line.
import SwiftUI
import FlightDeckCore

/// Both alerts are off by default; they become findings, so mutes and the Flight Log apply as usual.
struct CameraMicAlertsSection: View {
    @AppStorage(CameraMicAlertSettings.firstUseKey) private var firstUse = false
    @AppStorage(CameraMicAlertSettings.lockedKey) private var locked = false
    @AppStorage(CameraMicMenuBarRow.enabledKey) private var menuBar = true

    var body: some View {
        Section("Camera & Mic") {
            Toggle("Notify when an app uses the camera or microphone for the first time", isOn: $firstUse)
                .onChange(of: firstUse) { if firstUse { Alerts.shared.requestPermission() } }
            Toggle("Notify on any camera or microphone use while the screen is locked or the Mac is idle", isOn: $locked)
                .onChange(of: locked) { if locked { Alerts.shared.requestPermission() } }
            Toggle("Show camera and microphone use in the menu bar panel", isOn: $menuBar)
            Text("Idle means no keyboard or mouse input for 5 minutes. These notify at once, without waiting for the delay above. FlightDeck records only that a device was in use, never audio or video, and the history stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(Demo.isEnabled)
    }
}

/// "● CAMERA zoom.us · MICROPHONE zoom.us" while either is in use; nothing otherwise. Clicking opens the page.
struct CameraMicMenuBarRow: View {
    static let enabledKey = "cameraMicMenuBar"
    @AppStorage(enabledKey) private var enabled = true
    @ObservedObject private var model: CameraMicModel
    @MainActor init(model: CameraMicModel? = nil) { self.model = model ?? .shared }
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let kinds = SensorKind.allCases.filter { model.live.inUse($0) }
        if enabled && !kinds.isEmpty {
            Button { dismiss(); AppActions.showMain(navigate: CameraMicFindings.destination, engine: e) } label: {
                HStack(spacing: 10) {
                    ForEach(kinds, id: \.self) { k in
                        HStack(spacing: 4) {
                            Image(systemName: k.icon).foregroundStyle(p.warn)
                            Text(names(k)).lineLimit(1)
                        }.help("\(k.title) in use")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    /// The apps using it, or "in use" if none is known yet.
    func names(_ k: SensorKind) -> String {
        let apps = model.open(k).map(\.appLabel)
        return apps.isEmpty ? "in use" : apps.joined(separator: ", ")
    }
}
