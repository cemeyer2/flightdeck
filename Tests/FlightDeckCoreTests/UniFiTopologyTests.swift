// Topology from uplink fields (uplink_mac / uplink_remote_port / last_uplink, ap_mac, sw_mac / sw_port), the
// attachment lookup the network map uses, merging integration and classic records, and detection helpers.
import XCTest
@testable import FlightDeckCore

final class UniFiTopologyTests: XCTestCase {
    typealias F = UniFiFixtures

    func classicSnapshot() throws -> UniFiSnapshot {
        var s = UniFiSnapshot(time: Date(), source: .classic)
        s.devices = try XCTUnwrap(UniFiClassic.devices(Data(F.statDevice.utf8)))
        s.clients = try XCTUnwrap(UniFiClassic.clients(Data(F.statSta.utf8)))
        return s
    }

    func testTreeFromUplinks() throws {
        let t = try classicSnapshot().topology
        XCTAssertEqual(t.roots.map(\.device.mac), [F.gw], "the gateway is the only root")
        let sw = try XCTUnwrap(t.roots[0].children.first)
        XCTAssertEqual(sw.device.mac, F.sw); XCTAssertEqual(sw.parentPort, 10); XCTAssertEqual(sw.linkMbps, 10000)
        XCTAssertEqual(sw.children.map(\.device.mac), [F.ap1, F.ap2], "APs ordered by the switch port they're on")
        XCTAssertEqual(sw.children.map(\.parentPort), [1, 2])
        XCTAssertEqual(sw.portClients[5]?.map(\.hostname), ["nas"], "wired clients hang under their switch port")
        XCTAssertTrue(sw.clients.isEmpty)
        let ap = sw.children[0]
        XCTAssertEqual(Set(ap.clients.map(\.mac)), ["aa:bb:cc:00:00:01", "aa:bb:cc:00:00:04"])
        XCTAssertEqual(t.unattached.map(\.mac), ["aa:bb:cc:00:00:05"], "a client without AP or switch isn't guessed")
        XCTAssertEqual(t.flattened.map(\.depth), [0, 1, 2, 2])
    }

    func testAttachmentLookup() throws {
        let s = try classicSnapshot()
        let phone = try XCTUnwrap(s.attachment(ofMAC: "AA-BB-CC-00-00-01"))
        XCTAssertEqual(phone.deviceMAC, F.ap1); XCTAssertEqual(phone.link, .wireless(ssid: "Home"))
        let nas = try XCTUnwrap(s.attachment(ofMAC: "aa:bb:cc:00:00:02"))
        XCTAssertEqual(nas.deviceName, "Office Switch"); XCTAssertEqual(nas.link, .wired(port: 5))
        let ap = try XCTUnwrap(s.attachment(ofMAC: F.ap1))
        XCTAssertEqual(ap.deviceMAC, F.sw); XCTAssertEqual(ap.link, .wired(port: 1)); XCTAssertEqual(ap.speedMbps, 1000)
        XCTAssertNil(s.attachment(ofMAC: "aa:bb:cc:00:00:05")); XCTAssertNil(s.attachment(ofMAC: F.gw))
        XCTAssertEqual(s.clients(on: F.sw, port: 5).count, 1)
    }

    func testCyclesAndMissingParentsDontLoseDevices() {
        var s = UniFiSnapshot(time: Date(), source: .classic)
        var a = UniFiDevice(mac: "00:00:00:00:00:0a", kind: .switch); a.uplink = UniFiUplink(parentMAC: "00:00:00:00:00:0b")
        var b = UniFiDevice(mac: "00:00:00:00:00:0b", kind: .switch); b.uplink = UniFiUplink(parentMAC: "00:00:00:00:00:0a")
        var c = UniFiDevice(mac: "00:00:00:00:00:0c", kind: .accessPoint); c.uplink = UniFiUplink(parentMAC: "00:00:00:00:00:ff")
        s.devices = [a, b, c]
        let flat = s.topology.flattened.map(\.node.device.mac)
        XCTAssertEqual(Set(flat), Set([a.mac, b.mac, c.mac])); XCTAssertEqual(flat.count, 3)
    }

    func testMergePrefersIntegrationAndFillsFromClassic() throws {
        var ints = try XCTUnwrap(UniFiIntegration.devices(Data(F.intDevices.utf8)))
        var ic = try XCTUnwrap(UniFiIntegration.clients(Data(F.intClients.utf8)))
        UniFiIntegration.resolve(devices: &ints, uplinkIDs: ["d-sw": "d-gw"], clients: &ic)
        let cl = try classicSnapshot()
        let devs = UniFiMerge.devices(ints, cl.devices)
        XCTAssertEqual(devs.count, 4, "the classic-only AP is added")
        let gw = try XCTUnwrap(devs.first { $0.mac == F.gw })
        XCTAssertEqual(gw.ip, "192.168.1.1", "integration value wins"); XCTAssertEqual(gw.firmware, "4.0.6.6754", "classic fills gaps")
        XCTAssertEqual(devs.first { $0.mac == F.sw }?.uplink?.parentPort, 10)
        let clients = UniFiMerge.clients(ic, cl.clients)
        let nas = try XCTUnwrap(clients.first { $0.mac == "aa:bb:cc:00:00:02" })
        XCTAssertEqual(nas.name, "NAS"); XCTAssertEqual(nas.switchPort, 5); XCTAssertEqual(nas.vendor, "Synology")
    }

    func testDetectionHelpers() {
        let arp = """
        ? (192.168.1.1) at 74:ac:b9:5e:21:b3 on en0 ifscope [ethernet]
        ? (192.168.1.9) at (incomplete) on en0 ifscope [ethernet]
        ? (10.0.0.1) at 0:1b:2c:3:4:5 on en1 ifscope [ethernet]
        """
        XCTAssertEqual(UniFiDetection.mac(forIP: "192.168.1.1", arpOutput: arp), "74:ac:b9:5e:21:b3")
        XCTAssertNil(UniFiDetection.mac(forIP: "192.168.1.9", arpOutput: arp))
        XCTAssertNil(UniFiDetection.mac(forIP: "192.168.1.19", arpOutput: arp), "no prefix matches")
        XCTAssertEqual(UniFiDetection.mac(forIP: "10.0.0.1", arpOutput: arp), "00:1b:2c:03:04:05")
        XCTAssertTrue(UniFiDetection.isUbiquiti(mac: "74:AC:B9:5E:21:B3")); XCTAssertFalse(UniFiDetection.isUbiquiti(mac: "00:1b:2c:03:04:05"))
        XCTAssertTrue(UniFiDetection.looksLikeUniFiOS("<html><head><title>UniFi OS</title><script>window.UNIFI_OS_MANIFEST = {}</script>"))
        XCTAssertTrue(UniFiDetection.looksLikeUniFiOS(#"{"hardware":{"shortname":"UDMPRO"},"name":"UDMP"}"#))
        XCTAssertFalse(UniFiDetection.looksLikeUniFiOS("<title>Router login</title>"))
    }
}
