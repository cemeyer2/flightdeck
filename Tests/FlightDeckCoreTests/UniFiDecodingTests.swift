// UniFi decoding and topology: Integration API sites/devices/clients, classic stat/device, stat/sta and stat/health,
// lenient field types, merging the two APIs, and the device/client tree built from uplink fields.
import XCTest
@testable import FlightDeckCore

final class UniFiDecodingTests: XCTestCase {
    typealias F = UniFiFixtures
    func d(_ s: String) -> Data { Data(s.utf8) }

    func testNormalizesMACs() {
        XCTAssertEqual(UniFi.normalizeMAC("74ACB95E21A9"), "74:ac:b9:5e:21:a9")
        XCTAssertEqual(UniFi.normalizeMAC("74-AC-B9-5E-21-A9"), "74:ac:b9:5e:21:a9")
        XCTAssertEqual(UniFi.normalizeMAC("0:1a:2b:3:4:5"), "00:1a:2b:03:04:05", "arp prints octets without leading zeros")
    }

    func testIntegrationSites() throws {
        let s = try XCTUnwrap(UniFiIntegration.sites(d(F.intSites)))
        XCTAssertEqual(s, [UniFiSite(id: "88f7af54-98f8-306a-a1c7-c9349722b1f6", name: "default", description: "Default")])
    }

    func testIntegrationDevicesAndDetail() throws {
        let list = try XCTUnwrap(UniFiIntegration.devices(d(F.intDevices)))
        XCTAssertEqual(list.map(\.kind), [.gateway, .switch, .accessPoint])
        XCTAssertEqual(list[0].mac, F.gw, "MACs are normalized")
        XCTAssertEqual(list[2].online, false)
        XCTAssertNil(list[0].firmware, "the list endpoint has no firmware; it stays unknown")
        let (ap, uplink) = try XCTUnwrap(UniFiIntegration.deviceDetail(d(F.intDeviceDetailAP)))
        XCTAssertEqual(uplink, "d-sw")
        XCTAssertEqual(ap.firmware, "6.6.77"); XCTAssertEqual(ap.online, true); XCTAssertEqual(ap.kind, .accessPoint)
        XCTAssertEqual(ap.ports.first?.speedMbps, 1000); XCTAssertEqual(ap.ports.first?.poeStandard, "802.3at")
        XCTAssertEqual(ap.radios.map(\.band), ["2.4 GHz", "5 GHz"]); XCTAssertEqual(ap.radios[1].widthMHz, 80)
        XCTAssertNil(ap.radios[1].utilizationPercent, "the integration API doesn't report utilization")
        var dev = ap
        UniFiIntegration.applyStatistics(d(F.intStatsAP), to: &dev)
        XCTAssertEqual(dev.uptime, 86400); XCTAssertEqual(dev.cpuPercent, 12.5); XCTAssertEqual(dev.memoryPercent, 41)
        XCTAssertEqual(dev.txBps, 1_000_000, "bits per second become bytes per second")
    }

    func testIntegrationClientsResolveToDevices() throws {
        var devices = try XCTUnwrap(UniFiIntegration.devices(d(F.intDevices)))
        var clients = try XCTUnwrap(UniFiIntegration.clients(d(F.intClients)))
        XCTAssertEqual(clients.map(\.wired), [false, true, nil], "VPN clients are neither wired nor wireless")
        XCTAssertNotNil(clients[0].uptime, "connectedAt becomes an uptime")
        UniFiIntegration.resolve(devices: &devices, uplinkIDs: ["d-ap1": "d-sw", "d-sw": "d-gw"], clients: &clients)
        XCTAssertEqual(clients[0].apMAC, F.ap1)
        XCTAssertEqual(clients[1].switchMAC, F.sw); XCTAssertNil(clients[1].switchPort, "the integration API names no port")
        XCTAssertEqual(devices[2].uplink?.parentMAC, F.sw); XCTAssertEqual(devices[1].uplink?.parentMAC, F.gw)
        XCTAssertNil(devices[0].uplink)
    }

    func testClassicDevices() throws {
        let devs = try XCTUnwrap(UniFiClassic.devices(d(F.statDevice)))
        XCTAssertEqual(devs.count, 4)
        let gw = devs[0], sw = devs[1], ap = devs[2], ap2 = devs[3]
        XCTAssertEqual(gw.kind, .gateway); XCTAssertEqual(gw.model, "UDM Pro"); XCTAssertEqual(gw.cpuPercent, 9.8, "string numbers decode")
        XCTAssertEqual(gw.temperatures.map(\.name), ["CPU", "Local"]); XCTAssertEqual(gw.rxBps, 2_500_000)
        XCTAssertNil(gw.uplink?.parentMAC, "the gateway's uplink is the WAN: no parent")
        XCTAssertNil(gw.ports.first?.speedMbps, "a down port has no speed")
        XCTAssertEqual(sw.uptime, 600000); XCTAssertEqual(sw.temperatures, [UniFiTemperature(name: "General", celsius: 44)])
        XCTAssertEqual(sw.uplink, UniFiUplink(parentMAC: F.gw, parentPort: 10, localPort: 25, speedMbps: 10000, wireless: false))
        XCTAssertEqual(sw.ports[0].poeWatts, 7.42); XCTAssertEqual(sw.ports[0].poeStandard, "802.3at/802.3af/24V passive")
        XCTAssertEqual(sw.ports[1].poeStandard, "802.3bt/802.3at/802.3af/24V passive")
        XCTAssertEqual(sw.ports[2].poeEnabled, false); XCTAssertEqual(sw.ports[2].rxBytes, 123456789)
        XCTAssertNil(sw.ports[3].speedMbps)
        XCTAssertEqual(ap.radios.count, 2)
        XCTAssertEqual(ap.radios[0].band, "2.4 GHz"); XCTAssertEqual(ap.radios[0].channel, 6); XCTAssertEqual(ap.radios[0].utilizationPercent, 38)
        XCTAssertEqual(ap.radios[1].clientCount, 1); XCTAssertEqual(ap.radios[1].widthMHz, 80); XCTAssertEqual(ap.radios[1].standard, "802.11ax")
        XCTAssertEqual(ap2.online, false); XCTAssertEqual(ap2.state, "disconnected")
        XCTAssertEqual(ap2.uplink?.parentMAC, F.sw, "an offline device keeps its last_uplink"); XCTAssertEqual(ap2.uplink?.parentPort, 2)
        XCTAssertNil(ap2.ip); XCTAssertNil(ap2.firmware)
    }

    func testClassicClients() throws {
        let cs = try XCTUnwrap(UniFiClassic.clients(d(F.statSta)))
        let phone = cs[0], nas = cs[1], thermo = cs[2], mystery = cs[3]
        XCTAssertEqual(phone.mac, "aa:bb:cc:00:00:01"); XCTAssertEqual(phone.vendor, "Google"); XCTAssertEqual(phone.wired, false)
        XCTAssertEqual(phone.apMAC, F.ap1); XCTAssertEqual(phone.ssid, "Home"); XCTAssertEqual(phone.signalDbm, -58); XCTAssertEqual(phone.rssi, 38)
        XCTAssertEqual(phone.band, "5 GHz"); XCTAssertEqual(phone.wifiStandard, "802.11ax (Wi-Fi 6/6E)"); XCTAssertEqual(phone.linkSpeedMbps, 576)
        XCTAssertEqual(phone.downloadBytes, 5_000_000_000, "tx_bytes is what the AP sent: the client's download")
        XCTAssertEqual(phone.uploadBps, 40000); XCTAssertNil(phone.switchMAC)
        XCTAssertEqual(nas.switchMAC, F.sw); XCTAssertEqual(nas.switchPort, 5); XCTAssertNil(nas.apMAC)
        XCTAssertEqual(nas.downloadBytes, 9000, "wired clients use the wired- counters"); XCTAssertEqual(nas.uploadBps, 50)
        XCTAssertNil(thermo.linkSpeedMbps); XCTAssertNil(thermo.downloadBytes, "no counters reported: unknown, not 0")
        XCTAssertEqual(thermo.wifiStandard, "802.11n (Wi-Fi 4)")
        XCTAssertNil(mystery.wired); XCTAssertNil(mystery.parentMAC)
    }

    func testClassicHealth() throws {
        let h = try XCTUnwrap(UniFiClassic.health(d(F.statHealth)))
        XCTAssertEqual(h.wanIP, "203.0.113.7"); XCTAssertEqual(h.isp, "Example Fiber")
        XCTAssertEqual(h.wanRxBps, 2_500_000); XCTAssertEqual(h.latencyMs, 11, "www latency wins over the WAN monitor average")
        XCTAssertEqual(h.wanUptime, 1209500)
        XCTAssertNil(h.packetLossPercent, "availability is not packet loss; not reported means unknown")
        XCTAssertEqual(h.speedTest?.downloadMbps, 912.3); XCTAssertEqual(h.speedTest?.latencyMs, 8)
        XCTAssertEqual(h.speedTest?.time, Date(timeIntervalSince1970: 1709370000))
        XCTAssertEqual(h.subsystems["lan"], "warning")
    }

    func testClassicErrorEnvelope() {
        XCTAssertEqual(UniFiJSON.classicError(d(F.loginRequired)), "api.err.LoginRequired")
        XCTAssertNil(UniFiJSON.classicError(d(F.statHealth)))
        XCTAssertNil(UniFiClassic.devices(d("<html>login</html>")), "non-JSON is a failure, not an empty network")
    }
}
