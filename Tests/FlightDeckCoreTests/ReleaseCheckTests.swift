// Update checks without the network: version comparison, the release decoder and link validator, the schedule,
// Check Now, rate-limit and notify rules, the saved state and the response step, and the one GET (through a stub).
import XCTest
@testable import FlightDeckCore

final class ReleaseCheckTests: XCTestCase {
    let v = { (s: String) in ReleaseVersion(s)! }

    // MARK: Versions

    func testVersionComparisonTable() {
        XCTAssertTrue(ReleaseVersion.isNewer(remote: v("1.6.1"), installed: v("1.6.0")))
        XCTAssertTrue(ReleaseVersion.isNewer(remote: v("1.7"), installed: v("1.6.0")))
        XCTAssertTrue(ReleaseVersion.isNewer(remote: v("2.0.0"), installed: v("1.6.0")))
        XCTAssertFalse(ReleaseVersion.isNewer(remote: v("1.6.0"), installed: v("1.6.0")))
        XCTAssertFalse(ReleaseVersion.isNewer(remote: v("1.5.9"), installed: v("1.6.0")))
        XCTAssertTrue(ReleaseVersion.isNewer(remote: v("v1.10.0"), installed: v("1.9.0")))   // numeric, not lexicographic
        XCTAssertEqual(v("1.6"), v("1.6.0"))
        XCTAssertEqual(v("1.6").hashValue, v("1.6.0").hashValue)
        XCTAssertEqual(v("1.6").description, "1.6")
        XCTAssertEqual(ReleaseVersion.installed(shortVersion: "1.6.0-3-gabc", build: "3-gabc"), v("1.6.0"))
    }

    func testRemoteTagClassification() {
        XCTAssertEqual(ReleaseVersion.remote(tag: "v1.7.0-beta.1"), .prerelease)
        XCTAssertEqual(ReleaseVersion.remote(tag: "v1.7.0-rc1"), .prerelease)
        XCTAssertEqual(ReleaseVersion.remote(tag: "v1.7.0+build5"), .stable(v("1.7.0")))
        XCTAssertEqual(ReleaseVersion.remote(tag: " v1.7.0 "), .stable(v("1.7.0")))
        for g in ["", "v", "latest", "1..2", "1.2.x", "v1.2.", "99999999999999999999.0"] {
            XCTAssertEqual(ReleaseVersion.remote(tag: g), .unparseable, g)
        }
    }

    func testInstalledUnknown() {
        XCTAssertNil(ReleaseVersion.installed(shortVersion: "1.0", build: "1"))
        XCTAssertNil(ReleaseVersion.installed(shortVersion: nil, build: nil))
        XCTAssertNil(ReleaseVersion.installed(shortVersion: "—", build: "—"))
        XCTAssertEqual(ReleaseVersion.installed(shortVersion: "1.0", build: "42"), v("1.0"))
    }

    // MARK: Decoder and link validator

    /// A trimmed but real-shaped `/releases/latest` body.
    static func fixture(tag: String = "v1.7.0", draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {
          "url": "https://api.github.com/repos/cemeyer2/flightdeck/releases/261234567",
          "html_url": "https://github.com/cemeyer2/flightdeck/releases/tag/\(tag)",
          "id": 261234567,
          "author": { "login": "cemeyer2", "id": 1234, "type": "User", "site_admin": false },
          "node_id": "RE_kwDOexample",
          "tag_name": "\(tag)",
          "target_commitish": "main",
          "name": "FlightDeck 1.7.0",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "created_at": "2026-11-20T17:58:40Z",
          "published_at": "2026-11-20T18:04:11Z",
          "assets": [
            { "name": "FlightDeck-1.7.0.zip", "size": 9876543, "download_count": 12,
              "browser_download_url": "https://github.com/cemeyer2/flightdeck/releases/download/v1.7.0/FlightDeck-1.7.0.zip" }
          ],
          "tarball_url": "https://api.github.com/repos/cemeyer2/flightdeck/tarball/v1.7.0",
          "body": "What's new…"
        }
        """.utf8)
    }

    func testDecodesRealShapedRelease() {
        guard case .stable(let r) = ReleaseInfo.decode(Self.fixture()) else { return XCTFail("not stable") }
        XCTAssertEqual(r.version, ReleaseVersion("1.7.0"))
        XCTAssertEqual(r.tag, "v1.7.0")
        XCTAssertEqual(r.name, "FlightDeck 1.7.0")
        XCTAssertEqual(r.url.absoluteString, "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0")
        XCTAssertNotNil(r.publishedAt)
    }

    func testPrereleaseOrDraftIgnored() {
        XCTAssertEqual(ReleaseInfo.decode(Self.fixture(prerelease: true)), .noStableRelease)
        XCTAssertEqual(ReleaseInfo.decode(Self.fixture(draft: true)), .noStableRelease)
        XCTAssertEqual(ReleaseInfo.decode(Self.fixture(tag: "v1.7.0-beta.1")), .noStableRelease)
    }

    func testUnreadableBodies() {
        XCTAssertEqual(ReleaseInfo.decode(Data("<html>".utf8)), .unreadable)
        XCTAssertEqual(ReleaseInfo.decode(Data("{}".utf8)), .unreadable)
        XCTAssertEqual(ReleaseInfo.decode(Self.fixture(tag: "nightly")), .unreadable)
    }

    func testLinkValidatorAcceptsGood() {
        XCTAssertTrue(ReleaseInfo.isTrustedReleaseURL(URL(string: "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0")!))
        XCTAssertEqual(ReleaseInfo.releaseURL(htmlURL: "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0", tag: "v1.7.0").absoluteString,
                       "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0")
    }

    func testLinkValidatorFallsBack() {
        let fallback = "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0"
        let bad: [String?] = [
            "http://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0",
            "https://github.com.evil.example/cemeyer2/flightdeck/releases/tag/v1.7.0",
            "https://user:pw@github.com/cemeyer2/flightdeck/releases/tag/v1.7.0",
            "https://github.com:8443/cemeyer2/flightdeck/releases/tag/v1.7.0",
            "https://github.com/someoneelse/flightdeck/releases/tag/v1.7.0",
            nil,
        ]
        for b in bad { XCTAssertEqual(ReleaseInfo.releaseURL(htmlURL: b, tag: "v1.7.0").absoluteString, fallback, b ?? "nil") }
    }

    func testLinkValidatorRejectsTraversalAndLookalikes() {
        for s in ["https://github.com/cemeyer2/flightdeck/releases/../../evil/x",
                  "https://github.com/cemeyer2/flightdeck/releases/tag/v1?next=https://evil.example",
                  "https://GitHub.com@evil.example/cemeyer2/flightdeck/releases/tag/v1.7.0",
                  "https://user@github.com/cemeyer2/flightdeck/releases/tag/v1.7.0",
                  "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0#x",
                  "https://github.com/cemeyer2/flightdeck/releases/%2E%2E/x"] {
            XCTAssertFalse(ReleaseInfo.isTrustedReleaseURL(URL(string: s)!), s)
        }
        XCTAssertTrue(ReleaseInfo.isTrustedReleaseURL(URL(string: "https://GitHub.com/cemeyer2/flightdeck/releases/tag/v1.7.0")!))
    }

    func testFallbackIsPercentEncoded() {
        XCTAssertEqual(ReleaseInfo.releaseURL(htmlURL: nil, tag: "v1.7.0+build5").absoluteString,
                       "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0%2Bbuild5")
    }

    // MARK: Rules

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func due(lastCheckedAt: Date?, retryNotBefore: Date? = nil, enabled: Bool = true, demo: Bool = false, versionKnown: Bool = true) -> Bool {
        ReleaseCheck.shouldCheck(now: now, lastCheckedAt: lastCheckedAt, retryNotBefore: retryNotBefore, enabled: enabled,
                                 demo: demo, versionKnown: versionKnown)
    }

    func testScheduleRule() {
        XCTAssertTrue(due(lastCheckedAt: nil))
        XCTAssertFalse(due(lastCheckedAt: now - 23 * 3600))
        XCTAssertTrue(due(lastCheckedAt: now - 25 * 3600))
        // The scheduled path never checks with the toggle off.
        for last in [nil, now - 23 * 3600, now - 25 * 3600, now + 86_400 * 3] { XCTAssertFalse(due(lastCheckedAt: last, enabled: false)) }
        XCTAssertFalse(due(lastCheckedAt: nil, demo: true))
        XCTAssertFalse(due(lastCheckedAt: nil, versionKnown: false))
        XCTAssertFalse(due(lastCheckedAt: nil, retryNotBefore: now + 600))
    }

    func testFutureLastCheckedIsDue() {
        XCTAssertTrue(due(lastCheckedAt: now + 3 * 86_400))
    }

    func testFarFutureRetryIsDiscardedNotReclamped() {
        XCTAssertNil(ReleaseCheck.effectiveRetry(now + 30 * 86_400, now: now))
        XCTAssertEqual(ReleaseCheck.effectiveRetry(now + 3600, now: now), now + 3600)
        XCTAssertTrue(due(lastCheckedAt: nil, retryNotBefore: now + 30 * 86_400))
        XCTAssertEqual(ReleaseCheck.checkNowAvailability(demo: false, versionKnown: true, inFlight: false, now: now,
                                                         retryNotBefore: now + 30 * 86_400), .available)
    }

    func testCheckNowAvailability() {
        func a(demo: Bool = false, versionKnown: Bool = true, inFlight: Bool = false, at: Date? = nil, retry: Date? = nil) -> CheckNowAvailability {
            ReleaseCheck.checkNowAvailability(demo: demo, versionKnown: versionKnown, inFlight: inFlight, now: at ?? now, retryNotBefore: retry)
        }
        // No `enabled` parameter: Check Now works with automatic checks off (user decision U1).
        XCTAssertEqual(a(), .available)
        XCTAssertEqual(a(demo: true), .demo)
        XCTAssertEqual(a(versionKnown: false), .unknownVersion)
        XCTAssertEqual(a(inFlight: true), .inFlight)
        XCTAssertEqual(a(retry: now + 600), .rateLimited(until: now + 600))
        XCTAssertEqual(a(at: now + 601, retry: now + 600), .available)
    }

    func testRateLimitHeaderForms() {
        func r(_ status: Int, _ h: [String: String] = [:]) -> Date? { ReleaseCheck.rateLimitRetry(status: status, headers: h, now: now) }
        XCTAssertEqual(r(429), now + 3600)
        XCTAssertEqual(r(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(Int(now.timeIntervalSince1970) + 900)"]), now + 900)
        XCTAssertEqual(r(403, ["retry-after": "120"]), now + 120)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(r(429, ["Retry-After": f.string(from: now + 1800)]), now + 1800)
        XCTAssertNil(r(403, ["X-RateLimit-Remaining": "12"]))
        XCTAssertNil(r(200))
        XCTAssertEqual(r(429, ["Retry-After": "999999"]), now + 86_400)
        XCTAssertEqual(r(429, ["Retry-After": "soon"]), now + 3600)
        XCTAssertEqual(r(429, ["X-RateLimit-Reset": "\(Int(now.timeIntervalSince1970) - 60)"]), now + 3600)
    }

    func release(_ s: String) -> ReleaseInfo {
        ReleaseInfo(tag: "v" + s, version: v(s), url: ReleaseInfo.releaseURL(htmlURL: nil, tag: "v" + s))
    }

    func testNotifyDecision() {
        func n(latest: String = "1.7.0", installed: String = "1.6.0", lastNotified: String? = nil, alerts: Bool = true) -> ReleaseNotice? {
            ReleaseCheck.notice(latest: release(latest), installed: v(installed), lastNotified: lastNotified, alertsEnabled: alerts)
        }
        let first = n()
        XCTAssertEqual(first?.identifier, "update-1.7.0")
        XCTAssertEqual(first?.version, v("1.7.0"))
        XCTAssertEqual(first?.title, "FlightDeck 1.7.0 is available")
        XCTAssertEqual(first?.body, "You have 1.6.0. Click to see what's new.")
        XCTAssertEqual(first?.url, release("1.7.0").url)
        XCTAssertNil(n(lastNotified: "1.7.0"))
        XCTAssertNil(n(lastNotified: "1.7"))
        XCTAssertNil(n(alerts: false))
        XCTAssertNil(n(latest: "1.6.0"))
        XCTAssertNil(n(installed: "1.8.0"))
        XCTAssertNotNil(n(lastNotified: "1.6.5"))
        XCTAssertNotNil(n(lastNotified: "garbage"))
        XCTAssertNil(ReleaseCheck.notice(latest: nil, installed: v("1.6.0"), lastNotified: nil, alertsEnabled: true))
    }

    func testPermissionDecision() {
        for t in [false, true] { for a in [false, true] { for r in [false, true] {
            XCTAssertEqual(ReleaseCheck.shouldRequestPermission(toggledOn: t, alertsEnabled: a, alreadyRequested: r), t && a && !r)
        } } }
    }

    // MARK: Saved state and the response step

    var suite = ""
    var defaults: UserDefaults!
    override func setUp() { suite = "ReleaseCheckTests-\(UUID())"; defaults = UserDefaults(suiteName: suite)! }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func cached() -> ReleaseCheckState {
        var s = ReleaseCheckState()
        s.latest = release("1.7.0"); s.etag = "W/\"abc\""; s.lastCheckedAt = now - 86_400
        return s
    }

    func testStateRoundTrip() {
        var s = ReleaseCheckState()
        s.lastCheckedAt = now; s.etag = "W/\"abc\""
        s.latest = ReleaseInfo(tag: "v1.7.0", version: v("1.7.0"), name: nil,
                               url: URL(string: "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0")!, publishedAt: now - 3600)
        s.lastNotifiedVersion = "1.7.0"; s.retryNotBefore = now + 600; s.lastError = "Couldn't check: offline"
        s.permissionRequested = true
        s.save(to: defaults)
        XCTAssertEqual(ReleaseCheckState.load(from: defaults), s)
        // nil fields remove their keys
        ReleaseCheckState().save(to: defaults)
        XCTAssertEqual(ReleaseCheckState.load(from: defaults), ReleaseCheckState())
        XCTAssertNil(defaults.object(forKey: "updateCheck.etag"))
    }

    func testLoadDropsInvalidCacheAndETag() {
        defaults.set("v1.7.0", forKey: "updateCheck.latestTag")
        defaults.set("https://evil.example/x", forKey: "updateCheck.latestURL")
        defaults.set("W/\"abc\"", forKey: "updateCheck.etag")
        let s = ReleaseCheckState.load(from: defaults)
        XCTAssertNil(s.latest)
        XCTAssertNil(s.etag)
    }

    func testMarkNotifiedOnlyWhenDelivered() {
        var s = cached()
        let installed = v("1.6.0")
        let first = ReleaseCheck.notice(latest: s.latest, installed: installed, lastNotified: s.lastNotifiedVersion, alertsEnabled: true)!
        s.markNotified(first, delivered: false)
        XCTAssertNil(s.lastNotifiedVersion)
        // Alerts off: no notice at all, and nothing recorded.
        XCTAssertNil(ReleaseCheck.notice(latest: s.latest, installed: installed, lastNotified: s.lastNotifiedVersion, alertsEnabled: false))
        // Alerts turned on later: told once.
        let later = ReleaseCheck.notice(latest: s.latest, installed: installed, lastNotified: s.lastNotifiedVersion, alertsEnabled: true)!
        s.markNotified(later, delivered: true)
        XCTAssertEqual(s.lastNotifiedVersion, "1.7.0")
        XCTAssertNil(ReleaseCheck.notice(latest: s.latest, installed: installed, lastNotified: s.lastNotifiedVersion, alertsEnabled: true))
    }

    func step(_ s: ReleaseCheckState, _ r: ReleaseHTTPResponse) -> (state: ReleaseCheckState, outcome: ReleaseStepOutcome) {
        ReleaseCheck.next(state: s, response: r, now: now)
    }

    func testStep200StoresResultAndETag() {
        let (s, o) = step(ReleaseCheckState(), .http(status: 200, headers: ["etag": "W/\"abc\""], body: Self.fixture()))
        XCTAssertEqual(s.latest?.version, v("1.7.0"))
        XCTAssertEqual(s.etag, "W/\"abc\"")
        XCTAssertEqual(s.lastCheckedAt, now)
        XCTAssertNil(s.lastError)
        XCTAssertEqual(o, .done)
    }

    func testStep200NoStableReleaseKeepsLatestClearsETag() {
        let (s, o) = step(cached(), .http(status: 200, headers: ["ETag": "W/\"new\""], body: Self.fixture(tag: "v1.8.0-beta.1")))
        XCTAssertEqual(s.latest, release("1.7.0"))
        XCTAssertNil(s.etag)
        XCTAssertNil(s.lastError)
        XCTAssertEqual(o, .done)
    }

    func testStep304WithCacheReuses() {
        var start = cached(); start.lastError = "Couldn't check: offline"
        let (s, o) = step(start, .http(status: 304, headers: [:], body: Data()))
        XCTAssertEqual(s.latest, start.latest)
        XCTAssertEqual(s.etag, start.etag)
        XCTAssertNil(s.lastError)
        XCTAssertEqual(s.lastCheckedAt, now)
        XCTAssertEqual(o, .done)
    }

    func testStep304WithoutCacheRetriesOnce() {
        var start = ReleaseCheckState(); start.etag = "W/\"abc\""
        let (s, o) = step(start, .http(status: 304, headers: [:], body: Data()))
        XCTAssertEqual(o, .retryWithoutETag)
        XCTAssertNil(s.etag)
    }

    func testStepDecodeFailureClearsETag() {
        let (s, _) = step(cached(), .http(status: 200, headers: ["ETag": "W/\"x\""], body: Data("<html>".utf8)))
        XCTAssertNil(s.etag)
        XCTAssertNil(s.latest)
        XCTAssertEqual(s.lastError, "Couldn't read the latest release")
    }

    func testStepRateLimitKeepsCacheAndSetsRetry() {
        let (s, o) = step(cached(), .http(status: 429, headers: ["Retry-After": "120"], body: Data()))
        XCTAssertEqual(s.retryNotBefore, now + 120)
        XCTAssertEqual(s.lastError, "GitHub rate limit; will retry later")
        XCTAssertEqual(s.latest, release("1.7.0"))
        XCTAssertEqual(s.etag, "W/\"abc\"")
        XCTAssertEqual(o, .done)
    }

    func testStepPlain403IsOrdinaryError() {
        let (s, _) = step(cached(), .http(status: 403, headers: [:], body: Data()))
        XCTAssertEqual(s.lastError, "Couldn't check: GitHub returned 403")
        XCTAssertNil(s.retryNotBefore)
        XCTAssertEqual(s.latest, release("1.7.0"))
    }

    func testStep404IsUnreadable() {
        let (s, _) = step(cached(), .http(status: 404, headers: [:], body: Data()))
        XCTAssertEqual(s.lastError, "Couldn't read the latest release")
        XCTAssertEqual(s.latest, release("1.7.0"))
        XCTAssertEqual(s.lastCheckedAt, now)
    }

    func testStepOfflineKeepsLastGood() {
        let (s, _) = step(cached(), .transport(.notConnectedToInternet))
        XCTAssertEqual(s.lastError, "Couldn't check: offline")
        XCTAssertEqual(s.latest, release("1.7.0"))
        XCTAssertEqual(s.lastCheckedAt, now)
        XCTAssertEqual(step(cached(), .transport(.timedOut)).state.lastError, "Couldn't check: timed out")
        XCTAssertEqual(step(cached(), .transport(.dnsLookupFailed)).state.lastError, "Couldn't check: GitHub not found (DNS)")
        XCTAssertEqual(step(cached(), .transport(.serverCertificateUntrusted)).state.lastError, "Couldn't check: secure connection failed")
        XCTAssertEqual(step(cached(), .transport(.badServerResponse)).state.lastError, "Couldn't check: couldn't reach GitHub")
    }

    func testStatusText() {
        func t(_ s: ReleaseCheckState, installed: String? = "1.6.0", demo: Bool = false) -> ReleaseCheckStatus {
            ReleaseCheck.status(state: s, installed: installed.map(v), demo: demo)
        }
        XCTAssertEqual(t(cached(), demo: true), ReleaseCheckStatus(text: "Not available in demo mode"))
        XCTAssertEqual(t(cached(), installed: nil), ReleaseCheckStatus(text: "Version unknown (development build); update checks are off"))
        var err = cached(); err.lastError = "Couldn't check: offline"
        // A newer cached release stays on the first line; the error goes on a second.
        XCTAssertEqual(t(err), ReleaseCheckStatus(text: "FlightDeck 1.7.0 is available", error: "Couldn't check: offline", updateAvailable: true))
        // No newer release: the error is the status line, with no link.
        XCTAssertEqual(t(err, installed: "1.7.0"), ReleaseCheckStatus(text: "Couldn't check: offline"))
        XCTAssertEqual(t(cached()), ReleaseCheckStatus(text: "FlightDeck 1.7.0 is available", updateAvailable: true))
        XCTAssertEqual(t(ReleaseCheckState()), ReleaseCheckStatus(text: "Never checked"))
        XCTAssertEqual(t(cached(), installed: "1.7.0"), ReleaseCheckStatus(text: "Up to date"))
    }

    // MARK: The one GET

    func testClientSendsPlainRequest() async {
        let body = String(decoding: Self.fixture(), as: UTF8.self)
        ReleaseStub.set { _ in (200, ["ETag": "W/\"abc\""], body) }
        let client = ReleaseCheckClient(timeout: 5, protocolClasses: [ReleaseStub.self])
        let r = await client.fetchLatest(etag: nil)
        guard case .http(let status, let headers, let data) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(headers.first { $0.key.lowercased() == "etag" }?.value, "W/\"abc\"")
        XCTAssertEqual(data, Self.fixture())
        XCTAssertEqual(ReleaseStub.log.count, 1)
        let req = ReleaseStub.log[0]
        XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/repos/cemeyer2/flightdeck/releases/latest")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "FlightDeck")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertNil(req.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"))

        ReleaseStub.set { _ in (304, [:], "") }
        _ = await client.fetchLatest(etag: "W/\"abc\"")
        XCTAssertEqual(ReleaseStub.log.count, 1)
        XCTAssertEqual(ReleaseStub.log[0].value(forHTTPHeaderField: "If-None-Match"), "W/\"abc\"")
    }
}

/// Answers every request from `route` and records requests (the same shape as `UniFiStub`, kept separate).
final class ReleaseStub: URLProtocol, @unchecked Sendable {
    typealias Reply = (status: Int, headers: [String: String], body: String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _route: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) private static var _log: [URLRequest] = []
    static func set(_ r: @escaping @Sendable (URLRequest) -> Reply) { lock.lock(); _route = r; _log = []; lock.unlock() }
    static var log: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _log }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self._log.append(request); let route = Self._route; Self.lock.unlock()
        let r: Reply = route?(request) ?? (404, [:], "")
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
