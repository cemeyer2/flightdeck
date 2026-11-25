// Settings › About: this copy's version and the opt-in update check (`updateCheck.enabled`, read by ReleaseCheckModel
// at each hourly wake). Check Now works with the toggle off, one request per click. Links go only to this repo's
// releases on github.com (validated in ReleaseInfo).
import SwiftUI
import FlightDeckCore

struct AboutSettingsSection: View {
    @ObservedObject var model = ReleaseCheckModel.shared
    @AppStorage(ReleaseCheckModel.enabledKey) private var enabled = false

    /// The latest release, only when it's newer than this copy.
    private var update: ReleaseInfo? {
        guard let l = model.state.latest, let i = model.installed, ReleaseVersion.isNewer(remote: l.version, installed: i) else { return nil }
        return l
    }

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
            Toggle("Check for updates once a day", isOn: $enabled)
                .onChange(of: enabled) { model.enabledChanged(enabled) }
                .disabled(Demo.isEnabled || model.installed == nil)
            Text("Off by default. When on, FlightDeck asks GitHub once a day whether a newer release of FlightDeck exists. Check Now asks once, whenever you click it, even with this off. It sends no information about this Mac or this copy of FlightDeck; GitHub sees your IP address as with any web request. Nothing is downloaded.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Last checked") {
                    Text(model.state.lastCheckedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                }
                HStack(spacing: 4) {
                    Text(model.statusText)
                    if let update { Link("View Release", destination: update.url) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Check Now") { Task { await model.checkNow() } }
                    .disabled(model.availability != .available)
                if model.inFlight { ProgressView().controlSize(.small) }
                switch model.availability {
                case .rateLimited(let until):
                    Text("Try again after \(until.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                case .demo:
                    Text("Not available in demo mode").font(.caption).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
        }
    }
}
