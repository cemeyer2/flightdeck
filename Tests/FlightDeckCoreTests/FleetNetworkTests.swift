// Fleet over a real socket (127.0.0.1 only, no Bonjour): pairing, a signed status read, refusals, the local-address
// filter, redaction and the status builder.
import XCTest
import Network
@testable import FlightDeckCore

final class FleetNetworkTests: XCTestCase {
    func identity(_ id: String) -> FleetIdentity { FleetIdentity(id: id, name: "Studio", model: "Mac14,13", kind: "studio", macOS: "15.1", appVersion: "dev") }

    func testLocalhostRoundTrip() async throws {
        let hostStore = FleetStore(dir: nil)
        let ident = identity(hostStore.instanceID)
        let snap = MetricsExportTests().snapshot()
        let finding = Finding(id: "mem-pressure", severity: .warning, icon: "memorychip", title: "Memory pressure is critical", detail: nil, since: snap.time,
                              destination: "Performance:Memory", pids: [123])
        let status = FleetStatus.build(identity: ident, snapshot: snap, findings: [finding], incidents: [], history: [FleetPoint(snap)], uptime: 3600,
                                       redaction: FleetRedaction(names: []))
        let server = FleetServer(store: hostStore, hostName: "Studio") { status }
        let listener = FleetListener(server: server, port: 0, advertise: false, loopbackOnly: true)
        let ready = expectation(description: "listening")
        listener.start { err in XCTAssertNil(err); ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.stop() }
        guard let port = listener.port else { throw XCTSkip("couldn't bind a loopback port") }
        let client = FleetClient(host: "127.0.0.1", port: port)

        let hello = try await client.hello()
        XCTAssertEqual(hello.name, "Studio"); XCTAssertFalse(hello.pairingOpen)

        // Pairing closed: refused.
        do { _ = try await client.pair(code: "123456", viewerID: "v1", viewerName: "Air"); XCTFail("paired while closed") }
        catch let e as FleetError { XCTAssertEqual(e.status, 403) }

        let code = server.openPairing()
        let open = try await client.hello()
        XCTAssertTrue(open.pairingOpen)
        // A wrong code fails on the viewer's side (the host's proof doesn't match) without revealing anything.
        let wrong = String((Int(String(code.first!))! + 1) % 10) + code.dropFirst()
        do { _ = try await client.pair(code: wrong, viewerID: "v1", viewerName: "Air"); XCTFail("paired with a wrong code") }
        catch let e as FleetError { XCTAssertEqual(e.status, 403) }
        // The viewer ends the session at once (counted as a failure, so the host shows a new code), not blocking pairing.
        let code2 = try XCTUnwrap(server.pairingState().code)
        XCTAssertNotEqual(code2, code)
        let host = try await client.pair(code: code2, viewerID: "v1", viewerName: "Air")
        XCTAssertEqual(host.id, hostStore.instanceID)
        XCTAssertEqual(hostStore.viewer("v1")?.secret, host.secret)

        let s = try await client.status(host: host, viewerID: "v1")
        XCTAssertEqual(s.identity, ident)
        XCTAssertEqual(s.vitals?.cpu.value, 42.5)
        XCTAssertEqual(s.findings.first?.kind, "mem-pressure")

        // Unpaired viewer and a forged secret are refused.
        var forged = host; forged.secret = FleetCrypto.random(32).base64EncodedString()
        do { _ = try await client.status(host: forged, viewerID: "v1"); XCTFail() } catch let e as FleetError { XCTAssertEqual(e.status, 401) }
        do { _ = try await client.status(host: host, viewerID: "v2"); XCTFail() } catch let e as FleetError { XCTAssertEqual(e.status, 401) }
    }

    func testOnlyLocalAddressesAreServed() {
        func ep(_ s: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(s), port: 1) }
        for a in ["10.0.0.5", "172.16.1.1", "172.31.255.1", "192.168.1.20", "169.254.3.4", "127.0.0.1", "::1", "fe80::1", "fd12:3456::1", "::ffff:192.168.1.2"] {
            XCTAssertTrue(FleetNetwork.isLocal(ep(a)), a)
        }
        for a in ["8.8.8.8", "172.32.0.1", "100.64.0.1", "2001:db8::1", "::ffff:8.8.8.8"] { XCTAssertFalse(FleetNetwork.isLocal(ep(a)), a) }
        XCTAssertFalse(FleetNetwork.isLocal(.service(name: "x", type: "_t._tcp", domain: "local.", interface: nil)))
    }

    func testRedactionScrubsPrivateDetails() {
        let r = FleetRedaction(names: ["/Users/alice", "alice", "Alice Smith"])
        let cases: [(String, String)] = [
            ("Startup disk /Volumes/Data is full", "Startup disk ‹path› is full"),
            ("Log at ~/Library/Logs/x.log", "Log at ‹path›"),
            ("Router 192.168.1.1 is slow", "Router ‹address› is slow"),
            ("Router fe80::1%en0 is slow", "Router ‹address› is slow"),
            ("Device 3c:22:fb:01:02:03 joined", "Device ‹address› joined"),
            ("Connected to api.example.com", "Connected to ‹host›"),
            ("See https://example.com/a?b=c", "See ‹link›"),
            ("Mail alice@example.com", "Mail ‹email›"),
            ("Alice Smith's script /Users/alice/bin/run is busy", "‹user›'s script ‹path› is busy"),
            ("alice's job", "‹user›'s job"),
        ]
        for (input, expected) in cases { XCTAssertEqual(r.scrub(input), expected, input) }
        // Ordinary wording survives.
        for keep in ["Heavy disk activity (120 MB/s)", "CPU is 95% busy", "Swap grew by 1.2 GB in 10 minutes", "Paused at 12:30:05",
                     "Already 3/4 full", "Xcode is not responding"] {
            XCTAssertEqual(r.scrub(keep), keep)
        }
    }

    func testStatusWithholdsPrivateKindsAndIDs() throws {
        let now = Date()
        let findings = [
            Finding(id: "cpu:com.example.app", severity: .caution, icon: "cpu", title: "Example is using 150% CPU", detail: nil, since: now, destination: nil, pids: [42]),
            Finding(id: "privacy:dest:Safari:1", severity: .caution, icon: "point.3.connected.trianglepath.dotted", title: "Safari connected to example.com",
                    detail: nil, since: now, destination: nil),
            Finding(id: "privacy:first:abc", severity: .info, icon: "web.camera", title: "Zoom used the camera", detail: nil, since: now, destination: nil),
        ]
        let incidents = [Incident(id: UUID(), key: "privacy:unattended:x", severity: .caution, icon: "mic", title: "Mic on", detail: nil, destination: nil, start: now, end: nil),
                         Incident(id: UUID(), key: "hang:12-34", severity: .warning, icon: "hourglass", title: "Mail is not responding", detail: nil, destination: nil, start: now, end: now)]
        let awake = Finding(id: "awake:x", severity: .info, icon: "moon.zzz", title: "Foo prevents sleep", detail: "Reason given: “Downloading tax-return”",
                            since: now, destination: nil)
        XCTAssertNil(FleetRedaction(names: []).finding(awake)?.detail, "an app's free-text reason isn't shared")
        let s = FleetStatus.build(identity: identity("h"), snapshot: nil, findings: findings, incidents: incidents, history: [], uptime: nil, redaction: .init(names: []))
        XCTAssertEqual(s.findings.map(\.kind), ["cpu"])
        XCTAssertEqual(s.incidents.map(\.kind), ["hang"])
        XCTAssertEqual(s.vitalsReason, "No sample yet")
        let json = String(decoding: try JSONEncoder.fleet.encode(s), as: UTF8.self)
        for leak in ["com.example.app", "42", "Safari", "Zoom", "12-34", "pids"] { XCTAssertFalse(json.contains(leak), leak) }
    }

    func testVitalsNeverInventZeros() {
        var snap = MetricsExportTests().snapshot()
        snap.power.hottest = .unavailable("no sensors")
        snap.power.battery = nil
        snap.memory.measured = false
        let v = FleetStatus.vitals(snap, uptime: nil)
        XCTAssertNil(v.hottest.value); XCTAssertEqual(v.hottest.reason, "no sensors")
        XCTAssertNil(v.memoryPressure.value); XCTAssertNotNil(v.memoryPressure.reason)
        XCTAssertNil(v.memoryLevel)
        XCTAssertNil(v.battery); XCTAssertEqual(v.batteryReason, "No battery")
        XCTAssertNil(v.uptime.value)
        XCTAssertEqual(v.cpu.value, 42.5)
    }

    func testStoreFileIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = FleetStore(dir: dir)
        a.addHost(FleetPeer(id: "h", name: "Studio", secret: FleetCrypto.random(32), pairedAt: Date()))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("fleet.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let b = FleetStore(dir: dir)
        XCTAssertEqual(b.instanceID, a.instanceID)
        XCTAssertEqual(b.host("h")?.secret, a.host("h")?.secret)
    }

    func testFleetWatchRaisesOnlyForWarnings() {
        let ident = identity("h")
        let warn = FleetFinding(kind: "mem-pressure", severity: 3, icon: "memorychip", title: "Memory pressure is critical", detail: nil, since: Date())
        let calm = FleetFinding(kind: "swap-used", severity: 1, icon: "x", title: "Swap in use", detail: nil, since: Date())
        let a = FleetStatus(identity: ident, vitals: nil, findings: [calm, warn], incidents: [], history: [])
        let b = FleetStatus(identity: ident, vitals: nil, findings: [calm], incidents: [], history: [])
        let f = FleetWatch.findings(for: [("Studio", "h", a), ("Mini", "m", b)])
        XCTAssertEqual(f.map(\.title), ["Studio: Memory pressure is critical"])
        XCTAssertEqual(f.first?.destination, "Fleet")
    }
}
