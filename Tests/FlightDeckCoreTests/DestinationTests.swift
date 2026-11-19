// Destinations: flow parsing, address classification, registrable domains, accumulation from synthetic nettop
// output (including counter resets and the per-app cap), naming, new-destination detection, findings and retention.
import XCTest
@testable import FlightDeckCore

final class DestinationAddressTests: XCTestCase {
    func testScopes() {
        let cases: [(String, AddressScope)] = [
            ("127.0.0.1", .loopback), ("10.1.2.3", .privateLAN), ("172.16.0.1", .privateLAN), ("172.31.255.1", .privateLAN),
            ("172.32.0.1", .publicInternet), ("192.168.1.20", .privateLAN), ("100.64.0.1", .sharedCGNAT), ("100.127.255.254", .sharedCGNAT),
            ("100.128.0.1", .publicInternet), ("169.254.10.1", .linkLocal), ("224.0.0.251", .multicast), ("255.255.255.255", .broadcast),
            ("0.0.0.0", .unspecified), ("17.57.144.90", .publicInternet),
            ("::1", .loopback), ("::", .unspecified), ("fe80::1%en0", .linkLocal), ("febf::1", .linkLocal), ("fd12:3456::1", .uniqueLocal),
            ("fc00::1", .uniqueLocal), ("ff02::fb", .multicast), ("2001:db8::1", .publicInternet), ("::ffff:192.168.0.4", .privateLAN),
        ]
        for (ip, s) in cases { XCTAssertEqual(AddressScope.of(ip), s, ip) }
        XCTAssertNil(AddressScope.of("example.com"))
        XCTAssertTrue(AddressScope.sharedCGNAT.isLocal)
        XCTAssertFalse(AddressScope.publicInternet.isLocal)
        XCTAssertFalse(AddressScope.linkLocal.lookUp)
    }

    func testFlowParsing() {
        let v4 = FlowEndpoint.parse("tcp4 192.168.1.124:50725<->17.57.144.90:5223")
        XCTAssertEqual(v4, FlowEndpoint(proto: "tcp", ip: "17.57.144.90", remotePort: 5223, localPort: 50725))
        let v6 = FlowEndpoint.parse("tcp6 fe80::1%en0.5353<->2001:db8::5.443")
        XCTAssertEqual(v6?.ip, "2001:db8::5"); XCTAssertEqual(v6?.remotePort, 443); XCTAssertEqual(v6?.localPort, 5353)
        XCTAssertEqual(FlowEndpoint.parse("quic4 10.0.0.2:64375<->17.248.193.73:443")?.proto, "quic")
        XCTAssertNil(FlowEndpoint.parse("udp4 *:5353<->*:*"))
        XCTAssertNil(FlowEndpoint.parse("tcp6 *.22<->*.*"))
        // An SSH session into this Mac: the service port is the local one.
        let inbound = FlowEndpoint.parse("tcp4 192.168.1.5:22<->192.168.1.9:61000")
        XCTAssertEqual(inbound?.servicePort?.port, 22); XCTAssertEqual(inbound?.servicePort?.inbound, true)
        XCTAssertEqual(v4?.servicePort?.inbound, false)
        XCTAssertEqual(ServiceNames.label(port: 443, proto: "udp"), "QUIC (HTTP/3) 443")
        XCTAssertEqual(ServiceNames.label(port: 53, proto: "udp"), "DNS 53")
        XCTAssertEqual(ServiceNames.label(port: 8123, proto: "tcp"), "port 8123")
    }

    func testRegistrableDomain() {
        XCTAssertEqual(DomainName.registrable("api.notion.com"), "notion.com")
        XCTAssertEqual(DomainName.registrable("API.Notion.COM."), "notion.com")
        XCTAssertEqual(DomainName.registrable("notion.com"), "notion.com")
        XCTAssertEqual(DomainName.registrable("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(DomainName.registrable("a.b.example.com.au"), "example.com.au")
        XCTAssertEqual(DomainName.registrable("www.city.lg.jp"), "city.lg.jp")
        XCTAssertEqual(DomainName.registrable("ec2-3-4-5-6.compute-1.amazonaws.com"), "amazonaws.com")
        XCTAssertEqual(DomainName.registrable("router"), "router")
        XCTAssertNil(DomainName.registrable("17.57.144.90"))
        XCTAssertNil(DomainName.registrable(""))
        XCTAssertEqual(DomainName.provider("server-1-2-3-4.fra56.r.cloudfront.net"), "Amazon CloudFront (CDN)")
        XCTAssertNil(DomainName.provider("slack.com"))
        // LAN names group by the full name, internet names by domain, unnamed by IP.
        XCTAssertEqual(DestinationRow.key(host: "printer.home.arpa", ip: "192.168.1.9", scope: .privateLAN), "printer.home.arpa")
        XCTAssertEqual(DestinationRow.key(host: "edge-1.slack.com", ip: "203.0.113.5", scope: .publicInternet), "slack.com")
        XCTAssertEqual(DestinationRow.key(host: nil, ip: "203.0.113.5", scope: .publicInternet), "203.0.113.5")
    }

    func testPTRNames() {
        XCTAssertEqual(HostNamer.ptrName("17.57.144.90"), "90.144.57.17.in-addr.arpa.")
        let v6 = HostNamer.ptrName("2001:db8::1")
        XCTAssertEqual(v6, "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa.")
        let wire: [UInt8] = [3, 0x77, 0x77, 0x77, 7] + Array("example".utf8) + [3] + Array("com".utf8) + [0]
        XCTAssertEqual(wire.withUnsafeBytes { HostNamer.decodeName($0) }, "www.example.com")
        XCTAssertNil([UInt8]([5, 0x61]).withUnsafeBytes { HostNamer.decodeName($0) })
    }

    /// Real reverse DNS (needs network and a resolver that answers PTR queries): skipped on CI and offline.
    func testLiveReverseDNS() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("no live DNS on CI") }
        let namer = HostNamer()
        let exp = expectation(description: "ptr")
        final class Box: @unchecked Sendable { var name: String?? }
        let box = Box()
        namer.onName = { _, n in box.name = .some(n); exp.fulfill() }
        namer.request("1.1.1.1")
        wait(for: [exp], timeout: 8)
        guard case .some(let n) = box.name, let n else { throw XCTSkip("no PTR answer (offline or filtered)") }
        XCTAssertEqual(n, "one.one.one.one")
    }
}
