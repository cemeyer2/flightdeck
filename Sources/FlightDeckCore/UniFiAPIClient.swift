// HTTP transport for a UniFi console: configuration, credentials, the pinned TLS session, authentication (API key, or
// classic username/password login with its session cookie and CSRF token), and error mapping. The read flows that
// assemble a UniFiSnapshot are in UniFiFetch.swift. Read-only: the only non-GET request ever sent is the login POST.
import Foundation

/// What the user configured in Settings. Contains no secrets (those live in the Keychain, see `UniFiCredentials`).
public struct UniFiConfig: Codable, Sendable, Hashable {
    public enum Auth: String, Codable, Sendable, CaseIterable { case apiKey, password }
    /// Host name or IP, optionally with a port ("192.168.1.1", "unifi.local:8443").
    public var host: String
    /// Classic site name ("default") or integration site ID / name.
    public var site: String
    public var auth: Auth
    /// The SHA-256 fingerprint the user approved (trust on first use), or nil if none yet.
    public var pinnedFingerprint: String?
    public init(host: String, site: String = "default", auth: Auth = .apiKey, pinnedFingerprint: String? = nil) {
        self.host = host; self.site = site; self.auth = auth; self.pinnedFingerprint = pinnedFingerprint
    }
    /// The host without a port, as URLSession's protection space reports it.
    public var hostname: String {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("["), let end = h.firstIndex(of: "]") { return String(h[h.index(after: h.startIndex)..<end]) }   // [IPv6]:port
        if h.filter({ $0 == ":" }).count == 1 { return String(h.split(separator: ":")[0]) }
        return h
    }
}

public enum UniFiCredentials: Sendable {
    case apiKey(String)
    case password(user: String, password: String)
}

public enum UniFiError: Error, LocalizedError, Equatable {
    /// The certificate isn't trusted by the system and no fingerprint is pinned yet: ask the user.
    case untrustedCertificate(fingerprint: String)
    case certificateChanged(pinned: String, presented: String)
    case unauthorized(String)
    case notFound(String)
    case http(Int, String)
    case network(String)
    case badResponse(String)
    case siteNotFound(String, available: [String])
    case invalidHost

    public var errorDescription: String? {
        switch self {
        case .untrustedCertificate(let fp): return "The console's certificate isn't trusted yet. SHA-256 fingerprint: \(fp)"
        case .certificateChanged(let a, let b):
            return "The console's certificate has changed, so FlightDeck refused to connect. Pinned: \(a). Presented: \(b). If you replaced or renewed the certificate, trust the new one in Settings › UniFi."
        case .unauthorized(let s): return "The console rejected the credentials (\(s))."
        case .notFound(let p): return "The console has no \(p) endpoint (is this a UniFi console, and is the Network application installed?)."
        case .http(let c, let p): return "The console answered HTTP \(c) for \(p)."
        case .network(let s): return "Couldn't reach the console: \(s)"
        case .badResponse(let p): return "The console's answer to \(p) wasn't in a format FlightDeck understands."
        case .siteNotFound(let s, let all): return "No site \"\(s)\" on this console. Sites: \(all.joined(separator: ", "))."
        case .invalidHost: return "Enter the console's host name or IP address."
        }
    }
}

public final class UniFiAPIClient: @unchecked Sendable {
    public let config: UniFiConfig
    let credentials: UniFiCredentials
    let session: URLSession
    let delegate: PinningDelegate
    let base: URL
    let timeout: TimeInterval
    // Mutable session state, guarded by `lock`: the discovered path prefix ("/proxy/network" on UniFi OS, "" on a
    // standalone controller), the classic login state and the CSRF token UniFi OS requires on later requests.
    private let lock = NSLock()
    private var _prefix: String?
    private var _loggedIn = false
    private var _csrf: String?
    var prefix: String? { get { locked { _prefix } } set { locked { _prefix = newValue } } }

    func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    /// `protocolClasses` lets tests route every request to a URLProtocol stub; nothing in the app sets it.
    public init(config: UniFiConfig, credentials: UniFiCredentials, timeout: TimeInterval = 10, protocolClasses: [AnyClass]? = nil) throws {
        let h = config.host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !h.contains("/"), let url = URL(string: "https://\(h)") else { throw UniFiError.invalidHost }
        self.config = config; self.credentials = credentials; self.base = url; self.timeout = timeout
        delegate = PinningDelegate(host: config.hostname, pinnedFingerprint: config.pinnedFingerprint)
        // Ephemeral: the login cookie lives only in this session's memory, never in the shared cookie store or on disk.
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.httpCookieAcceptPolicy = .always
        c.urlCache = nil
        if let protocolClasses { c.protocolClasses = protocolClasses }
        session = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    /// A GET or the login POST, with the auth headers for the configured method. Returns the body and HTTP status.
    func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, Int, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: base) else { throw UniFiError.invalidHost }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .apiKey(let k) = credentials { r.setValue(k, forHTTPHeaderField: "X-API-KEY") }
        if let csrf = locked({ _csrf }) { r.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token") }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { throw UniFiError.badResponse(path) }
            // UniFi OS rotates the token; later requests must send the newest one.
            if let t = http.value(forHTTPHeaderField: "X-Updated-CSRF-Token") ?? http.value(forHTTPHeaderField: "X-CSRF-Token") {
                locked { _csrf = t }
            }
            return (data, http.statusCode, http)
        } catch let e as UniFiError {
            throw e
        } catch {
            // A challenge the pinning delegate cancelled surfaces as a cancelled/TLS error; report why instead.
            switch delegate.lastDecision {
            case .askUser(let fp)?: throw UniFiError.untrustedCertificate(fingerprint: fp)
            case .changed(let a, let b)?: throw UniFiError.certificateChanged(pinned: a, presented: b)
            default: throw UniFiError.network((error as? URLError)?.localizedDescription ?? error.localizedDescription)
            }
        }
    }

    /// GET that throws for anything but 2xx.
    func get(_ path: String) async throws -> Data {
        let (data, status, _) = try await request(path)
        switch status {
        case 200..<300: return data
        case 401, 403: throw UniFiError.unauthorized("HTTP \(status)")
        case 404: throw UniFiError.notFound(path)
        default: throw UniFiError.http(status, path)
        }
    }

    // MARK: Classic login

    /// Logs in once per client (the cookie is reused for every poll; UniFi OS rate-limits logins). Tries the UniFi OS
    /// endpoint first, then a standalone controller's, which also tells us which path prefix to use.
    func loginIfNeeded(force: Bool = false) async throws {
        guard case .password(let user, let pass) = credentials else { return }
        if !force && locked({ _loggedIn }) { return }
        let body = try JSONSerialization.data(withJSONObject: ["username": user, "password": pass, "remember": false])
        for (path, prefix) in [("/api/auth/login", "/proxy/network"), ("/api/login", "")] {
            let (data, status, _) = try await request(path, method: "POST", body: body)
            if status == 404 { continue }
            guard (200..<300).contains(status) else {
                throw UniFiError.unauthorized(UniFiJSON.classicError(data) ?? "HTTP \(status)")
            }
            locked { _loggedIn = true; _prefix = prefix }
            return
        }
        throw UniFiError.notFound("login")
    }

    /// GET a classic path (relative to the site API root), logging in again once if the session expired.
    func classicGet(_ path: String) async throws -> Data {
        try await loginIfNeeded()
        let p = (prefix ?? "/proxy/network") + path
        do { return try await get(p) } catch UniFiError.unauthorized(let why) {
            guard case .password = credentials else { throw UniFiError.unauthorized(why) }
            try await loginIfNeeded(force: true)
            return try await get(p)
        }
    }
}
