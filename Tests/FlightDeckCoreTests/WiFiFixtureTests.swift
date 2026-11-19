// A real scan captured once on a development Mac (via WiFiMCPTests.testLiveScan), reduced to band, channel, width,
// signal, standard and security. It had no SSIDs or BSSIDs to remove: the test runner has no Location permission, so
// macOS withheld them (and the beacon IEs). The Mac was on 5 GHz channel 132 at 80 MHz.
import XCTest
@testable import FlightDeckCore

final class WiFiFixtureTests: XCTestCase {
    /// (band, channel, width, rssi, phy, security), strongest first, as captured.
    static let rows: [(WiFiBand, Int, Int, Int, String, String)] = [
        (.ghz2, 1, 20, -25, "802.11n (Wi-Fi 4)", "WPA2/WPA3"), (.ghz2, 1, 20, -44, "802.11n (Wi-Fi 4)", "Open/OWE"),
        (.ghz2, 1, 20, -45, "802.11n (Wi-Fi 4)", "WPA3"), (.ghz5, 132, 80, -51, "802.11ac (Wi-Fi 5)", "WPA3"),
        (.ghz5, 132, 80, -51, "802.11ac (Wi-Fi 5)", "Open/OWE"), (.ghz5, 60, 160, -53, "802.11ax (Wi-Fi 6)", "WPA2/WPA3"),
        (.ghz5, 60, 160, -53, "802.11ax (Wi-Fi 6)", "WPA2/WPA3"), (.ghz5, 60, 160, -53, "802.11ax (Wi-Fi 6)", "WPA3"),
        (.ghz5, 161, 40, -54, "802.11n (Wi-Fi 4)", "WPA2/WPA3"), (.ghz2, 11, 20, -55, "802.11n (Wi-Fi 4)", "WPA2/WPA3"),
        (.ghz2, 1, 20, -60, "802.11n (Wi-Fi 4)", "WPA2/WPA3"), (.ghz5, 108, 80, -60, "802.11ac (Wi-Fi 5)", "WPA3"),
        (.ghz2, 11, 20, -61, "802.11n (Wi-Fi 4)", "Open/OWE"), (.ghz5, 157, 80, -67, "802.11ac (Wi-Fi 5)", "WPA3"),
        (.ghz5, 157, 80, -67, "802.11ac (Wi-Fi 5)", "WPA2/WPA3"), (.ghz5, 153, 20, -72, "802.11ac (Wi-Fi 5)", "WPA2/WPA3"),
        (.ghz2, 1, 20, -74, "802.11n (Wi-Fi 4)", "WPA3"), (.ghz5, 108, 80, -78, "802.11ac (Wi-Fi 5)", "WPA2/WPA3"),
        (.ghz5, 100, 80, -78, "802.11ac (Wi-Fi 5)", "WPA2/WPA3"), (.ghz5, 100, 80, -78, "802.11ac (Wi-Fi 5)", "WPA2/WPA3"),
        (.ghz5, 60, 160, -82, "802.11ax (Wi-Fi 6)", "WPA3"), (.ghz5, 60, 160, -82, "802.11ax (Wi-Fi 6)", "WPA3"),
        (.ghz5, 40, 80, -84, "802.11ax (Wi-Fi 6)", "Open/OWE"), (.ghz5, 40, 80, -84, "802.11ax (Wi-Fi 6)", "WPA2/WPA3"),
        (.ghz5, 40, 80, -85, "802.11ax (Wi-Fi 6)", "WPA3"),
    ]

    static var scan: WiFiScanResult {
        WiFiScanResult(time: Date(), networks: rows.enumerated().map { k, r in
            WiFiNetwork(id: k, rssi: r.3, band: r.0, channel: r.1, widthMHz: r.2, security: r.5, phy: r.4)
        }, identifiersHidden: true, ownChannel: 132, ownBand: .ghz5)
    }

    func testEveryNetworkHasASpan() {
        for n in Self.scan.networks { XCTAssertNotNil(n.span, "\(n.band!.rawValue) \(n.channel!) at \(n.widthMHz!) MHz") }
    }

    func testWideNetworksCoverTheirBlocks() throws {
        let s = Self.scan
        let loads = Dictionary(uniqueKeysWithValues: WiFiCongestion.loads(s, band: .ghz5, own: []).map { ($0.channel, $0) })
        // The 160 MHz networks on primary 60 occupy 36–64; 80 MHz on 132 occupies 132–144.
        for c in [36, 44, 52, 64] { XCTAssertGreaterThanOrEqual(loads[c]?.networks ?? 0, 5, "channel \(c)") }
        for c in [132, 136, 140, 144] { XCTAssertEqual(loads[c]?.networks, 2, "channel \(c)") }
        XCTAssertEqual(loads[116]?.networks, 0)
    }

    func testRecommendationFromRealScan() throws {
        let s = Self.scan
        // Names hidden: the access point is inferred from channel and signal (the link read -51 dBm).
        // Two entries at -51 dBm on 132/80 MHz: one radio with two SSIDs (WPA3 and its OWE transition network).
        XCTAssertEqual(WiFiCongestion.ownIDs(s, linkRSSI: -51), [3, 4])
        let r = try XCTUnwrap(WiFiCongestion.recommend(s, band: .ghz5, channel: 132, widthMHz: 80, linkRSSI: -51))
        XCTAssertEqual(r.strongNeighbours, 0)
        XCTAssertTrue(r.text.contains("5 GHz channel 132 (80 MHz)"), r.text)
        XCTAssertTrue(r.text.contains("identified by its channel and signal"), r.text)
    }
}
