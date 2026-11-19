// Destinations settings (Settings › Alerts) and the process inspector's destinations panel, kept here so the shared
// Settings form and InspectorView each gain a single line.
import SwiftUI
import FlightDeckCore

/// The "new destination" alert is off by default; it becomes a finding, so mutes and the Flight Log apply as usual.
struct DestinationAlertsSection: View {
    @AppStorage(DestinationAlertSettings.enabledKey) private var enabled = false
    @AppStorage(DestinationAlertSettings.browsersKey) private var ignoreBrowsers = true
    @AppStorage(DestinationAlertSettings.localKey) private var includeLocal = false
    @AppStorage(DestinationService.lookupsKey) private var lookups = true

    var body: some View {
        Section("Destinations") {
            Toggle("Notify when an app contacts a destination it hasn't contacted in 30 days", isOn: $enabled)
                .onChange(of: enabled) { if enabled { Alerts.shared.requestPermission() } }
            Toggle("Ignore web browsers", isOn: $ignoreBrowsers).disabled(!enabled)
            Toggle("Include devices on the local network", isOn: $includeLocal).disabled(!enabled)
            Toggle("Name remote hosts by reverse DNS", isOn: $lookups)
                .onChange(of: lookups) { DestinationsModel.applyLookups() }
            Text("An app is learned for a day before its contacts count as new. At most one notification per app per hour; more new destinations within the hour join it. Reverse DNS asks your DNS server for the name of each new remote IP (cached for hours); with it off, destinations are grouped by IP. Destination history stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(Demo.isEnabled)
    }
}

/// The inspected process's app: where it sent and received traffic over the last 30 days. Shown in the inspector's
/// Network tab. The whole app is shown (helpers included), since destinations are recorded per app.
struct DestinationsInspectorPanel: View {
    let process: ProcessSample
    @ObservedObject var model: DestinationsModel
    @Environment(\.palette) var p
    @MainActor init(process: ProcessSample, model: DestinationsModel? = nil) { self.process = process; self.model = model ?? .shared }

    var body: some View {
        let key = AppUsage.key(for: process).key
        let app = model.app(key)
        Panel(title: "Destinations", trailing: app.map { "\($0.destinations.count) in 30 days · whole app" } ?? "whole app") {
            if let app {
                DestinationTable(app: app, range: .month, limit: 12)
            } else {
                Text(model.built == nil ? "Loading…" : "No destinations recorded for this app in the last \(DestinationStore.retentionDays) days.")
                    .foregroundStyle(p.dim)
            }
            Text("From nettop's per-connection counters; names from reverse DNS where the IP has one. See Network › Destinations.")
                .font(.caption).foregroundStyle(p.dim)
        }
        .onAppear { model.refresh() }
    }
}
