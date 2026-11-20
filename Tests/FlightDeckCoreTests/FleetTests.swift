// Fleet tests: pairing (right code, wrong code, abandoned sessions, lockout, closed window), request authentication
// (good, bad MAC, replayed, stale, unknown viewer), sealed replies, redaction and the status builder. The localhost
// round trip is in FleetNetworkTests.
import XCTest
@testable import FlightDeckCore

final class FleetTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Runs the whole exchange in process. Returns the guest's secret and the host's new peer (nil on failure).
    func pair(_ host: FleetPairingHost, code: String, now: Date) -> (guest: Data?, peer: FleetPeer?, error: FleetError?) {
        guard let g = FleetPairingGuest(viewerID: "viewer-1", code: code) else { return (nil, nil, FleetError(400, "bad code")) }
        let st: FleetPairing.Started
        switch host.start(.init(viewerID: "viewer-1", viewerName: "Air", publicKey: g.publicKey), now: now) {
        case .failure(let e): return (nil, nil, e)
        case .success(let v): st = v
        }
        XCTAssertTrue(g.started(st))
        var peer: FleetPeer?
        for i in 1...FleetPairing.rounds {
            switch host.commit(.init(session: st.session, round: i, commitment: g.commitment(round: i)), now: now) {
            case .failure(let e): return (nil, nil, e)
            case .success(let proof):
                // The host's proof only checks out for a guest holding the right digit; a mismatch reveals nothing.
                guard let nonce = g.reveal(round: i, proof: proof) else {
                    // A real guest stops here; tell the host the wrong digit anyway to exercise its check.
                    let r = host.reveal(.init(session: st.session, round: i, nonce: FleetCrypto.random(16).base64EncodedString()), now: now)
                    if case .failure(let e) = r { return (nil, nil, e) }
                    return (nil, nil, FleetError(0, "guest refused proof"))
                }
                switch host.reveal(.init(session: st.session, round: i, nonce: nonce), now: now) {
                case .failure(let e): return (nil, nil, e)
                case .success(let (r, p)): XCTAssertEqual(r.done, i == FleetPairing.rounds); peer = p
                }
            }
        }
        return (g.secret(hostID: host.hostID), peer, nil)
    }

    func testPairingWithTheRightCodeAgreesOnASecret() {
        let host = FleetPairingHost(hostID: "host-1", hostName: "Studio")
        let code = host.open(now: t0)
        XCTAssertEqual(code.count, 6)
        let r = pair(host, code: code, now: t0)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.guest?.count, 32)
        XCTAssertEqual(r.guest, r.peer?.secretData)
        XCTAssertEqual(r.peer?.id, "viewer-1"); XCTAssertEqual(r.peer?.name, "Air")
        XCTAssertFalse(host.isOpen(now: t0), "pairing closes after a success")
        XCTAssertTrue(pair(host, code: code, now: t0).error?.status == 403, "the code can't be used twice")
    }

    func testCodesAreTypedLeniently() {
        XCTAssertEqual(FleetCrypto.digits("123 456"), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(FleetCrypto.digits("123-456"), [1, 2, 3, 4, 5, 6])
        XCTAssertNil(FleetCrypto.digits("12345"))
        XCTAssertNil(FleetCrypto.digits("12345a"))
        XCTAssertNil(FleetCrypto.digits("١٢٣٤٥٦"), "only ASCII digits")
    }

    func testWrongCodeFailsAndChangesTheCode() {
        let host = FleetPairingHost(hostID: "host-1", hostName: "Studio")
        let code = host.open(now: t0)
        let wrong = String(code.prefix(5)) + String((Int(String(code.last!))! + 1) % 10)
        let r = pair(host, code: wrong, now: t0)
        XCTAssertEqual(r.error?.status, 403)
        XCTAssertNil(r.peer)
        XCTAssertNotNil(host.code)
        XCTAssertNotEqual(host.code, code, "a failed attempt replaces the code")
    }

    func testTooManyFailuresLockPairing() {
        let host = FleetPairingHost(hostID: "host-1", hostName: "Studio")
        host.open(now: t0)
        for _ in 0..<FleetPairingHost.maxFailures {
            let c = host.code!
            let r = pair(host, code: String((Int(String(c.first!))! + 1) % 10) + c.dropFirst(), now: t0)
            XCTAssertEqual(r.error?.status, 403)
        }
        XCTAssertNotNil(host.lockedFor(now: t0))
        XCTAssertEqual(pair(host, code: host.code!, now: t0).error?.status, 429, "even the right code waits out the lockout")
        XCTAssertNil(host.lockedFor(now: t0.addingTimeInterval(FleetPairingHost.failureWindow + 1)))
    }

    func testAbandonedSessionCountsAsAFailure() {
        let host = FleetPairingHost(hostID: "host-1", hostName: "Studio")
        let code = host.open(now: t0)
        let g = FleetPairingGuest(viewerID: "v", code: "000000")!
        guard case .success(let st) = host.start(.init(viewerID: "v", viewerName: "x", publicKey: g.publicKey), now: t0) else { return XCTFail() }
        _ = g.started(st)
        // An attacker commits blind, learns digit 1 from the proof, and never reveals.
        guard case .success = host.commit(.init(session: st.session, round: 1, commitment: g.commitment(round: 1)), now: t0) else { return XCTFail() }
        // Meanwhile nobody else may start.
        let other = FleetPairingGuest(viewerID: "w", code: code)!
        if case .failure(let e) = host.start(.init(viewerID: "w", viewerName: "y", publicKey: other.publicKey), now: t0) { XCTAssertEqual(e.status, 409) } else { XCTFail() }
        // Once it times out, the code has changed.
        let later = t0.addingTimeInterval(FleetPairingHost.sessionTimeout + 1)
        _ = host.start(.init(viewerID: "w", viewerName: "y", publicKey: other.publicKey), now: later)
        XCTAssertNotEqual(host.code, code)
    }

    func testPairingRefusedWhileClosed() {
        let host = FleetPairingHost(hostID: "h", hostName: "n")
        let g = FleetPairingGuest(viewerID: "v", code: "123456")!
        if case .failure(let e) = host.start(.init(viewerID: "v", viewerName: "x", publicKey: g.publicKey), now: t0) { XCTAssertEqual(e.status, 403) } else { XCTFail() }
        host.open(now: t0)
        let late = t0.addingTimeInterval(FleetPairingHost.windowLength + 1)
        if case .failure(let e) = host.start(.init(viewerID: "v", viewerName: "x", publicKey: g.publicKey), now: late) { XCTAssertEqual(e.status, 403) } else { XCTFail() }
    }

    // MARK: Requests

    func server(status: FleetStatus? = nil) -> (FleetServer, FleetPeer) {
        let store = FleetStore(dir: nil)
        let secret = FleetCrypto.random(32)
        let viewer = FleetPeer(id: "viewer-1", name: "Air", secret: secret, pairedAt: t0)
        store.addViewer(viewer)
        let s = status ?? FleetStatus(identity: FleetIdentity(id: store.instanceID, name: "Studio", model: "Mac14,13", kind: "studio", macOS: "15", appVersion: "dev"),
                                      vitals: nil, findings: [], incidents: [], history: [])
        return (FleetServer(store: store, hostName: "Studio") { s }, viewer)
    }

    func headers(_ h: [(String, String)]) -> [String: String] { Dictionary(uniqueKeysWithValues: h.map { ($0.0.lowercased(), $0.1) }) }

    func testSignedRequestIsAcceptedOnceAndRepliesAreSealed() async throws {
        let (srv, viewer) = server()
        let signed = FleetCrypto.signedHeaders(secret: viewer.secretData, method: "GET", path: "/v1/status", clientID: viewer.id, hostID: srv.hostID, now: t0)
        let r = await srv.handle(method: "GET", path: "/v1/status", headers: headers(signed.headers), body: Data(), now: t0)
        XCTAssertEqual(r.status, 200)
        XCTAssertNil(try? JSONDecoder.fleet.decode(FleetStatus.self, from: r.body), "the body is sealed, not plain JSON")
        let opened = try FleetCrypto.openResponse(r.body, secret: viewer.secretData, requestNonce: signed.nonce, hostID: srv.hostID)
        XCTAssertEqual(try JSONDecoder.fleet.decode(FleetStatus.self, from: opened).identity.name, "Studio")
        XCTAssertThrowsError(try FleetCrypto.openResponse(r.body, secret: viewer.secretData, requestNonce: "other", hostID: srv.hostID),
                             "a reply is bound to its request")
        XCTAssertThrowsError(try FleetCrypto.openResponse(r.body, secret: FleetCrypto.random(32), requestNonce: signed.nonce, hostID: srv.hostID))
        // The same request again is a replay.
        let again = await srv.handle(method: "GET", path: "/v1/status", headers: headers(signed.headers), body: Data(), now: t0.addingTimeInterval(5))
        XCTAssertEqual(again.status, 401)
    }

    func testBadStaleAndUnknownRequestsAreRefused() async {
        let (srv, viewer) = server()
        func status(_ h: [(String, String)], now: Date? = nil) async -> Int {
            await srv.handle(method: "GET", path: "/v1/status", headers: headers(h), body: Data(), now: now ?? t0).status
        }
        let wrongKey = FleetCrypto.signedHeaders(secret: FleetCrypto.random(32), method: "GET", path: "/v1/status", clientID: viewer.id, hostID: srv.hostID, now: t0)
        let ok1 = await status(wrongKey.headers); XCTAssertEqual(ok1, 401)
        let otherPath = FleetCrypto.signedHeaders(secret: viewer.secretData, method: "GET", path: "/v1/hello", clientID: viewer.id, hostID: srv.hostID, now: t0)
        let ok2 = await status(otherPath.headers); XCTAssertEqual(ok2, 401, "the MAC covers the path")
        let otherHost = FleetCrypto.signedHeaders(secret: viewer.secretData, method: "GET", path: "/v1/status", clientID: viewer.id, hostID: "someone-else", now: t0)
        let ok3 = await status(otherHost.headers); XCTAssertEqual(ok3, 401, "the MAC covers the host ID")
        let stale = FleetCrypto.signedHeaders(secret: viewer.secretData, method: "GET", path: "/v1/status", clientID: viewer.id, hostID: srv.hostID, now: t0)
        let ok4 = await status(stale.headers, now: t0.addingTimeInterval(FleetCrypto.clockWindow + 1)); XCTAssertEqual(ok4, 401)
        let unknown = FleetCrypto.signedHeaders(secret: viewer.secretData, method: "GET", path: "/v1/status", clientID: "stranger", hostID: srv.hostID, now: t0)
        let ok5 = await status(unknown.headers); XCTAssertEqual(ok5, 401)
        let ok6 = await status([]); XCTAssertEqual(ok6, 401)
        // A removed viewer is refused from then on.
        srv.store.removeViewer(viewer.id)
        let fresh = FleetCrypto.signedHeaders(secret: viewer.secretData, method: "GET", path: "/v1/status", clientID: viewer.id, hostID: srv.hostID, now: t0)
        let ok7 = await status(fresh.headers); XCTAssertEqual(ok7, 401)
    }

    func testHelloSaysOnlyWhoItIs() async throws {
        let (srv, _) = server()
        let r = await srv.handle(method: "GET", path: "/v1/hello", headers: [:], body: Data(), now: t0)
        let h = try JSONDecoder.fleet.decode(FleetHello.self, from: r.body)
        XCTAssertEqual(h.name, "Studio"); XCTAssertFalse(h.pairingOpen)
        let keys = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        XCTAssertEqual(Set(keys.keys), ["proto", "id", "name", "pairingOpen"])
        let post = await srv.handle(method: "POST", path: "/v1/status", headers: [:], body: Data(), now: t0)
        XCTAssertEqual(post.status, 405)
        let unknown = await srv.handle(method: "GET", path: "/v1/kill", headers: [:], body: Data(), now: t0)
        XCTAssertEqual(unknown.status, 404)
    }
}
