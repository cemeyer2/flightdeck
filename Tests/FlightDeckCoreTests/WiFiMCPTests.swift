// The `wifi` MCP tool (no BSSIDs without Location permission, never scans) and the live CoreWLAN checks, which skip on
// Macs without Wi-Fi (CI's VMs). The live scan only runs with FD_LIVE_WIFI_SCAN set, because a scan briefly
// disrupts Wi-Fi.
import XCTest
@testable import FlightDeckCore

final class WiFiFakeSource: MCPDataSource, @unchecked Sendable {
    let standalone = false
    var snap: Snapshot?
    var scan: WiFiScanResult?
    var perm: WiFiPermission.Status = .granted
    let blackBoxConfig = BlackBox.Config()
    func snapshot() async -> Snapshot? { snap }
    func findings() async -> [Finding] { [] }
    func incidents() async -> [Incident] { [] }
    func reports(since: Date) async -> [DiagnosticReport] { [] }
    func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace? { nil }
    func dailyHistory() async -> DailyLog.History? { nil }
    func checkup() async -> [CheckResult] { [] }
    func wifiScan() async -> WiFiScanResult? { scan }
    func wifiPermission() async -> WiFiPermission.Status { perm }
}

final class WiFiMCPTests: XCTestCase {
    func source(_ perm: WiFiPermission.Status) -> WiFiFakeSource {
        let src = WiFiFakeSource()
        var s = BlackBoxTests.base
        s.wifi = WiFiInfo(interface: "en0", ssid: perm == .granted ? "Home" : nil, rssi: -58, noise: -94, txRate: 864, channel: 36,
                          band: "5 GHz", width: "80 MHz", phy: "802.11ax (Wi-Fi 6/6E)", security: "WPA3", bssid: "02:00:00:00:00:aa")
        src.snap = s; src.perm = perm
        src.scan = WiFiScanResult(time: s.time, networks: [
            WiFiNetwork(id: 0, ssid: "Home", bssid: "02:00:00:00:00:aa", rssi: -58, band: .ghz5, channel: 36, widthMHz: 80),
            WiFiNetwork(id: 1, ssid: "Next door", bssid: "02:00:00:00:00:bb", rssi: -62, band: .ghz5, channel: 40, widthMHz: 80),
        ], identifiersHidden: false, ownBSSID: "02:00:00:00:00:aa", ownChannel: 36, ownBand: .ghz5, ownSSID: "Home")
        return src
    }

    func call(_ src: MCPDataSource) async throws -> (JSON, String) {
        let r = await MCPTools(source: src).call("wifi", arguments: [:])
        XCTAssertFalse(r.isError, r.text)
        return (try JSON.parse(Data(r.text.utf8)), r.text)
    }

    func testWiFiToolWithPermission() async throws {
        let (j, _) = try await call(source(.granted))
        XCTAssertEqual(j["link"]?["rssi_dbm"]?.int, -58)
        XCTAssertEqual(j["link"]?["bssid"]?.string, "02:00:00:00:00:aa")
        XCTAssertEqual(j["last_scan"]?["networks"]?.int, 2)
        XCTAssertEqual(j["last_scan"]?["strongest"]?.array?.first?["yours"]?.bool, true)
        XCTAssertTrue(j["last_scan"]?["recommendation"]?.string?.contains("channel 36") == true)
    }

    func testNoBSSIDsWithoutPermission() async throws {
        let (j, text) = try await call(source(.denied))
        XCTAssertEqual(j["location_permission"]?.string, "denied")
        XCTAssertFalse(text.contains("02:00:00:00:00"), "no BSSID may appear without Location permission")
        XCTAssertTrue(j["link"]?["ssid"]?.string?.hasPrefix("unavailable") == true)
    }

    func testNoScanSaysSo() async throws {
        let src = source(.granted); src.scan = nil
        let (j, _) = try await call(src)
        XCTAssertTrue(j["last_scan"]?.string?.contains("never starts one") == true)
    }

    func testBSSIDIsNotEncoded() throws {
        let w = WiFiInfo(interface: "en0", ssid: nil, rssi: -60, noise: -90, txRate: 100, bssid: "02:00:00:00:00:aa")
        let data = try JSONEncoder().encode(w)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("bssid"), "the BSSID must stay out of recordings")
        XCTAssertNil(try JSONDecoder().decode(WiFiInfo.self, from: data).bssid)
    }

    // MARK: Live

    func testLiveLink() throws {
        guard let w = WiFiInfo.current() else { throw XCTSkip("no associated Wi-Fi interface (CI VM or Wi-Fi off)") }
        XCTAssertLessThan(w.rssi, 0)
        let p = WiFiLinkPoint(w, time: Date())
        if let b = p.band, let c = p.channel { XCTAssertNotNil(b.frequency(channel: c), "\(b.rawValue) channel \(c)") }
    }

    func testLiveScan() throws {
        guard ProcessInfo.processInfo.environment["FD_LIVE_WIFI_SCAN"] != nil else { throw XCTSkip("set FD_LIVE_WIFI_SCAN=1 to scan (briefly disrupts Wi-Fi)") }
        guard WiFiInfo.current() != nil else { throw XCTSkip("no Wi-Fi") }
        let r = try WiFiScanner.scan().get()
        XCTAssertFalse(r.networks.isEmpty)
        for n in r.networks { if let b = n.band, let c = n.channel { XCTAssertNotNil(b.frequency(channel: c)); XCTAssertNotNil(n.span) } }
        // Anonymized summary for the fixture in WiFiFixtureTests: no SSIDs or BSSIDs.
        for n in r.networks {
            print("FIXTURE", n.band?.rawValue ?? "?", n.channel ?? -1, n.widthMHz ?? -1, n.centerChannel ?? -1, n.rssi, n.ssid == nil ? 0 : 1, n.bssid == nil ? 0 : 1, n.phy ?? "-", n.security ?? "-")
        }
        print("FIXTURE hidden", r.identifiersHidden, "own", r.ownBand?.rawValue ?? "?", r.ownChannel ?? -1)
    }
}
