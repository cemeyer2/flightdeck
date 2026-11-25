// The optional web dashboard (Settings › Integrations › Web dashboard). Off by default. When on, a
// WebDashboardServer listens on every interface and serves the page, /api/state and /api/stream to browsers on the
// local network (and, only when the user lists them, a detected tailnet or, under Advanced, other addresses). Every
// decision is a FlightDeckCore call; this file only reads Engine state and settings and hands them over. The Engine
// subscription that feeds streams exists only while a browser has one open. Never started in demo mode.
import SwiftUI
import Combine
import Network
import SystemConfiguration
import CoreImage.CIFilterBuiltins
import os
import FlightDeckCore

@MainActor
final class WebDashboardEndpoint: ObservableObject {
    static let shared = WebDashboardEndpoint()
    static let defaultPort = 9466
    /// User defaults keys (also bound with @AppStorage in Settings).
    static let enabledKey = "webDashboardEnabled", portKey = "webDashboardPort", allowlistKey = "webDashboardAllowlist",
               advancedKey = "webDashboardAdvanced", nameKey = "webDashboardName"
    /// Refused connections are logged here (Console, category "web-dashboard"), at most once a minute per address.
    nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlightDeck", category: "web-dashboard")

    private weak var engine: Engine?
    private var server: WebDashboardServer?
    private var pathMonitor: NWPathMonitor?
    private var debounce: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var modelRequested = false
    private lazy var redaction = FleetRedaction.current
    /// Shown in Settings: "Serving …", or why the server isn't running.
    @Published private(set) var status: String?
    @Published private(set) var urls: [String] = []
    /// The network as last read, for Settings' entry labels and suggestions.
    @Published private(set) var context: WebNetworkContext?
    /// Marketing model name, the default page label (never the computer name). "Mac" until system_profiler answers.
    @Published private(set) var modelName = "Mac"

    /// Called once by the (non-headless) Engine at launch.
    func configure(engine: Engine) { self.engine = engine; apply() }

    /// Whether the server is set up; the Engine then computes the dashboard's helper-free findings (WebDashboardFeed).
    var isOn: Bool { server != nil }

    private var allowlist: WebAllowlist { .parse(UserDefaults.standard.string(forKey: Self.allowlistKey) ?? "") }

    /// Starts, restarts or stops the server to match the current settings.
    func apply() {
        stopServer()
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.enabledKey), !Demo.isEnabled, engine != nil else { status = nil; return }
        readModelName()
        let raw = d.object(forKey: Self.portKey) as? Int ?? Self.defaultPort
        guard (1024...65535).contains(raw) else { status = "Choose a port between 1024 and 65535."; return }
        let port = UInt16(raw)
        let allow = allowlist
        let ctx = readContext()
        context = ctx
        guard allow.invalid.isEmpty else { status = WebDashboardServer.invalidAllowlist; return }
        final class Ref: @unchecked Sendable { weak var server: WebDashboardServer? }
        let ref = Ref()
        let s = WebDashboardServer(port: port, context: ctx, allowlist: allow, provider: { withHistory, reply in
            Task { @MainActor in WebDashboardEndpoint.shared.document(withHistory: withHistory, reply: reply) }
        }, onStreamCount: { n in
            Task { @MainActor in
                guard let s = ref.server, WebDashboardEndpoint.shared.server === s else { return }
                WebDashboardEndpoint.shared.streamCount(n)
            }
        }, log: { Self.logger.notice("\($0, privacy: .public)") })
        ref.server = s
        server = s
        status = "Starting…"
        s.start { err in
            Task { @MainActor in
                // Ignore reports from a server that has since been replaced.
                guard WebDashboardEndpoint.shared.server === s else { return }
                if let err {
                    WebDashboardEndpoint.shared.status = err == WebDashboardServer.invalidAllowlist ? err : "Couldn't listen on port \(port): \(err)"
                    WebDashboardEndpoint.shared.server = nil
                } else {
                    WebDashboardEndpoint.shared.serving()
                    WebDashboardEndpoint.shared.startMonitor()
                }
            }
        }
    }

    /// An allowlist or Advanced edit: re-checks open connections, or restarts when the list became (in)valid.
    func settingsChanged() {
        if server == nil || !allowlist.invalid.isEmpty { apply() } else { refresh() }
    }

    /// Re-reads the network for Settings while the section is shown (cheap; no polling).
    func refreshContext() { context = readContext() }

    private func stopServer() {
        server?.stop(); server = nil
        subscription?.cancel(); subscription = nil
        pathMonitor?.cancel(); pathMonitor = nil
        debounce?.cancel(); debounce = nil
        urls = []
    }

    private func readModelName() {
        guard !modelRequested else { return }
        modelRequested = true
        Task.detached(priority: .utility) {
            let name = WebMacModel.read()
            await MainActor.run { WebDashboardEndpoint.shared.modelName = name }
        }
    }

    private func readContext() -> WebNetworkContext {
        let names = engine?.liveSnapshot?.processes.map(\.name) ?? []
        let bundles = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        return WebNetworkContext.read(localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?,
                                      tailscaleProcessRunning: WebTailscale.processRunning(processNames: names, bundleIDs: bundles),
                                      advanced: UserDefaults.standard.bool(forKey: Self.advancedKey))
    }

    private func serving() {
        guard let ctx = context, let port = server?.port else { return }
        var out: [String] = []
        if let v4 = ctx.interfaces.filter({ $0.kind == .lan }).flatMap(\.addresses).first(where: { $0.ip.isV4 })?.ip {
            out.append("http://\(v4):\(port)")
        }
        if let name = ctx.localHostName, !name.isEmpty { out.append("http://\(name).local:\(port)") }
        // The tailnet address, when a tailnet entry that is honoured lets tailnet devices in.
        let allow = allowlist
        if let tail = ctx.interfaces.first(where: { $0.kind == .tailscale })?.addresses.first(where: { $0.ip.isV4 })?.ip,
           allow.entries.contains(where: { WebAccess.label($0.prefix, context: ctx) == .tailnet && $0.prefix.contains(tail) }) {
            out.append("http://\(tail):\(port)")
        }
        urls = out
        status = out.isEmpty ? "Serving on port \(port), but this Mac has no local network address right now." : "Serving " + out.joined(separator: " and ")
    }

    /// Network changes (Wi-Fi joined, VPN up, Tailscale on) re-check open connections, debounced by a second.
    private func startMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { _ in
            Task { @MainActor in
                let e = WebDashboardEndpoint.shared
                e.debounce?.cancel()
                e.debounce = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    WebDashboardEndpoint.shared.refresh()
                }
            }
        }
        m.start(queue: DispatchQueue(label: "flightdeck.web.path", qos: .utility))
        pathMonitor = m
    }

    private func refresh() {
        guard let server else { return }
        let ctx = readContext()
        context = ctx
        server.update(context: ctx, allowlist: allowlist)
        serving()
    }

    // MARK: - Documents

    /// Everything comes from the Engine's helper-free `webDashboard` (nil until the first sample after turning on).
    /// Diagnostic-report and sleep findings are added here: they never involve helper values.
    private func inputs() -> WebDashboardInputs {
        let e = engine, d = e?.webDashboard
        let findings = (d?.findings ?? []) + (e.map { $0.reportFindings + $0.sleepFindings } ?? [])   // live, never a replay
        let muted = Set(findings.filter { Alerts.shared.isMuted($0) }.map(\.id))
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return WebDashboardInputs(
            snapshot: d?.snapshot, findings: findings, incidents: d?.incidents ?? [],
            displayName: UserDefaults.standard.string(forKey: Self.nameKey) ?? "", modelName: modelName,
            hardwareModel: Sysctl.string("hw.model") ?? "",
            macOS: "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""),
            appVersion: MCPEndpoint.version, uptime: Sysctl.timeval("kern.boottime").map { Date().timeIntervalSince($0) },
            paused: e?.paused ?? false,
            intervalS: e.map { WebDashboardState.interval(visible: $0.uiVisible, interval: $0.interval, background: $0.backgroundInterval) } ?? 5,
            redaction: redaction, isMuted: { muted.contains($0.id) })
    }

    /// The state document; a stream's first one also carries 30 minutes of history from the black box (read on its
    /// own queue). Without an Engine or a sample yet, the document still comes back, with every reading "No sample yet".
    private func document(withHistory: Bool, reply: @escaping @Sendable (Data?) -> Void) {
        let i = inputs()
        guard withHistory else { reply(WebDashboardState.encode(WebDashboardState.build(i))); return }
        guard let e = engine, e.blackBoxEnabled else {
            var j = i; j.history = .unavailable("The black box is turned off in Settings.")
            reply(WebDashboardState.encode(WebDashboardState.build(j)))
            return
        }
        Task { @MainActor in
            let now = Date()
            let trace = await e.readBlackBox(.coarse, from: now.addingTimeInterval(-WebDashboardState.historyStep * Double(WebDashboardState.historyPoints)))
            var j = self.inputs()
            j.history = trace.map { .points(WebDashboardState.history(frames: $0.frames, now: now)) }
                ?? .unavailable("The black box has no data for the last 30 minutes yet.")
            reply(WebDashboardState.encode(WebDashboardState.build(j)))
        }
    }

    /// Feeds streams from the Engine only while at least one is open.
    private func streamCount(_ n: Int) {
        if n > 0, subscription == nil, let e = engine {
            subscription = e.$liveSnapshot.dropFirst().compactMap { $0 }.sink { s in WebDashboardEndpoint.shared.publish(s) }
        } else if n == 0 {
            subscription?.cancel(); subscription = nil
        }
    }

    private func publish(_ s: Snapshot) {
        guard let server else { return }
        var i = inputs()
        i.point = WebPoint(s)   // machine-wide readings only
        server.publish(WebDashboardState.encode(WebDashboardState.build(i)))
    }
}

/// Settings section for the dashboard. Lives here rather than in SettingsView to keep that shared file small.
struct WebDashboardSection: View {
    @AppStorage(WebDashboardEndpoint.enabledKey) private var enabled = false
    @AppStorage(WebDashboardEndpoint.portKey) private var port = WebDashboardEndpoint.defaultPort
    @AppStorage(WebDashboardEndpoint.nameKey) private var name = ""
    @AppStorage(WebDashboardEndpoint.allowlistKey) private var allow = ""
    @AppStorage(WebDashboardEndpoint.advancedKey) private var advanced = false
    @ObservedObject private var endpoint = WebDashboardEndpoint.shared
    @State private var note: String?
    @State private var unifiNetworks: [UniFiNetwork] = []
    @State private var unifiError: String?

    static let warning = "No password and no encryption. Anyone on an allowed network can see this Mac's readings, findings and the names of running apps. Read-only: nothing can be changed from the browser."
    static let advancedWarning = "Addresses outside your local network can see this Mac's readings and running apps over unencrypted HTTP with no password. Anyone between you and them can read it too."

    private var ctx: WebNetworkContext {
        var c = endpoint.context ?? WebNetworkContext(interfaces: [], localHostName: nil, tailscaleProcessRunning: false, advanced: advanced)
        c.advanced = advanced
        return c
    }

    var body: some View {
        let list = WebAllowlist.parse(allow), ctx = ctx
        let local = WebSuggestions.local(ctx)
        let suggestions = WebSuggestions.visible(local + WebSuggestions.unifi(unifiNetworks, context: ctx)
                                                 + [WebSuggestions.tailnet(ctx)].compactMap { $0 }, current: list)
        Section("Web dashboard") {
            Toggle("Serve a live dashboard to browsers on the local network", isOn: $enabled)
                .disabled(Demo.isEnabled)
            if Demo.isEnabled {
                Text("Not available in demo mode.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Port", value: $port, format: .number.grouping(.never)).disabled(!enabled)
            TextField("Name shown on the dashboard", text: $name, prompt: Text(endpoint.modelName)).disabled(!enabled)
            TextField("Allowed addresses", text: $allow, prompt: Text("Empty: any address on the local network"), axis: .vertical)
                .lineLimit(1...6).font(.body.monospaced()).disabled(!enabled)
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(list.entries, id: \.position) { e in
                        let label = WebAccess.label(e.prefix, context: ctx)
                        HStack(spacing: 6) {
                            Text(e.prefix.description).font(.caption.monospaced())
                            if e.normalizedChanged { Text("(from \(e.text))").font(.caption).foregroundStyle(.secondary) }
                            Text(label.text).font(.caption).foregroundStyle(label.isIgnored ? Color.orange : Color.secondary)
                        }
                    }
                    ForEach(list.invalid, id: \.position) { i in
                        Text("Entry \(i.position), “\(i.text)”: \(i.reason)").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            ForEach(suggestions, id: \.self) { s in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.label).font(.caption.monospaced())
                        if let w = s.warning { Text(w).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer()
                    Button("Add") { add(s) }.disabled(!enabled)
                }
            }
            if let unifiError {
                Text("Couldn't read networks from UniFi: \(unifiError)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let note {
                HStack(alignment: .firstTextBaseline) {
                    Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let subnet = WebSuggestions.visible(local, current: list).first {
                        Button("Add \(subnet.entries.joined(separator: ", "))") { add(subnet); self.note = nil }
                    }
                }
            }
            DisclosureGroup("Advanced") {
                Toggle("Allow addresses outside the local network", isOn: $advanced).disabled(!enabled)
                if advanced {
                    Text(Self.advancedWarning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if enabled {
                if let s = endpoint.status { Text(s).font(.caption).monospacedDigit().textSelection(.enabled) }
                ForEach(endpoint.urls, id: \.self) { u in
                    HStack {
                        Text(u).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) }
                    }
                }
                if let first = endpoint.urls.first, let qr = Self.qr(first) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                        .accessibilityLabel("QR code for \(first)")
                }
                Text(Self.warning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { endpoint.refreshContext() }
        .task { await readUniFiNetworks() }
        .onChange(of: enabled) {
            endpoint.apply()
            if enabled { Task { await readUniFiNetworks() } }
        }
        .onChange(of: port) { endpoint.apply() }
        .onChange(of: allow) { endpoint.settingsChanged() }
        .onChange(of: advanced) { endpoint.settingsChanged() }
    }

    /// The UniFi console's networks, read once each time the section is shown with the dashboard on, or when it is
    /// turned on (no polling), if UniFi is set up.
    private func readUniFiNetworks() async {
        let model = UniFiModel.shared
        guard enabled, !Demo.isEnabled, let c = model.config, let creds = model.credentials(for: c) else { return }
        do {
            unifiNetworks = try await UniFiAPIClient(config: c, credentials: creds).networks()
            unifiError = nil
        } catch {
            unifiError = error.localizedDescription
        }
    }

    private func add(_ s: WebSuggestion) {
        let r = WebSuggestions.adding(s, to: allow)
        allow = r.text
        note = r.note
    }

    /// A crisp QR code: one pixel per module, scaled up without smoothing by the view.
    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
