// Tests for the Network map: arp/ndp/traceroute parsing (captured on macOS 27, addresses and the low MAC octets
// changed), the OUI table and the randomized-MAC rule, device-type guessing, merging, topology, and the active-scan
// target list and ICMP checksum. One live test reads this Mac's interfaces and neighbour caches (no packets sent).
import XCTest
@testable import FlightDeckCore

final class NetworkMapTests: XCTestCase {
    static let arp = """
    ? (192.168.1.1) at 74:ac:b9:12:34:56 on en0 ifscope [ethernet]
    ? (192.168.1.20) at b8:27:eb:f7:7:69 on en0 ifscope [ethernet]
    ? (192.168.1.24) at 7e:8d:9d:1e:a0:be on en0 ifscope permanent [ethernet]
    ? (192.168.1.31) at (incomplete) on en0 ifscope [ethernet]
    ? (192.168.1.41) at 0:11:d9:90:50:36 on en0 ifscope [ethernet]
    ? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
    ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
    ? (169.254.12.3) at 2:3:4:5:6:7 on awdl0 [ethernet]
    """
    static let ndp = """
    Neighbor                                Linklayer Address  Netif Expire    St Flgs Prbs
    fe80::1%lo0                             (incomplete)         lo0 permanent R
    fe80::4c0:8029:a62a:cbc%en0             7e:8d:9d:1e:a0:be    en0 permanent R
    fe80::76ac:b9ff:fe12:3456%en0           74:ac:b9:12:34:56    en0 4s        D  R
    fd00::1c2:3b4%en0                       b8:27:eb:f7:7:69     en0 23h59m58s S
    fe80::b017:75ff:fecd:a02%awdl0          b2:17:75:cd:a:2    awdl0 permanent R
    """

    func testMACNormalizeAndRandomizedRule() {
        XCTAssertEqual(MAC.normalize("b8:27:eb:f7:7:69"), "b8:27:eb:f7:07:69")
        XCTAssertEqual(MAC.normalize("0:11:D9:90:50:36"), "00:11:d9:90:50:36")
        XCTAssertNil(MAC.normalize("(incomplete)"))
        XCTAssertNil(MAC.normalize("00:11:22:33:44"))
        // Second hex digit 2, 6, A or E → locally administered.
        for m in ["02:00:00:00:00:01", "16:00:00:00:00:00", "aa:bb:cc:00:00:00", "7e:8d:9d:1e:a0:be", "fe:00:00:00:00:00"] {
            XCTAssertTrue(MAC.isLocallyAdministered(m), m)
        }
        for m in ["00:11:d9:90:50:36", "b8:27:eb:00:00:00", "3c:22:fb:00:00:00", "f0:18:98:00:00:00"] { XCTAssertFalse(MAC.isLocallyAdministered(m), m) }
        XCTAssertTrue(MAC.isGroup("01:00:5e:00:00:fb")); XCTAssertFalse(MAC.isGroup("00:11:d9:90:50:36"))
    }

    func testOUILookup() {
        XCTAssertGreaterThan(OUI.count, 5000)
        XCTAssertEqual(OUI.lookup("b8:27:eb:f7:7:69"), .known("Raspberry Pi"))
        XCTAssertEqual(OUI.lookup("00:11:d9:90:50:36"), .unlisted)   // TiVo: real, but not in the curated table
        XCTAssertEqual(OUI.lookup("00:03:93:00:00:01"), .known("Apple"))
        XCTAssertEqual(OUI.lookup("00:0e:58:00:00:01"), .known("Sonos"))
        XCTAssertEqual(OUI.lookup("7e:8d:9d:1e:a0:be"), .privateAddress)
        // A randomized MAC is never looked up, even though "02:…" could collide with a registry entry's digits.
        XCTAssertEqual(OUI.lookup("da:a1:19:00:00:00"), .privateAddress)
        XCTAssertEqual(OUI.lookup(nil), .noMAC)
        XCTAssertEqual(OUI.lookup("garbage"), .noMAC)
    }

    func testParseARP() {
        let a = Neighbors.parseARP(Self.arp)
        XCTAssertEqual(a.map(\.ip), ["192.168.1.1", "192.168.1.20", "192.168.1.24", "192.168.1.41"])
        XCTAssertEqual(a[1].mac, "b8:27:eb:f7:07:69")
        XCTAssertTrue(a[2].permanent); XCTAssertFalse(a[0].permanent)
        XCTAssertEqual(a[0].interface, "en0")
    }

    func testParseNDP() {
        let n = Neighbors.parseNDP(Self.ndp)
        XCTAssertEqual(n.count, 3)   // lo0 incomplete and awdl0 dropped
        XCTAssertEqual(n[0].ip, "fe80::4c0:8029:a62a:cbc"); XCTAssertTrue(n[0].permanent); XCTAssertFalse(n[0].isRouter)
        XCTAssertTrue(n[1].isRouter); XCTAssertEqual(n[1].mac, "74:ac:b9:12:34:56")
        XCTAssertFalse(n[2].isRouter); XCTAssertTrue(n[2].isIPv6)
    }

    func testTraceroute() {
        let out = """
        traceroute to 1.1.1.1 (1.1.1.1), 16 hops max, 40 byte packets
         1  192.168.1.1  3.112 ms
         2  *
         3  100.64.0.1  9.870 ms
         4  1.1.1.1  12.004 ms
        """
        let h = Traceroute.parse(out)
        XCTAssertEqual(h.count, 4)
        XCTAssertEqual(h[0], TraceHop(number: 1, ip: "192.168.1.1", ms: 3.112))
        XCTAssertNil(h[1].ip); XCTAssertNil(h[1].ms)
        XCTAssertEqual(h[3].ip, "1.1.1.1")
    }

    func testSubnetMath() {
        let n = IPv4Net(address: "192.168.1.24", prefix: 24)
        XCTAssertEqual(n.cidr, "192.168.1.0/24"); XCTAssertEqual(n.broadcast, "192.168.1.255")
        XCTAssertTrue(n.contains("192.168.1.200")); XCTAssertFalse(n.contains("192.168.2.1"))
        XCTAssertEqual(IPv4.prefixLength(ofMask: IPv4.parse("255.255.252.0")!), 22)
        let t = ActiveScan.targets(for: n)
        XCTAssertEqual(t.count, 253)   // .1 … .254 minus this Mac
        XCTAssertFalse(t.contains("192.168.1.24")); XCTAssertEqual(t.first, "192.168.1.1"); XCTAssertEqual(t.last, "192.168.1.254")
        // A /16 is limited to the /24 around this Mac; a /28 is scanned whole.
        XCTAssertEqual(ActiveScan.targets(for: IPv4Net(address: "10.0.5.9", prefix: 16)).first, "10.0.5.1")
        XCTAssertEqual(ActiveScan.targets(for: IPv4Net(address: "10.0.0.2", prefix: 28)).count, 13)
        XCTAssertTrue(ActiveScan.targets(for: IPv4Net(address: "10.0.0.2", prefix: 32)).isEmpty)
    }

    func testICMPChecksum() {
        let p = ActiveScan.echoRequest(id: 0x1234, seq: 7)
        XCTAssertEqual(ActiveScan.checksum(p), 0)   // a packet with a correct checksum sums to zero
        XCTAssertEqual(p[0], 8)
    }

    // MARK: identification

    func dev(_ f: (inout NetDevice) -> Void) -> NetDevice { var d = NetDevice(id: "x"); f(&d); return d }

    func testClassifier() {
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.isGateway = true }).kind, .router)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.model = "iPhone15,2" }).kind, .phone)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.model = "AudioAccessory5,1" }).kind, .speaker)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.model = "AppleTV14,1" }).kind, .tv)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.model = "MacBookPro18,3" }).kind, .computer)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.services = ["_ipp._tcp", "_http._tcp"] }).kind, .printer)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.services = ["_hap._tcp"] }).kind, .smartHome)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.services = ["_raop._tcp"] }).kind, .speaker)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.hostname = "Johns-iPhone" }).kind, .phone)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.hostname = "DESKTOP-4F2KQ" }).kind, .computer)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.hostname = "jonas-pc" }).kind, .unknown)   // "nas" only as a word
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.hostname = "living-room-tv" }).kind, .tv)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.vendor = .known("Sonos") }).kind, .speaker)
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.vendor = .known("Brother") }).kind, .printer)
        let apple = DeviceClassifier.guess(dev { $0.vendor = .known("Apple") })
        XCTAssertEqual(apple.kind, .unknown); XCTAssertTrue(apple.reason.contains("Apple"))
        XCTAssertTrue(DeviceClassifier.guess(dev { $0.vendor = .privateAddress }).reason.contains("randomized"))
        // The device's own model beats a misleading service.
        XCTAssertEqual(DeviceClassifier.guess(dev { $0.model = "MacBookAir10,1"; $0.services = ["_airplay._tcp"] }).kind, .computer)
    }

    static let wifi = NetInterface(name: "en0", displayName: "Wi-Fi", kind: .wifi, mac: "7e:8d:9d:1e:a0:be",
                                   ipv4: [IPv4Net(address: "192.168.1.24", prefix: 24)], ipv6: ["fe80::4c0:8029:a62a:cbc"])
    static let vpn = NetInterface(name: "utun4", displayName: "VPN tunnel", kind: .vpn, ipv4: [IPv4Net(address: "10.8.0.2", prefix: 24)])
    static let idleTunnel = NetInterface(name: "utun0", displayName: "VPN tunnel", kind: .vpn, ipv6: ["fe80::1234"])

    func testMerge() throws {
        let nb = Neighbors.parseARP(Self.arp) + Neighbors.parseNDP(Self.ndp)
        let services = [
            BonjourService(name: "Kitchen Pi", type: "_ssh._tcp", interface: "en0", host: "kitchenpi.local.", addresses: ["192.168.1.20", "fd00::1c2:3b4"]),
            BonjourService(name: "Kitchen Pi", type: "_device-info._tcp", interface: "en0", addresses: ["192.168.1.20"], txt: ["model": "Raspberry Pi 4"]),
            BonjourService(name: "Office Printer", type: "_ipp._tcp", interface: "en0", addresses: ["192.168.1.50"], txt: ["ty": "Brother HL-L2350DW"]),
            BonjourService(name: "Unresolved", type: "_airplay._tcp"),
        ]
        let earlier = Date(timeIntervalSince1970: 1000), now = Date(timeIntervalSince1970: 2000)
        let ds = NetworkInventory.merge(interfaces: [Self.wifi], neighbors: nb, services: services,
                                        reverseDNS: ["192.168.1.1": "router.lan", "192.168.1.41": "dvr.lan"],
                                        route: DefaultRoute(gateway: "192.168.1.1", interface: "en0"),
                                        seen: ["mac:b8:27:eb:f7:07:69": (earlier, earlier)], now: now)
        XCTAssertEqual(ds.first?.isThisMac, true); XCTAssertEqual(ds.first?.ipv4, ["192.168.1.24"])
        let gw = try XCTUnwrap(ds.first { $0.isGateway })
        XCTAssertEqual(gw.mac, "74:ac:b9:12:34:56"); XCTAssertTrue(gw.isIPv6Router); XCTAssertEqual(gw.hostname, "router.lan")
        XCTAssertEqual(gw.ipv6, ["fe80::76ac:b9ff:fe12:3456"]); XCTAssertEqual(gw.kind, .router)
        let pi = try XCTUnwrap(ds.first { $0.mac == "b8:27:eb:f7:07:69" })
        XCTAssertEqual(pi.displayName, "Kitchen Pi"); XCTAssertEqual(pi.bonjourHost, "kitchenpi")
        XCTAssertEqual(pi.model, "Raspberry Pi 4"); XCTAssertEqual(pi.vendor, .known("Raspberry Pi"))
        XCTAssertEqual(pi.services, ["_device-info._tcp", "_ssh._tcp"]); XCTAssertEqual(pi.ipv6, ["fd00::1c2:3b4"])
        XCTAssertEqual(pi.firstSeen, earlier); XCTAssertEqual(pi.lastSeen, now)
        XCTAssertEqual(pi.sources, ["ARP", "NDP", "Bonjour"])
        // A service resolved to an address not in any neighbour cache becomes an IP-keyed device without a MAC.
        let printer = try XCTUnwrap(ds.first { $0.id == "ip:192.168.1.50" })
        XCTAssertEqual(printer.kind, .printer); XCTAssertEqual(printer.vendor, .noMAC); XCTAssertEqual(printer.model, "Brother HL-L2350DW")
        XCTAssertFalse(ds.contains { $0.bonjourNames.contains("Unresolved") })
        // The permanent (own) entries didn't create a second "this Mac".
        XCTAssertFalse(ds.contains { !$0.isThisMac && $0.mac == "7e:8d:9d:1e:a0:be" })
        XCTAssertEqual(ds.count, 5)   // this Mac, gateway, Pi, .41, printer
    }

    func testGatewayFromRouteOnly() {
        let ds = NetworkInventory.merge(interfaces: [Self.wifi], neighbors: [], services: [], reverseDNS: [:],
                                        route: DefaultRoute(gateway: "192.168.1.1", interface: "en0"))
        let gw = ds.first { $0.isGateway }
        XCTAssertEqual(gw?.id, "ip:192.168.1.1"); XCTAssertEqual(gw?.vendor, .noMAC); XCTAssertEqual(gw?.sources, ["route"])
    }

    func testTopology() {
        let nb = Neighbors.parseARP(Self.arp)
        let ifs = [Self.wifi, Self.vpn, Self.idleTunnel]
        let route = DefaultRoute(gateway: "192.168.1.1", interface: "en0")
        let ds = NetworkInventory.merge(interfaces: ifs, neighbors: nb, services: [], reverseDNS: [:], route: route)
        let ap = AccessPoint(ssid: nil, bssid: nil, channel: "36 · 5 GHz", rssi: -50)
        let hops = [TraceHop(number: 1, ip: "192.168.1.1", ms: 2), TraceHop(number: 2, ip: "100.64.0.1", ms: 9)]
        let t = NetTopology.build(interfaces: ifs, devices: ds, route: route, wifi: ap, hops: hops)
        XCTAssertEqual(t.branches.map(\.interface.name), ["en0", "utun4"])   // idle utun0 has no branch
        let p = t.branches[0]
        XCTAssertTrue(p.carriesDefaultRoute); XCTAssertEqual(p.subnets, ["192.168.1.0/24"]); XCTAssertEqual(p.accessPoint, ap)
        XCTAssertEqual(p.gateway, "mac:74:ac:b9:12:34:56")
        XCTAssertEqual(p.devices.count, 2)   // the Pi and .41: not this Mac, not the gateway
        XCTAssertFalse(t.branches[1].carriesDefaultRoute); XCTAssertNil(t.branches[1].accessPoint)
        XCTAssertEqual(t.hops.map(\.number), [2])   // the gateway hop is the router node itself
        XCTAssertFalse(t.internetViaVPN)
        // Full-tunnel VPN: the default route leaves through utun4, which becomes the primary branch.
        let vt = NetTopology.build(interfaces: ifs, devices: ds, route: DefaultRoute(gateway: "10.8.0.1", interface: "utun4"), wifi: ap)
        XCTAssertEqual(vt.primary?.interface.name, "utun4"); XCTAssertTrue(vt.internetViaVPN)
    }

    // MARK: live (reads only; sends nothing)

    func testLiveInterfacesAndNeighbours() throws {
        let ifs = NetworkDiscovery.interfaces()
        guard ifs.contains(where: \.isActive) else { throw XCTSkip("no active network interface") }
        for i in ifs { XCTAssertFalse(i.name.hasPrefix("lo")); if let m = i.mac { XCTAssertNotNil(MAC.normalize(m)) } }
        for n in NetworkDiscovery.neighbors() { XCTAssertNotNil(MAC.normalize(n.mac)); XCTAssertFalse(n.ip.isEmpty) }
    }
}
