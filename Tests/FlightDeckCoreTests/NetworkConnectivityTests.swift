// Tests for the connectivity findings (an interface that lost its IP address, one that stopped receiving), the link
// status and packet counters they read, and the evidence captured for them. Analyzer inputs are quiet Snapshots from
// `AnalyzerTests.snap` with only `network.interfaces` set, at fixed timestamps.
import XCTest
@testable import FlightDeckCore

final class NetworkConnectivityTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    let lan = ["192.168.1.80", "fe80::1c2b:3d4e:5f60:7182"]

    /// One interface sample. Defaults describe a healthy wired adapter.
    func iface(_ name: String, link: Bool? = true, addrs: [String]? = nil, inPkts: UInt64 = 1000, outPkts: UInt64 = 1000,
               mac: String? = "aa:bb:cc:00:00:01") -> InterfaceSample {
        InterfaceSample(name: name, inBps: 0, outBps: 0, totalIn: 0, totalOut: 0, linkSpeed: 1_000_000_000, isUp: true,
                        addresses: addrs ?? lan, mac: mac, linkActive: link, inPackets: inPkts, outPackets: outPkts,
                        inErrors: 0, outErrors: 0, inDrops: 0)
    }

    func snap(_ sec: Double, _ ifaces: [InterfaceSample]) -> Snapshot {
        var s = AnalyzerTests().snap(t0.addingTimeInterval(sec), procs: [])
        s.network.interfaces = ifaces
        return s
    }

    /// Feeds `seconds` of one-second samples, building each interface list from the elapsed second.
    @discardableResult
    func run(_ a: Analyzer, from: Double, to: Double, _ make: (Double) -> [InterfaceSample]) -> [Finding] {
        var out: [Finding] = []
        for s in stride(from: from, to: to, by: 1) { out = a.ingest(snap(s, make(s))) }
        return out
    }

    func connectivity(_ fs: [Finding]) -> [Finding] { fs.filter { $0.id.hasPrefix("net-noip:") || $0.id.hasPrefix("net-rx-stall:") } }

    // MARK: lost IP address

    /// The reported failure: link stays up, the address disappears and doesn't come back.
    func testLostAddressOnActiveLinkIsReported() throws {
        let a = Analyzer()
        run(a, from: 0, to: 60) { _ in [self.iface("en9")] }
        XCTAssertTrue(connectivity(a.findings).isEmpty, "healthy link raises nothing")
        let fs = run(a, from: 60, to: 130) { _ in [self.iface("en9", addrs: ["fe80::1c2b:3d4e:5f60:7182"])] }
        let f = try XCTUnwrap(fs.first { $0.id == "net-noip:en9" }, "an address lost for 70 s on an active link is a finding")
        XCTAssertEqual(f.severity, .warning)
        XCTAssertTrue(f.title.contains("en9"))
        XCTAssertLessThan(f.since.timeIntervalSince(t0.addingTimeInterval(60)), 5, "since is when the address went, not when it was reported")
    }

    /// A DHCP renewal can drop the address for a few seconds; that must not look like an outage.
    func testShortAddressBlipIsIgnored() {
        let a = Analyzer()
        run(a, from: 0, to: 60) { _ in [self.iface("en9")] }
        run(a, from: 60, to: 68) { _ in [self.iface("en9", addrs: [])] }
        let fs = run(a, from: 68, to: 120) { _ in [self.iface("en9")] }
        XCTAssertTrue(connectivity(fs).isEmpty)
        XCTAssertTrue(connectivity(a.findings).isEmpty)
    }

    func testFindingClearsWhenAddressReturns() {
        let a = Analyzer()
        run(a, from: 0, to: 30) { _ in [self.iface("en9")] }
        run(a, from: 30, to: 120) { _ in [self.iface("en9", addrs: [])] }
        XCTAssertNotNil(a.findings.first { $0.id == "net-noip:en9" })
        run(a, from: 120, to: 125) { _ in [self.iface("en9")] }
        XCTAssertNil(a.findings.first { $0.id == "net-noip:en9" })
    }

    /// Self-assigned 169.254.x.x is DHCP failure by definition, so it is reported even if the interface never had a lease.
    func testSelfAssignedAddressIsReportedWithoutHistory() throws {
        let a = Analyzer()
        let fs = run(a, from: 0, to: 80) { _ in [self.iface("en9", addrs: ["169.254.77.12", "fe80::1"])] }
        let f = try XCTUnwrap(fs.first { $0.id == "net-noip:en9" })
        XCTAssertTrue(f.title.lowercased().contains("self-assigned"))
    }

    /// The ten-odd interfaces of a normal Mac that are enabled but have no link or no address must never fire.
    func testInactiveAndNonPhysicalInterfacesNeverFire() {
        let a = Analyzer()
        let noisy: (Double) -> [InterfaceSample] = { s in [
            self.iface("en4", link: false, addrs: []),                       // unplugged port
            self.iface("en0", link: false, addrs: []),                       // Wi-Fi switched off
            self.iface("anpi0", link: false, addrs: [], mac: "f6:29:e9:08:15:2e"),
            self.iface("bridge0", link: true, addrs: []),                    // Thunderbolt bridge: active, never addressed
            self.iface("awdl0", link: true, addrs: ["fe80::1"]),
            self.iface("utun3", link: nil, addrs: [], mac: nil),             // tunnel without IPv4
            self.iface("lo0", link: nil, addrs: ["127.0.0.1"], mac: nil),
            self.iface("en5", link: true, addrs: [])                         // plugged in, never had an address: not a regression
        ] }
        run(a, from: 0, to: 300, noisy)
        XCTAssertTrue(connectivity(a.findings).isEmpty, "got \(connectivity(a.findings).map(\.id))")
    }

    /// Wi-Fi turned off after working is the user's doing, not a failure.
    func testLinkGoingDownAfterWorkingIsNotReported() {
        let a = Analyzer()
        run(a, from: 0, to: 60) { _ in [self.iface("en0")] }
        run(a, from: 60, to: 200) { _ in [self.iface("en0", link: false, addrs: [])] }
        XCTAssertTrue(connectivity(a.findings).isEmpty)
    }

    /// Without a media status (link unknown) nothing is concluded from a missing address.
    func testUnknownLinkStatusDoesNotFire() {
        let a = Analyzer()
        run(a, from: 0, to: 60) { _ in [self.iface("en9", link: nil)] }
        run(a, from: 60, to: 200) { _ in [self.iface("en9", link: nil, addrs: [])] }
        XCTAssertTrue(connectivity(a.findings).isEmpty)
    }

    /// Joining a network: Wi-Fi has link at once, and 802.1X plus DHCP can take 40 s. The previous network's lease doesn't count.
    func testSlowNetworkJoinIsNotReported() {
        let a = Analyzer()
        run(a, from: 0, to: 30) { _ in [self.iface("en0")] }                                        // worked before
        run(a, from: 30, to: 60) { _ in [self.iface("en0", link: false, addrs: [])] }                // moved
        let fs = run(a, from: 60, to: 100) { _ in [self.iface("en0", addrs: [])] }                  // 40 s of auth and DHCP
        XCTAssertTrue(connectivity(fs).isEmpty)
        let after = run(a, from: 100, to: 160) { _ in [self.iface("en0")] }
        XCTAssertTrue(connectivity(after).isEmpty)
    }

    /// On an IPv6-only network there is no IPv4 address by design: a caution that says IPv4, not a warning about the IP address.
    func testNoIPv4WithGlobalIPv6IsOnlyACaution() throws {
        let a = Analyzer()
        run(a, from: 0, to: 30) { _ in [self.iface("en0")] }
        let fs = run(a, from: 30, to: 120) { _ in [self.iface("en0", addrs: ["2001:db8:1::5", "fe80::1"])] }
        let f = try XCTUnwrap(fs.first { $0.id == "net-noip:en0" })
        XCTAssertEqual(f.severity, .caution)
        XCTAssertTrue(f.title.contains("IPv4")); XCTAssertTrue(f.detail?.contains("IPv6-only") == true)
    }

    // MARK: receive stall

    /// Transmit keeps counting while nothing is received for 40 s on a link that is up and addressed.
    func testReceiveStallWhileTransmitting() throws {
        let a = Analyzer()
        run(a, from: 0, to: 30) { s in [self.iface("en9", inPkts: 1000 + UInt64(s) * 10, outPkts: 1000 + UInt64(s) * 10)] }
        let fs = run(a, from: 30, to: 80) { s in [self.iface("en9", inPkts: 1300, outPkts: 1000 + UInt64(s) * 10)] }
        let f = try XCTUnwrap(fs.first { $0.id == "net-rx-stall:en9" })
        XCTAssertEqual(f.severity, .warning)
    }

    func testHealthyTrafficDoesNotStall() {
        let a = Analyzer()
        let fs = run(a, from: 0, to: 200) { s in [self.iface("en9", inPkts: 1000 + UInt64(s) * 5, outPkts: 1000 + UInt64(s) * 5)] }
        XCTAssertTrue(connectivity(fs).isEmpty)
    }

    /// A quiet interface (nothing in, nothing out) is idle, not stalled.
    func testIdleInterfaceDoesNotStall() {
        let a = Analyzer()
        let fs = run(a, from: 0, to: 200) { _ in [self.iface("en9", inPkts: 5000, outPkts: 5000)] }
        XCTAssertTrue(connectivity(fs).isEmpty)
    }

    /// A trickle of outbound packets (a few keep-alives) is not enough to call a stall.
    func testTrickleOfOutboundIsNotAStall() {
        let a = Analyzer()
        let fs = run(a, from: 0, to: 120) { s in [self.iface("en9", inPkts: 5000, outPkts: 5000 + UInt64(s / 30))] }
        XCTAssertTrue(connectivity(fs).isEmpty)
    }

    /// A quiet segment where the Mac sends a keep-alive every 20 s is idle, however long it lasts: the outbound count is
    /// per 30 s window, not cumulative since the last inbound packet.
    func testSlowOutboundTrickleOverMinutesIsNotAStall() {
        let a = Analyzer()
        let fs = run(a, from: 0, to: 900) { s in [self.iface("en9", inPkts: 5000, outPkts: 5000 + UInt64(s / 20))] }
        XCTAssertTrue(connectivity(fs).isEmpty)
        XCTAssertTrue(connectivity(a.findings).isEmpty)
    }

    /// Once real outbound traffic resumes during the silence, the stall is reported, and clears when something arrives.
    func testStallAfterLongQuietSpellAndRecovery() {
        let a = Analyzer()
        run(a, from: 0, to: 600) { s in [self.iface("en9", inPkts: 5000, outPkts: 5000 + UInt64(s / 20))] }
        let fs = run(a, from: 600, to: 660) { s in [self.iface("en9", inPkts: 5000, outPkts: 5030 + UInt64(s - 600) * 3)] }
        XCTAssertNotNil(fs.first { $0.id == "net-rx-stall:en9" })
        let ok = run(a, from: 660, to: 665) { s in [self.iface("en9", inPkts: 5000 + UInt64(s - 659), outPkts: 5300)] }
        XCTAssertTrue(connectivity(ok).isEmpty)
    }

    /// Packets counted at the adapter can't show software drops, and the finding must say so where the user reads it.
    func testReceiveStallFindingStatesItsLimit() throws {
        let a = Analyzer()
        run(a, from: 0, to: 30) { s in [self.iface("en9", inPkts: 1000 + UInt64(s) * 10, outPkts: 1000 + UInt64(s) * 10)] }
        let fs = run(a, from: 30, to: 80) { s in [self.iface("en9", inPkts: 1300, outPkts: 1000 + UInt64(s) * 10)] }
        let d = try XCTUnwrap(fs.first { $0.id == "net-rx-stall:en9" }?.detail)
        XCTAssertTrue(d.contains("before any VPN, network filter or security software"))
        XCTAssertTrue(d.contains("cannot see traffic"))
        XCTAssertTrue(d.contains("the cause is higher up, in software"))
    }

    func testCountersMissingDoNotFire() {
        var i = iface("en9"); i.inPackets = nil; i.outPackets = nil
        let a = Analyzer()
        let fs = run(a, from: 0, to: 200) { _ in [i] }
        XCTAssertTrue(connectivity(fs).isEmpty)
    }

    /// A sampling gap (sleep) breaks the run: no finding may be bridged across it.
    func testSamplingGapResetsConnectivityState() {
        let a = Analyzer()
        run(a, from: 0, to: 30) { _ in [self.iface("en9")] }
        run(a, from: 30, to: 40) { _ in [self.iface("en9", addrs: [])] }
        let fs = [a.ingest(snap(600, [iface("en9", addrs: [])]))].flatMap { $0 }
        XCTAssertTrue(connectivity(fs).isEmpty, "the first sample after a gap starts a fresh condition")
    }

    // MARK: stored data

    /// Frames saved before these fields existed must still decode, with the new fields absent.
    func testOldInterfaceSampleJSONStillDecodes() throws {
        let json = #"{"name":"en9","inBps":1,"outBps":2,"totalIn":3,"totalOut":4,"linkSpeed":1000000000,"isUp":true,"addresses":["192.168.1.80"],"mac":"aa:bb:cc:00:00:01"}"#
        let i = try JSONDecoder().decode(InterfaceSample.self, from: Data(json.utf8))
        XCTAssertEqual(i.name, "en9")
        XCTAssertNil(i.linkActive); XCTAssertNil(i.inPackets); XCTAssertNil(i.outPackets)
        XCTAssertNil(i.inErrors); XCTAssertNil(i.outErrors); XCTAssertNil(i.inDrops)
    }

    func testNewFieldsRoundTrip() throws {
        let i = iface("en9")
        let back = try JSONDecoder().decode(InterfaceSample.self, from: JSONEncoder().encode(i))
        XCTAssertEqual(back.linkActive, true); XCTAssertEqual(back.inPackets, 1000); XCTAssertEqual(back.inDrops, 0)
    }

    // MARK: live

    /// The media status read from the kernel must agree with ifconfig's "status:" line on this Mac, for every interface
    /// that has one. Interfaces without a status line must read nil.
    func testLinkActiveMatchesIfconfig() throws {
        guard let out = Shell.run("/sbin/ifconfig", []) else { throw XCTSkip("ifconfig unavailable") }
        var expected: [String: Bool] = [:]; var cur: String?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if let c = line.first, c != "\t", c != " ", let colon = line.firstIndex(of: ":") { cur = String(line[..<colon]) }
            else if let cur, line.contains("status: active") { expected[cur] = true }
            else if let cur, line.contains("status: inactive") { expected[cur] = false }
        }
        try XCTSkipIf(expected.isEmpty, "no interface with a media status")
        let sample = NetworkSampler().sample()
        for (name, active) in expected {
            guard let mine = sample.interfaces.first(where: { $0.name == name }) else { continue }
            XCTAssertEqual(mine.linkActive, active, "\(name) link status disagrees with ifconfig")
        }
        for i in sample.interfaces where NetworkSampler.isVirtual(i.name) { XCTAssertNil(i.linkActive, i.name) }
    }

    /// Packet counters are read for real interfaces and never go backwards between samples.
    func testPacketCountersPresentAndMonotonic() {
        let s = NetworkSampler()
        let a = s.sample(), b = s.sample()
        guard let lo = b.interfaces.first(where: { $0.name == "lo0" }), let lo0 = a.interfaces.first(where: { $0.name == "lo0" }) else { return XCTFail("no lo0") }
        XCTAssertNotNil(lo.inPackets); XCTAssertNotNil(lo.outPackets)
        XCTAssertGreaterThanOrEqual(lo.inPackets ?? 0, lo0.inPackets ?? 0)
    }

    // MARK: evidence and triage

    let ifconfigNoAddress = """
    en9: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \tether 00:e0:4c:68:00:01
    \tinet6 fe80::1c2b:3d4e:5f60:7182%en9 prefixlen 64 scopeid 0x10
    \tmedia: autoselect (1000baseT <full-duplex>)
    \tstatus: active
    """
    let routesNoDefault = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    127                127.0.0.1          UCS                   lo0
    """

    func testEvidenceSummaryDescribesLinkAddressAndRoute() {
        XCTAssertEqual(NetworkEvidence.summarize(interface: "en9", ifconfig: ifconfigNoAddress, routes: routesNoDefault),
                       "en9: link active, no IPv4 address, no default route on en9")
        let ok = ifconfigNoAddress.replacingOccurrences(of: "\tmedia", with: "\tinet 192.168.1.80 netmask 0xffffff00 broadcast 192.168.1.255\n\tmedia")
        let routes = routesNoDefault + "\ndefault            192.168.1.1        UGScg                 en9"
        XCTAssertEqual(NetworkEvidence.summarize(interface: "en9", ifconfig: ok, routes: routes),
                       "en9: link active, IPv4 192.168.1.80, default route via 192.168.1.1")
        // A default route on another interface is not this interface's route.
        XCTAssertTrue(NetworkEvidence.summarize(interface: "en0", ifconfig: ok, routes: routes).hasSuffix("no default route on en0"))
    }

    func testAgentProcessFilterKeepsHeaderAndSecurityAgents() {
        let ps = """
          PID     ELAPSED  %CPU STAT COMM
            1       10:00   0.0 Ss   /sbin/launchd
          412       10:00   1.2 Ss   /Library/CS/falcond
          777       09:59   0.4 S    /Applications/Zscaler/Zscaler.app/Contents/MacOS/Zscaler
          900       09:00   3.0 S    /Applications/Safari.app/Contents/MacOS/Safari
        """
        let out = NetworkEvidence.agentProcesses(ps).split(separator: "\n").map(String.init)
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out[0].contains("PID")); XCTAssertTrue(out[1].contains("falcond")); XCTAssertTrue(out[2].contains("Zscaler"))
    }

    /// A real capture on loopback: the report is written next to the given directory, with every section and a summary.
    func testCaptureWritesReportWithAllSections() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-net-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let (url, summary) = try XCTUnwrap(NetworkEvidence.capture(interface: "lo0", incident: id, directory: dir, timeout: 5))
        XCTAssertEqual(url.lastPathComponent, "\(id.uuidString)-network-lo0.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        for c in NetworkEvidence.commands(interface: "lo0") { XCTAssertTrue(text.contains("### \(c.title)"), c.title) }
        XCTAssertTrue(text.contains("### VPN, filter and security processes"))
        XCTAssertTrue(text.contains("How to read this") && text.contains("counted before any VPN, network filter or security software"))
        XCTAssertTrue(try XCTUnwrap(summary).hasPrefix("lo0:"))
    }

    /// An address-less or silent interface points the triage reader at the Flight Log, where its evidence is, and not at the Wi-Fi tool.
    func testTriageRoutesConnectivityFindingsToTheFlightLog() {
        for id in ["net-noip:en9", "net-rx-stall:en9"] {
            let f = Finding(id: id, severity: .warning, icon: "network.slash", title: "t", detail: nil, since: t0, destination: nil)
            let (sub, tool, _) = Triage.route(f)
            XCTAssertEqual(sub, "network"); XCTAssertEqual(tool, "recent_incidents")
        }
        let wifi = Finding(id: "wifi-weak", severity: .info, icon: "x", title: "t", detail: nil, since: t0, destination: nil)
        XCTAssertEqual(Triage.route(wifi).1, "wifi", "existing routing is unchanged")
    }
}
