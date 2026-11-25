// Web dashboard, part 1: addresses, prefixes and the allowed-addresses text from Settings.
import XCTest
@testable import FlightDeckCore

final class WebAllowlistTests: XCTestCase {
    func testParsesV4V6AndCIDR() {
        let l = WebAllowlist.parse("192.168.1.42, 192.168.1.0/24\nfd00::/8")
        XCTAssertEqual(l.entries.count, 3)
        XCTAssertTrue(l.invalid.isEmpty)
        XCTAssertEqual(l.entries[1].prefix.description, "192.168.1.0/24")
        XCTAssertTrue(l.entries[2].prefix.contains(WebIP("fd12::1")!))
        XCTAssertTrue(l.contains(WebIP("192.168.1.200")!))
        XCTAssertFalse(l.contains(WebIP("192.168.2.1")!))
    }

    func testCIDREdges() {
        XCTAssertTrue(WebPrefix("0.0.0.0/0")!.contains(WebIP("8.8.8.8")!))
        let host = WebPrefix("10.0.0.1/32")!
        XCTAssertTrue(host.contains(WebIP("10.0.0.1")!))
        XCTAssertFalse(host.contains(WebIP("10.0.0.2")!))
        let v6 = WebPrefix("::1/128")!
        XCTAssertTrue(v6.contains(WebIP("::1")!))
        XCTAssertFalse(v6.contains(WebIP("::2")!))
        XCTAssertFalse(WebPrefix("0.0.0.0/0")!.contains(WebIP("::1")!), "never across families")
        XCTAssertNil(WebPrefix("10.0.0.0/33"))
        XCTAssertNil(WebPrefix("::/129"))
        XCTAssertEqual(WebAllowlist.parse("10.0.0.0/33, ::/129").invalid.map(\.position), [1, 2])
        XCTAssertTrue(WebPrefix("10.0.0.0/8")!.contains(WebPrefix("10.1.0.0/16")!))
        XCTAssertFalse(WebPrefix("10.1.0.0/16")!.contains(WebPrefix("10.0.0.0/8")!))
    }

    func testHostBitsMasked() {
        let e = WebAllowlist.parse("192.168.1.7/24").entries[0]
        XCTAssertEqual(e.prefix.description, "192.168.1.0/24")
        XCTAssertTrue(e.normalizedChanged)
        XCTAssertFalse(WebAllowlist.parse("10.0.0.1").entries[0].normalizedChanged)
        XCTAssertEqual(WebPrefix(address: WebIP("10.1.2.3")!, length: 8).description, "10.0.0.0/8")
    }

    func testMappedIPv4Normalized() {
        XCTAssertEqual(WebIP("::ffff:192.168.1.5"), WebIP("192.168.1.5"))
        XCTAssertEqual(WebAllowlist.parse("::ffff:10.0.0.0/104").entries.first?.prefix.description, "10.0.0.0/8")
        XCTAssertFalse(WebIP("64:ff9b::a00:1")!.isV4, "only ::ffff:0:0/96 is IPv4")
        XCTAssertTrue(WebIP("127.0.0.1")!.isLoopback)
        XCTAssertTrue(WebIP("::1")!.isLoopback)
        XCTAssertFalse(WebIP("10.0.0.1")!.isLoopback)
        XCTAssertEqual(WebIP("fd7a:115c:a1e0:0:0:0:0:1")?.description, "fd7a:115c:a1e0::1")
    }

    func testZoneIDRejected() {
        let l = WebAllowlist.parse("fe80::1%en0")
        XCTAssertTrue(l.entries.isEmpty)
        XCTAssertEqual(l.invalid.map(\.position), [1])
        XCTAssertEqual(l.invalid.first?.text, "fe80::1%en0")
        XCTAssertNil(WebIP("fe80::1%en0"))
    }

    func testInvalidReportedWithPosition() {
        let l = WebAllowlist.parse("10.0.0.1, banana, 10.0.0.300")
        XCTAssertEqual(l.invalid.map(\.position), [2, 3])
        XCTAssertEqual(l.invalid.map(\.text), ["banana", "10.0.0.300"])
        XCTAssertEqual(l.entries.map(\.text), ["10.0.0.1"])
        XCTAssertFalse(l.isEmpty)
        XCTAssertTrue(WebAllowlist.parse(" \n ,").isEmpty)
    }

    /// Review focus: whitespace, CRLF, stray commas and duplicates never make the list invalid.
    func testMessyAllowlistText() {
        let l = WebAllowlist.parse(" 10.0.0.1 ,,\r\n\n10.0.0.1/32,\t192.168.0.0/16, ")
        XCTAssertEqual(l.entries.map(\.prefix.description), ["10.0.0.1", "192.168.0.0/16"])
        XCTAssertTrue(l.invalid.isEmpty)
    }
}
