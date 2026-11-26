// Settings › UniFi: console host, site, auth method and credentials, Test connection, trusting the console's
// certificate (trust on first use), and Forget. Secrets typed here go straight to the Keychain via UniFiModel.save;
// the fields are cleared from memory on save and are never stored in UserDefaults.
import SwiftUI
import FlightDeckCore

struct UniFiSettingsSection: View {
    @ObservedObject private var model = UniFiModel.shared
    @State private var host = ""
    @State private var site = "default"
    @State private var auth: UniFiConfig.Auth = .apiKey
    @State private var apiKey = ""
    @State private var username = ""
    @State private var password = ""
    @State private var status: String?
    @State private var statusOK = false
    /// A certificate fingerprint awaiting the user's decision (from Test connection or from polling).
    @State private var fingerprint: String?
    @State private var testing = false

    var body: some View {
        Section("UniFi") {
            if Demo.isEnabled {
                Text("Not available in demo mode (the UniFi view shows an invented network).").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Console host or IP", text: $host, prompt: Text(model.suggestion?.host ?? "192.168.1.1"))
                if let s = model.suggestion, host.isEmpty {
                    HStack {
                        Text(s.reason).font(.caption).foregroundStyle(.secondary)
                        Button("Use \(s.host)") { host = s.host }
                    }
                }
                TextField("Site", text: $site)
                Picker("Sign in with", selection: $auth) {
                    Text("API key (recommended)").tag(UniFiConfig.Auth.apiKey); Text("Username and password").tag(UniFiConfig.Auth.password)
                }
                if auth == .apiKey {
                    SecureField("API key", text: $apiKey, prompt: Text(model.hasSecret(for: .apiKey) ? "saved in the Keychain" : "from UniFi Network › Settings › Control Plane › Integrations"))
                } else {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password, prompt: Text(model.hasSecret(for: .password) ? "saved in the Keychain" : "a local, read-only account is best"))
                }
                HStack {
                    Button("Save") { save() }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Test connection") { test() }.disabled(testing || host.trimmingCharacters(in: .whitespaces).isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Forget", role: .destructive) { model.forget(); load() }.disabled(model.config == nil)
                }
                if let fp = fingerprint ?? model.untrustedFingerprint {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.config?.pinnedFingerprint == nil
                             ? "The console's certificate isn't trusted by macOS (consoles use self-signed certificates). Compare this SHA-256 fingerprint with the one shown in your console's settings or browser before trusting it:"
                             : "The console's certificate has changed from the one you pinned. If you renewed or replaced it, compare this SHA-256 fingerprint with the one shown in your console's settings or browser, then trust it. Your saved credentials are kept:")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        Text(fp).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        Button("Trust This Certificate") { trust(fp) }
                    }
                }
                if let status { Text(status).font(.caption).foregroundStyle(statusOK ? Color.secondary : Color.red).fixedSize(horizontal: false, vertical: true) }
                if let pin = model.config?.pinnedFingerprint {
                    Text("Pinned certificate: \(pin)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Off until configured. FlightDeck only reads from the console (devices, clients, WAN health) while the UniFi view is open, every 15 s. Credentials are kept in the Keychain. The certificate you trust is pinned; if it changes, FlightDeck refuses to connect until you trust the new one.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        let c = model.config
        host = c?.host ?? ""; site = c?.site ?? "default"; auth = c?.auth ?? .apiKey
        username = Demo.isEnabled ? "" : model.savedUsername; apiKey = ""; password = ""
    }

    /// The config as edited, keeping the current pin if the host is unchanged.
    private var edited: UniFiConfig {
        let h = host.trimmingCharacters(in: .whitespaces)
        let pin = model.config.flatMap { $0.host.lowercased() == h.lowercased() ? $0.pinnedFingerprint : nil }
        return UniFiConfig(host: h, site: site.isEmpty ? "default" : site, auth: auth, pinnedFingerprint: pin)
    }

    private func save() {
        do {
            try model.save(edited, apiKey: apiKey, username: username, password: password)
            apiKey = ""; password = ""
            status = "Saved."; statusOK = true
            Task { await model.refresh() }
        } catch { status = "Couldn't save to the Keychain: \(error)"; statusOK = false }
    }

    /// Tests with the typed credentials, or the saved ones where a field was left empty.
    private func test() {
        let c = edited
        let creds: UniFiCredentials?
        switch auth {
        case .apiKey: creds = apiKey.isEmpty ? model.credentials(for: c) : .apiKey(apiKey)
        case .password:
            let saved = model.credentials(for: c)
            if case .password(let u, let p)? = saved { creds = .password(user: username.isEmpty ? u : username, password: password.isEmpty ? p : password) }
            else { creds = username.isEmpty || password.isEmpty ? nil : .password(user: username, password: password) }
        }
        guard let creds else { status = "Enter the credentials first."; statusOK = false; return }
        testing = true; status = nil
        Task {
            let r = await model.test(c, creds)
            testing = false; status = r.message; statusOK = r.ok; fingerprint = r.fingerprint
        }
    }

    /// Pins the fingerprint: saves the edited settings (and typed secrets) with the pin, then connects.
    private func trust(_ fp: String) {
        var c = edited; c.pinnedFingerprint = fp
        do {
            try model.save(c, apiKey: apiKey, username: username, password: password)
            model.trust(fp)
            apiKey = ""; password = ""; fingerprint = nil
            status = "Certificate trusted and pinned."; statusOK = true
        } catch { status = "Couldn't save to the Keychain: \(error)"; statusOK = false }
    }
}
