import XCTest
@testable import FlightdeckCore

final class NetworkQualityTests: XCTestCase {
    func testPingParse() {
        let ok = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes

        --- 1.1.1.1 ping statistics ---
        5 packets transmitted, 4 packets received, 20.0% packet loss
        round-trip min/avg/max/stddev = 11.201/14.552/20.003/3.101 ms
        """
        let r = NetworkProbe.parse(ok, host: "1.1.1.1", role: "Internet")!
        XCTAssertEqual(r.loss, 20); XCTAssertEqual(r.avgMs!, 14.552, accuracy: 0.001); XCTAssertEqual(r.jitterMs!, 3.101, accuracy: 0.001)
        let dead = "5 packets transmitted, 0 packets received, 100.0% packet loss\n"
        let d = NetworkProbe.parse(dead, host: "10.0.0.1", role: "Router")!
        XCTAssertEqual(d.loss, 100); XCTAssertNil(d.avgMs, "no latency is invented when everything was lost")
    }

    func testWiFiAndRouteRead() {
        let t0 = Date()
        let w = WiFiInfo.current()
        print("WIFI", w as Any, "in", Date().timeIntervalSince(t0), "s")
        print("ROUTE", NetworkConfig.defaultRoute() as Any, "DNS", NetworkConfig.dnsServers())
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
    }

    func testOldSnapshotsDecodeWithoutNewFields() throws {
        let s = BlackBoxTests.base
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        json["wifi"] = nil; json["latency"] = nil
        let back = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.wifi)
    }
}
