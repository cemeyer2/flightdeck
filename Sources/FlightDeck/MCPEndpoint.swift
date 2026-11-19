// The optional MCP server (Settings › AI assistants). Off by default. When on, an MCPHTTPServer listens on
// 127.0.0.1:<port>/mcp and answers MCP clients (Claude Code, Codex, …) from the Engine's live state: the latest
// sample, current findings, the Flight Log, macOS reports, the black box and the Trends log. Nothing runs between
// requests. Never started in demo mode: an assistant asking about "this Mac" must not be handed invented data, so in
// demo mode the server is simply off (and `FlightDeck --mcp` then answers standalone from real samples).
//
// The bearer token is generated the first time the server is turned on and kept in the app's user defaults, which
// only this user can read. `FlightDeck --mcp` reads the same defaults to find the port and token to proxy to.
import SwiftUI
import AppKit
import FlightDeckCore

@MainActor
final class MCPEndpoint: ObservableObject {
    static let shared = MCPEndpoint()
    // nonisolated: also read by `FlightDeck --mcp`, which doesn't run on the main actor.
    nonisolated static let defaultPort = 9465
    nonisolated static let enabledKey = "mcpEnabled", portKey = "mcpPort", tokenKey = "mcpToken"
    /// The bundle identifier the app's defaults live under (scripts/bundle.sh). The CLI may run from a bare build
    /// (`.build/…/FlightDeck`) whose defaults domain is different, so it names this domain explicitly.
    nonisolated static let appDefaultsDomain = "app.flightdeck.Flightdeck"

    private weak var engine: Engine?
    private var server: MCPHTTPServer?
    /// Shown in Settings: "Serving on …", or why the listener couldn't start.
    @Published private(set) var status: String?

    func configure(engine: Engine) { self.engine = engine; apply() }

    /// The app's version as stamped by the release workflow, or "dev" for unbundled builds.
    nonisolated static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    /// Starts, restarts or stops the server to match the settings.
    func apply() {
        server?.stop(); server = nil
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.enabledKey), !Demo.isEnabled, let engine else { status = nil; return }
        let raw = d.object(forKey: Self.portKey) as? Int ?? Self.defaultPort
        guard (1024...65535).contains(raw) else { status = "Choose a port between 1024 and 65535."; return }
        let port = UInt16(raw)
        let token = Self.token(creating: true)
        let tools = MCPTools(source: EngineMCPSource(engine: engine))
        let mcp = MCPServer(version: Self.version, instructions: MCPTools.instructions, tools: tools)
        let s = MCPHTTPServer(port: port, token: token, server: mcp)
        server = s
        status = "Starting…"
        s.start { err in
            Task { @MainActor in
                guard MCPEndpoint.shared.server === s else { return }
                MCPEndpoint.shared.status = err.map { "Couldn't listen on port \(port): \($0)" } ?? "Serving http://127.0.0.1:\(port)/mcp"
            }
        }
    }

    /// The bearer token, generated and saved on first use when `creating`.
    static func token(creating: Bool) -> String {
        let d = UserDefaults.standard
        if let t = d.string(forKey: tokenKey), !t.isEmpty { return t }
        guard creating else { return "" }
        let t = MCPHTTPGate.newToken()
        d.set(t, forKey: tokenKey)
        return t
    }

    /// Replaces the token (clients configured with the old one stop working until updated) and restarts the server.
    func regenerateToken() {
        UserDefaults.standard.set(MCPHTTPGate.newToken(), forKey: Self.tokenKey)
        objectWillChange.send()
        apply()
    }

    /// For `FlightDeck --mcp`: the app's endpoint if its MCP server is turned on, read from the app's defaults
    /// domain. Whether it is actually running is found out by trying it (MCPStdio falls back to standalone).
    nonisolated static func appEndpoint() -> MCPStdio.AppEndpoint? {
        let d = Bundle.main.bundleIdentifier == appDefaultsDomain ? UserDefaults.standard : (UserDefaults(suiteName: appDefaultsDomain) ?? .standard)
        guard d.bool(forKey: enabledKey), !d.bool(forKey: "demo"), let token = d.string(forKey: tokenKey), !token.isEmpty else { return nil }
        let port = d.object(forKey: portKey) as? Int ?? defaultPort
        guard (1024...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)/mcp") else { return nil }
        return MCPStdio.AppEndpoint(url: url, token: token)
    }

    /// The path of this binary, for the stdio setup commands (inside the .app when installed).
    nonisolated static var executablePath: String { Bundle.main.executablePath ?? "/Applications/FlightDeck.app/Contents/MacOS/FlightDeck" }
}

/// The Engine as an MCP data source. Each read hops to the main actor for the Engine's published state; anything slow
/// (black box decompression, Trends copy, Checkup) runs off it.
final class EngineMCPSource: MCPDataSource, @unchecked Sendable {
    let standalone = false
    private weak var engine: Engine?
    let blackBoxConfig: BlackBox.Config
    private let dailyLog: DailyLog

    @MainActor init(engine: Engine) {
        self.engine = engine; blackBoxConfig = engine.blackBox.config; dailyLog = engine.dailyLog
    }

    func snapshot() async -> Snapshot? { await MainActor.run { engine?.liveSnapshot } }
    /// Live findings (not a replayed recording's), including muted ones: muting silences alerts, it doesn't make the
    /// condition untrue.
    func findings() async -> [Finding] {
        await MainActor.run { engine.map { $0.liveFindings + $0.reportFindings + $0.sleepFindings } ?? [] }
    }
    func incidents() async -> [Incident] { await MainActor.run { engine?.incidents ?? [] } }
    func reports(since: Date) async -> [DiagnosticReport] {
        // The Engine rescans 7 days of reports every 5 minutes; that copy is served rather than rescanning.
        await MainActor.run { (engine?.reports ?? []).filter { $0.time >= since } }
    }
    func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace? {
        guard let engine = await MainActor.run(body: { engine }) else { return nil }
        return await engine.readBlackBox(tier, from: from, to: to)
    }
    func dailyHistory() async -> DailyLog.History? {
        let log = dailyLog
        return await Task.detached(priority: .userInitiated) { log.history() }.value
    }
    func checkup() async -> [CheckResult] { await runCheckup() }
    func thermal() async -> (status: ThermalStatus, history: SensorHistory)? {
        guard let w = await MainActor.run(body: { engine?.thermal }) else { return nil }
        return (w.status(), w.history)
    }
    /// The Wi-Fi page's last scan (memory only; nil until the user scans). Demo scans are never served.
    func wifiScan() async -> WiFiScanResult? { await MainActor.run { WiFiModel.shared.demo ? nil : WiFiModel.shared.scan } }
    /// The app's live Camera & Mic watch (none in demo mode).
    func cameraMic() async -> (live: CameraMicLive?, store: CameraMicStore)? {
        CameraMicService.watch.map { ($0.live, $0.store) }
    }
    /// The live tracker's open day plus its saved days (none in demo mode).
    func destinations() async -> (days: [DestinationDay], known: KnownDestinations)? {
        guard let t = DestinationService.tracker, let store = t.store else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let today = t.today()
            let saved = store.days(from: Date().addingTimeInterval(-Double(DestinationStore.retentionDays) * 86_400), to: Date())
            return (saved.filter { $0.start != today.start } + [today], t.known())
        }.value
    }
}

/// Settings section for the MCP server, kept here so SettingsView only gains one line.
struct MCPSection: View {
    @AppStorage(MCPEndpoint.enabledKey) private var enabled = false
    @AppStorage(MCPEndpoint.portKey) private var port = MCPEndpoint.defaultPort
    @AppStorage(MCPEndpoint.tokenKey) private var token = ""
    @ObservedObject private var endpoint = MCPEndpoint.shared
    @State private var showToken = false

    private var url: String { "http://127.0.0.1:\(String(port))/mcp" }
    private var claudeCommand: String { "claude mcp add --transport http flightdeck \(url) --header \"Authorization: Bearer \(token)\"" }
    private var codexConfig: String { "[mcp_servers.flightdeck]\nurl = \"\(url)\"\nhttp_headers = { \"Authorization\" = \"Bearer \(token)\" }" }
    private var stdioCommand: String { "claude mcp add flightdeck -- \(MCPEndpoint.executablePath) --mcp" }

    var body: some View {
        Section("AI assistants (MCP)") {
            Toggle("Let AI assistants read FlightDeck's data", isOn: $enabled).disabled(Demo.isEnabled)
            if enabled && !Demo.isEnabled {
                TextField("Port", value: $port, format: .number.grouping(.never))
                if let s = endpoint.status { Text(s).font(.caption).monospacedDigit() }
                HStack {
                    Text("Token").font(.caption)
                    Text(showToken ? token : String(repeating: "•", count: 16)).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                    Button("Copy") { copy(token) }
                    Button("New Token") { endpoint.regenerateToken() }
                        .help("Clients set up with the old token stop working until you update them.")
                }
                command("Claude Code", claudeCommand)
                command("Codex (~/.codex/config.toml)", codexConfig)
                command("Claude Code, as a command (no token needed; also works with the app closed)", stdioCommand)
            }
            Text(Demo.isEnabled ? "Not available in demo mode."
                 : "Off by default. When on, MCP clients such as Claude Code and Codex can ask FlightDeck about this Mac: status and findings, processes, stack samples of your own apps, the Flight Log, crash reports, black-box history, Checkup and Trends. Read-only: no tool can quit, change or slow anything. Only this Mac can connect, and only with the token. It does no work between requests.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: enabled) { endpoint.apply() }
        .onChange(of: port) { endpoint.apply() }
    }

    /// A copyable setup snippet. The token is part of the text, so it is shown only while "Show" is on.
    private func command(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Button("Copy") { copy(text) }.controlSize(.small)
            }
            Text(showToken || token.isEmpty ? text : text.replacingOccurrences(of: token, with: "<token>"))
                .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
