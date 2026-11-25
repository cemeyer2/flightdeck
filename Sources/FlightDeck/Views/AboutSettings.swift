// Settings › About: this copy's version and the opt-in update check (`updateCheck.enabled`, read by ReleaseCheckModel
// at each hourly wake). Check Now works with the toggle off, one request per click. Links go only to this repo's
// releases on github.com (validated in ReleaseInfo).
import SwiftUI
import FlightDeckCore

struct AboutSettingsSection: View {
    @ObservedObject var model = ReleaseCheckModel.shared
    @AppStorage(ReleaseCheckModel.enabledKey) private var enabled = false

    /// Demo mode reads no `updateCheck.*` key, so the (disabled) toggle shows off rather than the real default.
    private var enabledBinding: Binding<Bool> { Demo.isEnabled ? .constant(false) : $enabled }

    var body: some View {
        Section {
            LabeledContent("Version", value: model.versionText)
            LabeledContent("Latest release") {
                if let latest = model.state.latest {
                    HStack(spacing: 0) { Text(latest.version.description + " — "); Link("View Release", destination: latest.url) }
                } else {
                    Text("—")
                }
            }
            Toggle("Check for updates once a day", isOn: enabledBinding)
                .onChange(of: enabled) { model.enabledChanged(enabled) }
                .disabled(Demo.isEnabled || model.installed == nil)
            Text("Off by default. When on, FlightDeck asks GitHub once a day whether a newer release of FlightDeck exists. Check Now asks once, whenever you click it, even with this off. It sends no information about this Mac or this copy of FlightDeck; GitHub sees your IP address as with any web request. Nothing is downloaded.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Last checked") {
                    Text(model.state.lastCheckedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                }
                let status = model.status
                HStack(spacing: 4) {
                    Text(status.text)
                    if status.updateAvailable, let latest = model.state.latest { Link("View Release", destination: latest.url) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let error = status.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            // Redrawn every 30 s so a rate limit's "Try again after" clears, and Check Now re-enables, once it passes.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                HStack {
                    Button("Check Now") { Task { await model.checkNow() } }
                        .disabled(model.availability != .available)
                    if model.inFlight { ProgressView().controlSize(.small) }
                    if case .rateLimited(let until) = model.availability {
                        Text("Try again after \(until.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
