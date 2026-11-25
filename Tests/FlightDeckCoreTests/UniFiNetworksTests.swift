// UniFi networks as web dashboard allowlist suggestions: the classic networkconf list, decoded and normalized.
import XCTest
@testable import FlightDeckCore

final class UniFiNetworksTests: XCTestCase {
    func testClassicNetworkconf() throws {
        let json = #"""
        {"meta":{"rc":"ok"},"data":[
          {"_id":"a","name":"Default","purpose":"corporate","ip_subnet":"192.168.1.1/24"},
          {"_id":"b","name":"IoT","purpose":"corporate","ip_subnet":"192.168.10.1/24","vlan":10,"vlan_enabled":true},
          {"_id":"c","name":"Internet 1","purpose":"wan"}
        ]}
        """#
        let n = try XCTUnwrap(UniFiNetworks.classic(Data(json.utf8)))
        XCTAssertEqual(n, [UniFiNetwork(name: "Default", subnet: "192.168.1.0/24", vlan: nil),
                           UniFiNetwork(name: "IoT", subnet: "192.168.10.0/24", vlan: 10)])
        XCTAssertNil(UniFiNetworks.classic(Data("nope".utf8)))
    }

    /// One row with unexpected types must not hide the others.
    func testOddRowsDoNotHideTheList() throws {
        let json = #"""
        {"data":[
          {"name":"Guest","ip_subnet":"192.168.20.1/24","vlan":"20"},
          {"name":"Weird","ip_subnet":42,"vlan":true},
          {"name":7,"ip_subnet":"192.168.30.1/24","vlan":{"x":1}},
          "not an object",
          {"name":"IoT","ip_subnet":"192.168.10.1/24","vlan":10}
        ]}
        """#
        let n = try XCTUnwrap(UniFiNetworks.classic(Data(json.utf8)))
        XCTAssertEqual(n, [UniFiNetwork(name: "Guest", subnet: "192.168.20.0/24", vlan: 20),
                           UniFiNetwork(name: "Network", subnet: "192.168.30.0/24", vlan: nil),
                           UniFiNetwork(name: "IoT", subnet: "192.168.10.0/24", vlan: 10)])
    }

    func testSuggestions() {
        let s = WebSuggestions.unifi([UniFiNetwork(name: "IoT", subnet: "192.168.10.0/24", vlan: 10),
                                      UniFiNetwork(name: "Lab", subnet: "203.0.113.0/24", vlan: nil)], context: WebAccessTests.context())
        XCTAssertEqual(s.map(\.label), ["UniFi: IoT (VLAN 10): 192.168.10.0/24",
                                        "UniFi: Lab: 203.0.113.0/24 — Not a local address — ignored (turn on Advanced to allow)"])
        XCTAssertEqual(s.first?.entries, ["192.168.10.0/24"])
    }
}
