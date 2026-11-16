// The optional Prometheus endpoint (Settings › Metrics export). Off by default. When on, a MetricsServer listens on
// 127.0.0.1:<port> and answers each scrape by rendering the Engine's latest live snapshot on the main actor. Between
// scrapes nothing runs: there is no timer and no extra sampling. Never started in demo mode.
import SwiftUI
import FlightDeckCore

@MainActor
final class MetricsEndpoint: ObservableObject {
    static let shared = MetricsEndpoint()
    static let defaultPort = 9464
    /// User defaults keys (also bound with @AppStorage in Settings).
    static let enabledKey = "metricsEnabled", portKey = "metricsPort"

    /// The engine whose snapshots are served; weak so the endpoint never keeps a closed engine alive.
    private weak var engine: Engine?
    private var server: MetricsServer?
    /// Shown in Settings: "Serving on …", or why the listener couldn't start (e.g. the port is in use).
    @Published private(set) var status: String?

    /// Called once by the (non-headless) Engine at launch, then again whenever the settings change.
    func configure(engine: Engine) { self.engine = engine; apply() }

    /// Starts, restarts or stops the server to match the current settings.
    func apply() {
        server?.stop(); server = nil
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.enabledKey), !Demo.isEnabled, engine != nil else { status = nil; return }
        let raw = d.object(forKey: Self.portKey) as? Int ?? Self.defaultPort
        guard (1024...65535).contains(raw) else { status = "Choose a port between 1024 and 65535."; return }
        let port = UInt16(raw)
        // Each scrape hops to the main actor to read `liveSnapshot` (the latest live sample, even while a recording is
        // being replayed; it updates every 5 s while no window is open). Rendering happens there too: it is a few
        // hundred lines of text, cheap enough not to need another copy of the snapshot.
        let s = MetricsServer(port: port) { reply in
            Task { @MainActor in reply(MetricsEndpoint.shared.engine?.liveSnapshot.map(PrometheusText.render)) }
        }
        server = s
        status = "Starting…"
        s.start { err in
            Task { @MainActor in
                // Ignore reports from a server that has since been replaced.
                guard MetricsEndpoint.shared.server === s else { return }
                MetricsEndpoint.shared.status = err.map { "Couldn't listen on port \(port): \($0)" } ?? "Serving http://127.0.0.1:\(port)/metrics"
            }
        }
    }
}

/// Settings section for the endpoint. Lives here rather than in SettingsView to keep that shared file small.
struct MetricsExportSection: View {
    @AppStorage(MetricsEndpoint.enabledKey) private var enabled = false
    @AppStorage(MetricsEndpoint.portKey) private var port = MetricsEndpoint.defaultPort
    @ObservedObject private var endpoint = MetricsEndpoint.shared

    var body: some View {
        Section("Metrics export") {
            Toggle("Serve Prometheus metrics on localhost", isOn: $enabled)
                .disabled(Demo.isEnabled)
            TextField("Port", value: $port, format: .number.grouping(.never)).disabled(!enabled)
            if let s = endpoint.status, enabled { Text(s).font(.caption).monospacedDigit() }
            Text(Demo.isEnabled ? "Not available in demo mode."
                 : "Off by default. When on, FlightDeck answers http://127.0.0.1:\(String(port))/metrics (this Mac only, not the network) with its latest sample in Prometheus text format. It does no work between scrapes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: enabled) { endpoint.apply() }
        .onChange(of: port) { endpoint.apply() }
    }
}
