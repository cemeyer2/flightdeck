// What the update check remembers between launches (UserDefaults, `updateCheck.*`), and the pure step that applies one
// GitHub response to it. The ETag is kept only together with a decoded result, so a 304 is never "reused" against
// nothing; a cached release that no longer validates is dropped with its ETag when loaded.
import Foundation

public struct ReleaseCheckState: Sendable, Equatable {
    public var lastCheckedAt: Date?
    public var etag: String?
    public var latest: ReleaseInfo?
    public var lastNotifiedVersion: String?
    public var retryNotBefore: Date?
    public var lastError: String?
    public var permissionRequested = false

    public init() {}

    enum Key {
        static let lastCheckedAt = "updateCheck.lastCheckedAt", etag = "updateCheck.etag", latestTag = "updateCheck.latestTag"
        static let latestURL = "updateCheck.latestURL", latestPublishedAt = "updateCheck.latestPublishedAt"
        static let lastNotifiedVersion = "updateCheck.lastNotifiedVersion", retryNotBefore = "updateCheck.retryNotBefore"
        static let lastError = "updateCheck.lastError", permissionRequested = "updateCheck.permissionRequested"
    }

    /// The release name isn't saved (nothing shows it), so a loaded `latest` has `name == nil`.
    public static func load(from d: UserDefaults) -> ReleaseCheckState {
        var s = ReleaseCheckState()
        s.lastCheckedAt = d.object(forKey: Key.lastCheckedAt) as? Date
        s.lastNotifiedVersion = d.string(forKey: Key.lastNotifiedVersion)
        s.retryNotBefore = d.object(forKey: Key.retryNotBefore) as? Date
        s.lastError = d.string(forKey: Key.lastError)
        s.permissionRequested = d.bool(forKey: Key.permissionRequested)
        if let tag = d.string(forKey: Key.latestTag), case .stable(let version) = ReleaseVersion.remote(tag: tag),
           let u = d.string(forKey: Key.latestURL).flatMap(URL.init(string:)), ReleaseInfo.isTrustedReleaseURL(u) {
            s.latest = ReleaseInfo(tag: tag, version: version, url: u, publishedAt: d.object(forKey: Key.latestPublishedAt) as? Date)
            s.etag = d.string(forKey: Key.etag)
        }
        return s
    }

    /// nil fields remove their key.
    public func save(to d: UserDefaults) {
        func put(_ v: Any?, _ k: String) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        put(lastCheckedAt, Key.lastCheckedAt)
        put(etag, Key.etag)
        put(latest?.tag, Key.latestTag)
        put(latest?.url.absoluteString, Key.latestURL)
        put(latest?.publishedAt, Key.latestPublishedAt)
        put(lastNotifiedVersion, Key.lastNotifiedVersion)
        put(retryNotBefore, Key.retryNotBefore)
        put(lastError, Key.lastError)
        d.set(permissionRequested, forKey: Key.permissionRequested)
    }

    /// A version counts as notified only when the notification was actually posted (user decision U3), so turning
    /// alerts on later still tells you once.
    public mutating func markNotified(_ notice: ReleaseNotice, delivered: Bool) {
        guard delivered else { return }
        lastNotifiedVersion = notice.version.description
    }
}

/// What Settings › About shows under "Last checked".
public struct ReleaseCheckStatus: Sendable, Equatable {
    public var text: String
    public var error: String?
    public var updateAvailable = false
    public init(text: String, error: String? = nil, updateAvailable: Bool = false) {
        self.text = text; self.error = error; self.updateAvailable = updateAvailable
    }
}

/// One answer to the GET: an HTTP response (any status), or a transport failure.
public enum ReleaseHTTPResponse: Sendable { case http(status: Int, headers: [String: String], body: Data), transport(URLError.Code) }
/// `retryWithoutETag`: a 304 arrived with nothing cached; the caller asks once more without If-None-Match, and not again.
public enum ReleaseStepOutcome: Sendable, Equatable { case done, retryWithoutETag }

extension ReleaseCheck {
    public static let unreadableText = "Couldn't read the latest release"
    public static let rateLimitText = "GitHub rate limit; will retry later"

    /// Applies one response. Always sets lastCheckedAt = now, so a failure waits the normal 24 h (a rate limit may
    /// make that longer through retryNotBefore, never shorter). Errors keep the last good result.
    public static func next(state: ReleaseCheckState, response: ReleaseHTTPResponse, now: Date)
        -> (state: ReleaseCheckState, outcome: ReleaseStepOutcome) {
        var s = state
        s.lastCheckedAt = now
        switch response {
        case .transport(let code):
            s.lastError = "Couldn't check: " + reason(code)
        case .http(let status, let headers, let body):
            if let retry = rateLimitRetry(status: status, headers: headers, now: now) {
                s.retryNotBefore = retry
                s.lastError = rateLimitText
                return (s, .done)
            }
            switch status {
            case 200:
                switch ReleaseInfo.decode(body) {
                case .stable(let r):
                    s.latest = r
                    s.etag = headers.first { $0.key.lowercased() == "etag" }?.value
                    s.lastError = nil; s.retryNotBefore = nil
                case .noStableRelease:
                    s.etag = nil; s.lastError = nil; s.retryNotBefore = nil
                case .unreadable:
                    s.latest = nil; s.etag = nil; s.lastError = unreadableText
                }
            case 304:
                guard s.latest != nil else { s.etag = nil; return (s, .retryWithoutETag) }
                s.lastError = nil; s.retryNotBefore = nil
            case 404:
                s.lastError = unreadableText
            default:
                s.lastError = "Couldn't check: GitHub returned \(status)"
            }
        }
        return (s, .done)
    }

    private static func reason(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost: "offline"
        case .timedOut: "timed out"
        case .cannotFindHost, .dnsLookupFailed: "GitHub not found (DNS)"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: "secure connection failed"
        default: "couldn't reach GitHub"
        }
    }

    /// The Settings status line, and a second line for an error that came after a good result. A newer cached release
    /// stays on the first line even when the latest check failed (errors keep the last good result); the view adds the
    /// "View Release" link only when `updateAvailable`.
    public static func status(state: ReleaseCheckState, installed: ReleaseVersion?, demo: Bool) -> ReleaseCheckStatus {
        if demo { return ReleaseCheckStatus(text: "Not available in demo mode") }
        guard let installed else { return ReleaseCheckStatus(text: "Version unknown (development build); update checks are off") }
        if let l = state.latest, ReleaseVersion.isNewer(remote: l.version, installed: installed) {
            return ReleaseCheckStatus(text: "FlightDeck \(l.version) is available", error: state.lastError, updateAvailable: true)
        }
        if let e = state.lastError { return ReleaseCheckStatus(text: e) }
        return ReleaseCheckStatus(text: state.lastCheckedAt == nil ? "Never checked" : "Up to date")
    }
}
