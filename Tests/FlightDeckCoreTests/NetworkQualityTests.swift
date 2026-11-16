import XCTest
@testable import FlightDeckCore

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

final class InterfaceCounterTests: XCTestCase {
    /// Byte counters must be the full 64-bit values (NET_RT_IFLIST2 alone wraps at 4 GB).
    func testCountersMatchNetstat() throws {
        let n = NetworkSampler().sample()
        guard let out = Shell.run("/usr/sbin/netstat", ["-ib"]) else { throw XCTSkip("no netstat") }
        var checked = 0
        for line in out.split(separator: "\n") where line.contains("<Link#") {
            let f = line.split(separator: " ")
            let name = String(f[0]).replacingOccurrences(of: "*", with: "")
            let nums = f.compactMap { UInt64($0) }   // ... Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            guard nums.count >= 7, let mine = n.interfaces.first(where: { $0.name == name }) else { continue }
            let nIn = Double(nums[nums.count - 5]), nOut = Double(nums[nums.count - 2])
            XCTAssertEqual(Double(mine.totalIn), nIn, accuracy: max(nIn * 0.01, 50e6), "\(name) in")
            XCTAssertEqual(Double(mine.totalOut), nOut, accuracy: max(nOut * 0.01, 50e6), "\(name) out")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
