// The update check's rules, all pure: when a scheduled check is due, when Check Now may ask, how GitHub's rate-limit
// headers become a retry time, and when a new version earns its one notification. No stored value can stop checks for
// more than about a day: a future last-check time counts as stale, and a retry time over 24 h ahead is discarded.
import Foundation

/// Whether the Check Now button may make a request, and if not, why (shown under the button).
public enum CheckNowAvailability: Sendable, Equatable { case available, demo, unknownVersion, inFlight, rateLimited(until: Date) }

/// The one notification for a new version. The identifier is stable per version, so a re-post replaces rather than stacks.
public struct ReleaseNotice: Sendable, Equatable {
    public var identifier, title, body: String
    public var url: URL
}

extension ReleaseCheck {
    public static let interval: TimeInterval = 86_400, wake: TimeInterval = 3_600, launchDelay: TimeInterval = 60
    public static let maxRetryDelay: TimeInterval = 86_400, defaultRateLimitDelay: TimeInterval = 3_600

    /// A retryNotBefore more than maxRetryDelay ahead of now is discarded (nil), never re-clamped: clamping it on every
    /// read would keep it a day away forever.
    public static func effectiveRetry(_ retryNotBefore: Date?, now: Date) -> Date? {
        guard let r = retryNotBefore, r.timeIntervalSince(now) <= maxRetryDelay else { return nil }
        return r
    }

    /// Whether the hourly wake should ask GitHub. Never with the toggle off, in demo mode, or for an unknown version.
    public static func shouldCheck(now: Date, lastCheckedAt: Date?, retryNotBefore: Date?, enabled: Bool,
                                   demo: Bool, versionKnown: Bool) -> Bool {
        guard enabled, !demo, versionKnown else { return false }
        if let r = effectiveRetry(retryNotBefore, now: now), r > now { return false }
        guard let last = lastCheckedAt, last <= now else { return true }   // never, or the clock went back
        return now.timeIntervalSince(last) >= interval
    }

    /// Check Now works whether or not automatic checks are on (user decision U1), so there is no `enabled` here.
    public static func checkNowAvailability(demo: Bool, versionKnown: Bool, inFlight: Bool,
                                            now: Date, retryNotBefore: Date?) -> CheckNowAvailability {
        if demo { return .demo }
        if !versionKnown { return .unknownVersion }
        if inFlight { return .inFlight }
        if let r = effectiveRetry(retryNotBefore, now: now), r > now { return .rateLimited(until: r) }
        return .available
    }

    /// nil = not a rate limit. 429, or 403 with x-ratelimit-remaining "0" or a retry-after header (any other 403 is an
    /// ordinary error). Header names are case-insensitive; Retry-After is seconds or an HTTP-date, X-RateLimit-Reset
    /// epoch seconds. A past or garbage value means now + defaultRateLimitDelay; the result is at most now + maxRetryDelay.
    public static func rateLimitRetry(status: Int, headers: [String: String], now: Date) -> Date? {
        var h: [String: String] = [:]
        for (k, v) in headers { h[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        let retryAfter = h["retry-after"]
        guard status == 429 || status == 403 && (h["x-ratelimit-remaining"] == "0" || retryAfter != nil) else { return nil }
        var at: Date?
        if let s = retryAfter {
            if let n = Int(s) { at = now + TimeInterval(n) } else { at = httpDate(s) }
        }
        if at.map({ $0 <= now }) ?? true, let s = h["x-ratelimit-reset"], let n = Int(s) {
            at = Date(timeIntervalSince1970: TimeInterval(n))
        }
        guard let t = at, t > now else { return now + defaultRateLimitDelay }
        return min(t, now + maxRetryDelay)
    }

    private static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    /// The notification for `latest`, or nil: only with alerts on, only when it's newer than this copy, and only once per
    /// version (a nil or unparseable `lastNotified` counts as never notified).
    public static func notice(latest: ReleaseInfo?, installed: ReleaseVersion, lastNotified: String?,
                              alertsEnabled: Bool) -> ReleaseNotice? {
        guard alertsEnabled, let latest, ReleaseVersion.isNewer(remote: latest.version, installed: installed) else { return nil }
        if let last = lastNotified.flatMap(ReleaseVersion.init), latest.version <= last { return nil }
        return ReleaseNotice(identifier: "update-\(latest.version)", title: "FlightDeck \(latest.version) is available",
                             body: "You have \(installed). Click to see what's new.", url: latest.url)
    }

    /// Turning update checks on asks for notification permission once, and only if alerts are on (user decision U3).
    public static func shouldRequestPermission(toggledOn: Bool, alertsEnabled: Bool, alreadyRequested: Bool) -> Bool {
        toggledOn && alertsEnabled && !alreadyRequested
    }
}
