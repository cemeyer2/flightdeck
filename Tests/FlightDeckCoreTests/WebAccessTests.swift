// Web dashboard, part 2: who may connect. A fixed set of interfaces stands in for this Mac's network, so every
// decision (local, tailnet, not local, the arrival interface, Advanced) is checked without touching a socket.
import XCTest
@testable import FlightDeckCore

final class WebAccessTests: XCTestCase {
    static func iface(_ name: String, _ display: String, _ kind: WebInterface.Kind, _ addrs: [String]) -> WebInterface {
        WebInterface(name: name, displayName: display, kind: kind, addresses: addrs.map { a in
            let p = a.split(separator: "/").map(String.init)
            return WebInterface.Address(ip: WebIP(p[0])!, length: Int(p[1])!)
        })
    }

    /// en0 Wi-Fi with IPv4 and global IPv6, utun4 Tailscale, utun5 another VPN, lo0.
    static func context(tailscale: Bool = true, advanced: Bool = false, processRunning: Bool = false) -> WebNetworkContext {
        var ifs = [iface("en0", "Wi-Fi", .lan, ["192.168.1.23/24", "2001:db8:1:2::23/64"]),
                   iface("utun5", "utun5", .tunnel, ["10.8.0.2/24"]),
                   iface("lo0", "lo0", .loopback, ["127.0.0.1/8", "::1/128"])]
        if tailscale { ifs.insert(iface("utun4", "utun4", .tailscale, ["100.101.102.103/32", "fd7a:115c:a1e0::1/128"]), at: 1) }
        return WebNetworkContext(interfaces: ifs, localHostName: "MacBook-Pro", tailscaleProcessRunning: processRunning, advanced: advanced)
    }

    static let en0 = WebIP("192.168.1.23")!, en0v6 = WebIP("2001:db8:1:2::23")!
    static let utun4 = WebIP("100.101.102.103")!, utun4v6 = WebIP("fd7a:115c:a1e0::1")!, utun5 = WebIP("10.8.0.2")!

    func admit(_ remote: String, via arrival: WebIP?, _ ctx: WebNetworkContext = context(), allow: String = "") -> WebAdmission {
        WebAccess.admit(remote: WebIP(remote)!, arrivalAddress: arrival, context: ctx, allowlist: .parse(allow))
    }

    func testEmptyAllowlistAdmitsLocalOnly() {
        XCTAssertEqual(admit("192.168.1.40", via: Self.en0), .admit)
        XCTAssertEqual(admit("100.64.0.5", via: Self.utun4), .drop)
        XCTAssertEqual(admit("100.64.0.5", via: Self.utun4, Self.context(advanced: true)), .drop)
        XCTAssertEqual(admit("8.8.8.8", via: Self.en0), .drop)
        XCTAssertEqual(admit("8.8.8.8", via: Self.en0, Self.context(advanced: true)), .drop)
    }

    func testGlobalIPv6OnLinkIsLocal() {
        XCTAssertEqual(admit("2001:db8:1:2::99", via: Self.en0v6), .admit)
        XCTAssertEqual(admit("2001:db8:1:2::99", via: Self.utun5), .drop)
    }

    func testTunnelArrivalIsNotLocal() {
        XCTAssertEqual(admit("fd7a:115c:a1e0::5", via: Self.utun4v6), .drop)
        XCTAssertEqual(admit("10.1.2.3", via: Self.utun5), .drop)
        XCTAssertEqual(WebAccess.classify(remote: WebIP("10.1.2.3")!, arrival: Self.context().interface(owning: Self.utun5),
                                          context: Self.context()), .notLocal)
    }

    func testTailnetClassifiedBeforeLocal() {
        XCTAssertEqual(WebAccess.label(WebPrefix("fd7a:115c:a1e0::/48")!, context: Self.context()), .tailnet)
        XCTAssertEqual(WebAccess.label(WebPrefix("fd7a:115c:a1e0::/48")!, context: Self.context(tailscale: false)), .tailnetIgnored)
        XCTAssertEqual(WebAccess.label(WebPrefix("fd00::/8")!, context: Self.context()), .local)
        XCTAssertEqual(WebAccess.EntryLabel.tailnetIgnored.text, "Tailscale not detected — ignored")
    }

    func testULAEntryDoesNotAdmitTailnet() {
        XCTAssertEqual(admit("fd12::7", via: Self.en0v6, allow: "fd00::/8"), .admit)
        XCTAssertEqual(admit("fd7a:115c:a1e0::5", via: Self.utun4v6, allow: "fd00::/8"), .drop)
        XCTAssertEqual(admit("fd7a:115c:a1e0::5", via: Self.utun4v6, allow: "fd00::/8, fd7a:115c:a1e0::/48"), .admit)
    }

    func testCGNATOnWiFiDoesNotMatchTailnet() {
        XCTAssertEqual(admit("100.64.0.5", via: Self.en0, allow: "100.64.0.0/10, fd7a:115c:a1e0::/48"), .drop)
        XCTAssertEqual(admit("100.64.0.5", via: Self.utun4, allow: "100.64.0.0/10, fd7a:115c:a1e0::/48"), .admit)
        // Advanced on does not let a tailnet entry match a not-local arrival.
        XCTAssertEqual(admit("100.64.0.5", via: Self.en0, Self.context(advanced: true), allow: "100.64.0.0/10"), .drop)
        XCTAssertEqual(admit("100.64.0.5", via: Self.en0, Self.context(advanced: true), allow: "100.64.0.0/10, 100.0.0.0/8"), .admit,
                       "a broader non-tailnet entry still counts with Advanced on")
    }

    func testCGNATOnLinkDoesNotMatchTailnet() {
        var ctx = Self.context()
        ctx.interfaces[0].addresses.append(.init(ip: WebIP("100.70.0.2")!, length: 24))
        XCTAssertEqual(WebAccess.classify(remote: WebIP("100.70.0.9")!, arrival: ctx.interface(owning: Self.en0), context: ctx), .local)
        XCTAssertEqual(admit("100.70.0.9", via: Self.en0, ctx, allow: "100.64.0.0/10"), .drop)
        XCTAssertEqual(admit("100.70.0.9", via: Self.en0, ctx, allow: "100.64.0.0/10, 100.70.0.0/24"), .drop,
                       "an entry inside the tailnet range is a tailnet entry")
        XCTAssertEqual(admit("100.70.0.9", via: Self.en0, ctx, allow: "100.0.0.0/8"), .admit)
    }

    func testProcessSignalAloneHonoursNothing() {
        let ctx = Self.context(tailscale: false, processRunning: true)
        XCTAssertTrue(ctx.tailscaleDetected)
        XCTAssertFalse(ctx.tailscaleInterfaceUp)
        XCTAssertNotNil(WebSuggestions.tailnet(ctx))
        XCTAssertEqual(WebAccess.label(WebPrefix("100.64.0.0/10")!, context: ctx), .tailnetIgnored)
        XCTAssertEqual(admit("100.64.0.5", via: nil, ctx, allow: "100.64.0.0/10"), .drop)
    }

    func testNotLocalEntryNeedsAdvanced() {
        XCTAssertEqual(admit("203.0.113.9", via: Self.en0, allow: "203.0.113.0/24"), .drop)
        XCTAssertEqual(WebAccess.label(WebPrefix("203.0.113.0/24")!, context: Self.context()), .notLocalIgnored)
        XCTAssertEqual(WebAccess.EntryLabel.notLocalIgnored.text, "Not a local address — ignored (turn on Advanced to allow)")
        let adv = Self.context(advanced: true)
        XCTAssertEqual(admit("203.0.113.9", via: Self.en0, adv, allow: "203.0.113.0/24"), .admit)
        XCTAssertEqual(WebAccess.label(WebPrefix("203.0.113.0/24")!, context: adv), .notLocal)
    }

    func testUnknownArrivalDropped() {
        XCTAssertEqual(admit("192.168.1.40", via: WebIP("192.168.77.1")), .drop)
        XCTAssertEqual(admit("192.168.1.40", via: nil), .drop)
    }

    func testLoopback() {
        XCTAssertEqual(admit("127.0.0.1", via: WebIP("127.0.0.1"), allow: "192.168.1.0/24"), .admitIfLoopbackHost)
        XCTAssertEqual(admit("127.0.0.1", via: WebIP("127.0.0.1"), allow: "127.0.0.1"), .admit)
        XCTAssertEqual(admit("::1", via: WebIP("::1")), .admitIfLoopbackHost)
    }

    func testSuggestions() {
        let ctx = Self.context()
        let local = WebSuggestions.local(ctx)
        XCTAssertEqual(local.map(\.label), ["Wi-Fi: 192.168.1.0/24", "Wi-Fi: 2001:db8:1:2::/64"])
        XCTAssertNil(WebSuggestions.tailnet(Self.context(tailscale: false)))
        let tail = WebSuggestions.tailnet(ctx)
        XCTAssertEqual(tail?.entries, ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
        XCTAssertEqual(tail?.warning, "Every device on your tailnet, including machines shared with you, will be able to see this dashboard.")

        let first = WebSuggestions.adding(local[0], to: "")
        XCTAssertEqual(first.text, "192.168.1.0/24")
        XCTAssertEqual(first.note, "Only listed addresses can connect now — add your local subnet too if you still want it")
        let more = WebSuggestions.adding(local[0], to: "10.0.0.1")
        XCTAssertEqual(more.text, "10.0.0.1\n192.168.1.0/24")
        XCTAssertNil(more.note)
        XCTAssertEqual(WebSuggestions.adding(local[0], to: "10.0.0.1,\n").text, "10.0.0.1\n192.168.1.0/24")

        let visible = WebSuggestions.visible(local + [tail!], current: .parse("192.168.1.7/24"))
        XCTAssertEqual(visible.map(\.label), ["Wi-Fi: 2001:db8:1:2::/64", "Allow my tailnet"])
    }

    func testTailscaleProcess() {
        XCTAssertTrue(WebTailscale.processRunning(processNames: ["tailscaled"], bundleIDs: []))
        XCTAssertTrue(WebTailscale.processRunning(processNames: [], bundleIDs: ["io.tailscale.ipn.macsys"]))
        XCTAssertFalse(WebTailscale.processRunning(processNames: ["Safari"], bundleIDs: []))
    }

    func testKinds() {
        let lan: Set = ["en0"]
        XCTAssertEqual(WebNetworkContext.kind(name: "lo0", addresses: [.loopbackV4], lanNames: lan), .loopback)
        XCTAssertEqual(WebNetworkContext.kind(name: "en0", addresses: [], lanNames: lan), .lan)
        XCTAssertEqual(WebNetworkContext.kind(name: "utun4", addresses: [Self.utun4], lanNames: lan), .tailscale)
        XCTAssertEqual(WebNetworkContext.kind(name: "utun5", addresses: [Self.utun5], lanNames: lan), .tunnel)
        XCTAssertEqual(WebNetworkContext.kind(name: "bridge0", addresses: [], lanNames: lan), .other)
    }

    /// The real reader: whatever this Mac has, loopback is up and nothing is classified from a tunnel as lan.
    func testReadThisMac() {
        let ctx = WebNetworkContext.read(localHostName: nil, tailscaleProcessRunning: false, advanced: false)
        XCTAssertTrue(ctx.interfaceAddresses.contains(.loopbackV4))
        XCTAssertFalse(ctx.interfaces.contains { $0.kind == .lan && $0.name.hasPrefix("utun") })
    }
}
