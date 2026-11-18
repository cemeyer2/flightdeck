// App-side state for the UniFi integration: the configuration (UserDefaults, no secrets), the credentials (Keychain
// only), polling while the UniFi view is visible, the cached last snapshot, WAN rate history for the visible session,
// trust-on-first-use prompts and gateway detection. In demo mode it serves UniFiDemo's invented network and never
// touches the network or the Keychain.
import SwiftUI
import FlightDeckCore

@MainActor
final class UniFiModel: ObservableObject {
    static let shared = UniFiModel()
    static let configKey = "unifiConfig"
    /// Poll period while the view is visible (the brief allows 10–15 s; consoles refresh their stats about every 10 s).
    static let period: Duration = .seconds(15)
    /// Keychain items: "apiKey", or "username" + "password".
    let keychain = Keychain(service: "FlightDeck.UniFi")

    @Published private(set) var config: UniFiConfig?
    /// The last successful read, kept while the view is closed so reopening shows it at once.
    @Published private(set) var snapshot: UniFiSnapshot?
    @Published private(set) var lastError: String?
    /// Set when the console presented a certificate that isn't trusted yet; the UI asks the user to trust it.
    @Published private(set) var untrustedFingerprint: String?
    @Published private(set) var loading = false
    @Published private(set) var suggestion: UniFiDetection.Suggestion?
    /// WAN download/upload (bytes/s) per poll since the view opened; nil where a poll failed or had no WAN rate.
    @Published private(set) var wanRx: [Double?] = []
    @Published private(set) var wanTx: [Double?] = []

    private var pollTask: Task<Void, Never>?
    private var client: UniFiAPIClient?
    private var demoTick = 0

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.configKey) { config = try? JSONDecoder().decode(UniFiConfig.self, from: d) }
    }

    var isConfigured: Bool { Demo.isEnabled || config != nil }

    // MARK: Configuration

    /// Saves the configuration and puts the secrets in the Keychain (removing the other method's secrets). A host
    /// change drops the pinned fingerprint: the pin belongs to the console it was approved for.
    func save(_ c: UniFiConfig, apiKey: String, username: String, password: String) throws {
        var c = c
        if let old = config, old.host.lowercased() != c.host.lowercased() { c.pinnedFingerprint = nil }
        switch c.auth {
        case .apiKey:
            if !apiKey.isEmpty { try keychain.set(apiKey, account: "apiKey") }
            try keychain.delete("username"); try keychain.delete("password")
        case .password:
            if !username.isEmpty { try keychain.set(username, account: "username") }
            if !password.isEmpty { try keychain.set(password, account: "password") }
            try keychain.delete("apiKey")
        }
        store(c)
    }

    private func store(_ c: UniFiConfig?) {
        config = c; client = nil
        if let c, let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: Self.configKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.configKey) }
    }

    /// Removes the configuration, the pin, the credentials and the cached data.
    func forget() {
        try? keychain.deleteAll()
        store(nil); snapshot = nil; lastError = nil; untrustedFingerprint = nil; wanRx = []; wanTx = []
    }

    var savedUsername: String { Demo.isEnabled ? "" : keychain.get("username") ?? "" }
    func hasSecret(for auth: UniFiConfig.Auth) -> Bool {
        auth == .apiKey ? keychain.get("apiKey") != nil : keychain.get("password") != nil
    }

    func credentials(for c: UniFiConfig) -> UniFiCredentials? {
        switch c.auth {
        case .apiKey: return keychain.get("apiKey").map { .apiKey($0) }
        case .password:
            guard let u = keychain.get("username"), let p = keychain.get("password") else { return nil }
            return .password(user: u, password: p)
        }
    }

    /// The user approved the fingerprint shown: pin it and connect.
    func trust(_ fingerprint: String) {
        guard var c = config else { return }
        c.pinnedFingerprint = fingerprint
        store(c); untrustedFingerprint = nil; lastError = nil
        Task { await refresh() }
    }

    // MARK: Polling (only while the UniFi view is on screen)

    func viewAppeared() {
        guard pollTask == nil else { return }
        wanRx = []; wanTx = []   // the WAN graph covers the visible session only
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.period)
            }
        }
        if !Demo.isEnabled && config == nil { detect() }
    }

    func viewDisappeared() { pollTask?.cancel(); pollTask = nil }

    func refresh() async {
        if Demo.isEnabled {
            demoTick += 1
            record(UniFiDemo.snapshot(tick: demoTick)); return
        }
        guard let c = config else { return }
        guard let creds = credentials(for: c) else { lastError = "No credentials in the Keychain. Enter them in Settings › UniFi."; return }
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            if client == nil { client = try UniFiAPIClient(config: c, credentials: creds) }
            let s = try await client!.fetch()
            guard config == c else { return }   // settings changed while this poll was in flight
            lastError = nil; untrustedFingerprint = nil
            record(s)
        } catch let e as UniFiError {
            fail(e)
        } catch {
            fail(.network(error.localizedDescription))
        }
    }

    private func record(_ s: UniFiSnapshot) {
        snapshot = s
        append(s.health.wanRxBps, s.health.wanTxBps)
    }

    private func fail(_ e: UniFiError) {
        if case .untrustedCertificate(let fp) = e { untrustedFingerprint = fp }
        if case .unauthorized = e { client = nil }   // log in afresh next time (credentials may have changed)
        lastError = e.localizedDescription
        append(nil, nil)   // a gap in the WAN graph, not a fake zero
    }

    private func append(_ rx: Double?, _ tx: Double?) {
        wanRx.append(rx); wanTx.append(tx)
        if wanRx.count > 240 { wanRx.removeFirst(wanRx.count - 240); wanTx.removeFirst(wanTx.count - 240) }
    }

    /// Headless renders (`--render-views`): fills the model with demo polls, without network, Keychain or timers.
    func renderDemo(ticks: Int) {
        for t in 1...max(ticks, 1) { demoTick = t; record(UniFiDemo.snapshot(tick: t)) }
    }

    /// One-off read with settings that may not be saved yet (Settings › Test connection). Uses its own client so a
    /// failed test doesn't disturb polling.
    func test(_ c: UniFiConfig, _ creds: UniFiCredentials) async -> (ok: Bool, message: String, fingerprint: String?) {
        if Demo.isEnabled { return (false, "Not available in demo mode.", nil) }
        do {
            let client = try UniFiAPIClient(config: c, credentials: creds)
            return (true, try await client.testConnection(), nil)
        } catch let e as UniFiError {
            if case .untrustedCertificate(let fp) = e { return (false, e.localizedDescription, fp) }
            return (false, e.localizedDescription, nil)
        } catch { return (false, error.localizedDescription, nil) }
    }

    /// Looks at the default gateway for a UniFi console (ARP OUI, then one unauthenticated HTTPS GET). Only called while
    /// the UniFi view is open and nothing is configured; sends no credentials.
    func detect() {
        guard !Demo.isEnabled, suggestion == nil else { return }
        Task.detached(priority: .utility) {
            let s = await UniFiDetection.suggest()
            await MainActor.run { UniFiModel.shared.suggestion = s }
        }
    }
}
