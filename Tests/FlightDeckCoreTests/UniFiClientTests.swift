// The UniFi HTTP flows against a URLProtocol stub (no real console): API-key Integration API with and without classic
// enrichment, classic login on UniFi OS and on a standalone controller, CSRF handling, re-login after a session expires,
// bad credentials and an unknown site.
import XCTest
@testable import FlightDeckCore

/// Answers every request from `route`, and records requests. Guarded by a lock because the client fetches device
/// details concurrently.
final class UniFiStub: URLProtocol, @unchecked Sendable {
    typealias Reply = (status: Int, headers: [String: String], body: String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _route: (@Sendable (URLRequest, Data?) -> Reply)?
    nonisolated(unsafe) private static var _log: [(URLRequest, Data?)] = []
    static func set(_ r: @escaping @Sendable (URLRequest, Data?) -> Reply) { lock.lock(); _route = r; _log = []; lock.unlock() }
    static var log: [(URLRequest, Data?)] { lock.lock(); defer { lock.unlock() }; return _log }
    static var paths: [String] { log.map { $0.0.url!.path } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession moves POST bodies into a stream before protocols see them.
        var body = request.httpBody
        if body == nil, let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); body = d
        }
        Self.lock.lock(); Self._log.append((request, body)); let route = Self._route; Self.lock.unlock()
        let r: Reply = route?(request, body) ?? (404, [:], "")
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UniFiClientTests: XCTestCase {
    typealias F = UniFiFixtures

    func client(_ auth: UniFiCredentials, site: String = "default") throws -> UniFiAPIClient {
        let kind: UniFiConfig.Auth = { if case .apiKey = auth { return .apiKey }; return .password }()
        return try UniFiAPIClient(config: UniFiConfig(host: "unifi.test", site: site, auth: kind), credentials: auth,
                                  timeout: 5, protocolClasses: [UniFiStub.self])
    }

    /// Classic endpoints under `prefix`, answered only when `ok(request)` holds (else 401).
    static func classic(_ path: String, prefix: String) -> String? {
        switch path {
        case prefix + "/api/self/sites": F.classicSites
        case prefix + "/api/s/default/stat/device": F.statDevice
        case prefix + "/api/s/default/stat/sta": F.statSta
        case prefix + "/api/s/default/stat/health": F.statHealth
        default: nil
        }
    }

    static func integration(_ path: String) -> String? {
        let root = "/proxy/network/integration/v1/sites"
        let site = root + "/88f7af54-98f8-306a-a1c7-c9349722b1f6"
        switch path {
        case root: return F.intSites
        case site + "/devices": return F.intDevices
        case site + "/clients": return F.intClients
        case site + "/devices/d-ap1": return F.intDeviceDetailAP
        case site + "/devices/d-ap1/statistics/latest": return F.intStatsAP
        default: return nil
        }
    }

    func testAPIKeyUsesIntegrationThenClassic() async throws {
        UniFiStub.set { r, _ in
            guard r.value(forHTTPHeaderField: "X-API-KEY") == "k3y" else { return (401, [:], "") }
            let p = r.url!.path
            if let b = Self.integration(p) ?? Self.classic(p, prefix: "/proxy/network") { return (200, [:], b) }
            return (404, [:], "")
        }
        let s = try await client(.apiKey("k3y")).fetch()
        XCTAssertEqual(s.source, .integrationAndClassic)
        XCTAssertEqual(s.site?.name, "default")
        XCTAssertEqual(s.devices.count, 4)
        let ap = try XCTUnwrap(s.device(mac: F.ap1))
        XCTAssertEqual(ap.firmware, "6.6.77"); XCTAssertEqual(ap.cpuPercent, 12.5); XCTAssertEqual(ap.radios.first?.utilizationPercent, 38)
        XCTAssertEqual(s.attachment(ofMAC: "aa:bb:cc:00:00:02")?.link, .wired(port: 5))
        XCTAssertEqual(s.health.isp, "Example Fiber")
        XCTAssertTrue(UniFiStub.log.allSatisfy { $0.0.httpMethod == "GET" }, "read-only: no writes with an API key")
        XCTAssertTrue(UniFiStub.paths.contains("/proxy/network/integration/v1/sites/88f7af54-98f8-306a-a1c7-c9349722b1f6/devices"))
    }

    func testAPIKeyWithoutClassicAccessSaysWhatsMissing() async throws {
        UniFiStub.set { r, _ in
            if let b = Self.integration(r.url!.path) { return (200, [:], b) }
            return (401, [:], #"{"meta":{"rc":"error","msg":"api.err.LoginRequired"}}"#)
        }
        let s = try await client(.apiKey("k")).fetch()
        XCTAssertEqual(s.source, .integration)
        XCTAssertFalse(s.notes.isEmpty)
        XCTAssertNil(s.health.wanIP, "no health data: unknown, not invented")
        XCTAssertEqual(s.clients.first { $0.mac == "aa:bb:cc:00:00:01" }?.apMAC, F.ap1)
    }

    func testPasswordLoginOnUniFiOSSendsCSRF() async throws {
        UniFiStub.set { r, body in
            let p = r.url!.path
            if p == "/api/auth/login" {
                let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                guard json?["username"] as? String == "ro", json?["password"] as? String == "s3cret" else { return (401, [:], "") }
                return (200, ["X-CSRF-Token": "tok1", "Set-Cookie": "TOKEN=abc; Path=/; Secure; HttpOnly"], "{}")
            }
            guard r.value(forHTTPHeaderField: "X-CSRF-Token") == "tok1" else { return (403, [:], "") }
            return Self.classic(p, prefix: "/proxy/network").map { (200, [:], $0) } ?? (404, [:], "")
        }
        let s = try await client(.password(user: "ro", password: "s3cret")).fetch()
        XCTAssertEqual(s.source, .classic); XCTAssertEqual(s.clients.count, 4); XCTAssertEqual(s.health.speedTest?.uploadMbps, 94.5)
        XCTAssertEqual(UniFiStub.paths.filter { $0 == "/api/auth/login" }.count, 1)
        XCTAssertNil(UniFiStub.log.first?.0.value(forHTTPHeaderField: "X-API-KEY"))
    }

    func testStandaloneControllerFallsBackToApiLogin() async throws {
        UniFiStub.set { r, _ in
            let p = r.url!.path
            if p == "/api/auth/login" { return (404, [:], "") }
            if p == "/api/login" { return (200, [:], #"{"meta":{"rc":"ok"},"data":[]}"#) }
            return Self.classic(p, prefix: "").map { (200, [:], $0) } ?? (404, [:], "")
        }
        let s = try await client(.password(user: "u", password: "p")).fetch()
        XCTAssertEqual(s.devices.count, 4)
        XCTAssertTrue(UniFiStub.paths.contains("/api/s/default/stat/sta"), "no /proxy/network prefix on a standalone controller")
    }

    func testReloginOnceWhenSessionExpires() async throws {
        let state = Counter()
        UniFiStub.set { r, _ in
            let p = r.url!.path
            if p == "/api/auth/login" { state.bump(); return (200, [:], "{}") }
            // The first device read fails as if the session had expired.
            if p.hasSuffix("stat/device") && state.value == 1 { return (401, [:], F.loginRequired) }
            return Self.classic(p, prefix: "/proxy/network").map { (200, [:], $0) } ?? (404, [:], "")
        }
        let s = try await client(.password(user: "u", password: "p")).fetch()
        XCTAssertEqual(s.devices.count, 4); XCTAssertEqual(state.value, 2)
    }

    func testBadCredentialsAndUnknownSite() async throws {
        UniFiStub.set { r, _ in r.url!.path == "/api/auth/login" ? (401, [:], "") : (404, [:], "") }
        do { _ = try await client(.password(user: "u", password: "wrong")).fetch(); XCTFail("expected an error") }
        catch let e as UniFiError { if case .unauthorized = e {} else { XCTFail("\(e)") } }

        UniFiStub.set { r, _ in Self.integration(r.url!.path).map { (200, [:], $0) } ?? (404, [:], "") }
        do { _ = try await client(.apiKey("k"), site: "garage").fetch(); XCTFail("expected an error") }
        catch let e as UniFiError { XCTAssertEqual(e, .siteNotFound("garage", available: ["default"])) }
    }
}

/// A thread-safe counter for stub routes (which run on URLSession's threads).
final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
