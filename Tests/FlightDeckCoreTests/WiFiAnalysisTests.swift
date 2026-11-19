import XCTest
@testable import FlightDeckCore

/// Congestion scoring, recommendations, roam detection and health ratings, on synthetic scans.
final class WiFiAnalysisTests: XCTestCase {
    func net(_ id: Int, _ ssid: String?, _ rssi: Int, _ band: WiFiBand, _ ch: Int, _ w: Int, bssid: String? = nil) -> WiFiNetwork {
        WiFiNetwork(id: id, ssid: ssid, bssid: bssid ?? (ssid == nil ? nil : String(format: "02:00:00:00:00:%02x", id)), rssi: rssi, band: band, channel: ch, widthMHz: w)
    }

    /// Ours on 5 GHz 36 at 80 MHz with six strong neighbours on 36–48; 149 has one weak one.
    func crowded() -> WiFiScanResult {
        var nets = [net(0, "Home", -50, .ghz5, 36, 80, bssid: "02:00:00:00:00:aa")]
        for (k, ch) in [36, 40, 44, 48, 36, 44].enumerated() { nets.append(net(k + 1, "N\(k)", -60 - k, .ghz5, ch, k % 2 == 0 ? 80 : 20)) }
        nets.append(net(9, "Far", -86, .ghz5, 149, 80))
        return WiFiScanResult(time: Date(), networks: nets, identifiersHidden: false, ownBSSID: "02:00:00:00:00:aa", ownChannel: 36, ownBand: .ghz5, ownSSID: "Home")
    }

    func testWeight() {
        XCTAssertEqual(WiFiCongestion.weight(rssi: -40), 1)
        XCTAssertEqual(WiFiCongestion.weight(rssi: -55), 1)
        XCTAssertEqual(WiFiCongestion.weight(rssi: -90), 0)
        XCTAssertEqual(WiFiCongestion.weight(rssi: -72), 18.0 / 35, accuracy: 1e-9)
    }

    func testLoadsCountWideNetworksOnEveryChannel() {
        let scan = crowded()
        let own = WiFiCongestion.ownIDs(scan, linkRSSI: -50)
        XCTAssertEqual(own, [0])
        let loads = Dictionary(uniqueKeysWithValues: WiFiCongestion.loads(scan, band: .ghz5, own: own).map { ($0.channel, $0) })
        // Our 80 MHz network shows on all of 36–48, highlighted.
        for c in [36, 40, 44, 48] { XCTAssertEqual(loads[c]?.ownScore ?? 0, 1, accuracy: 1e-9) }
        XCTAssertEqual(loads[52]?.score, 0)
        XCTAssertGreaterThan(loads[44]!.score, loads[149]!.score)
        XCTAssertEqual(loads[36]?.strong, 3, "N0 and N2 (80 MHz) plus N4 on 36")
    }

    func testLoads24GHzOverlap() {
        let scan = WiFiScanResult(time: Date(), networks: [net(0, "A", -50, .ghz2, 6, 20)], identifiersHidden: false)
        let l = Dictionary(uniqueKeysWithValues: WiFiCongestion.loads(scan, band: .ghz2, own: []).map { ($0.channel, $0.score) })
        XCTAssertEqual(l[6] ?? 0, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(l[4] ?? 0, 0, "a 22 MHz signal on 6 spills onto 4")
        XCTAssertEqual(l[1], 0); XCTAssertEqual(l[11], 0)
    }

    func testRecommendsClearerChannel() throws {
        let r = try XCTUnwrap(WiFiCongestion.recommend(crowded(), band: .ghz5, channel: 36, widthMHz: 80, linkRSSI: -50))
        XCTAssertEqual(r.strongNeighbours, 6)
        XCTAssertEqual(r.suggestion, 149)
        XCTAssertFalse(r.suggestionIsDFS)
        XCTAssertTrue(r.text.contains("5 GHz channel 36 (80 MHz) with 6 strong neighbours"), r.text)
        XCTAssertTrue(r.text.contains("channel 149 looks clearer"), r.text)
        XCTAssertTrue(r.text.contains("only what this Mac hears"), r.text)
    }

    func testNoRecommendationWhenClear() throws {
        let scan = WiFiScanResult(time: Date(), networks: [net(0, "Home", -50, .ghz5, 149, 80), net(1, "X", -84, .ghz5, 36, 80)],
                                  identifiersHidden: false, ownSSID: "Home")
        let r = try XCTUnwrap(WiFiCongestion.recommend(scan, band: .ghz5, channel: 149, widthMHz: 80, linkRSSI: -50))
        XCTAssertNil(r.suggestion)
        XCTAssertEqual(r.strongNeighbours, 0)
        XCTAssertTrue(r.text.contains("That looks good"), r.text)
    }

    func test24GHzRecommendsOneSixEleven() throws {
        let nets = [net(0, "Home", -50, .ghz2, 6, 40), net(1, "A", -55, .ghz2, 6, 20), net(2, "B", -58, .ghz2, 5, 20),
                    net(3, "C", -60, .ghz2, 7, 20), net(4, "D", -62, .ghz2, 11, 20)]
        let scan = WiFiScanResult(time: Date(), networks: nets, identifiersHidden: false, ownSSID: "Home")
        let r = try XCTUnwrap(WiFiCongestion.recommend(scan, band: .ghz2, channel: 6, widthMHz: 40, linkRSSI: -50))
        XCTAssertEqual(r.suggestion, 1)
        XCTAssertTrue(r.text.contains("20 MHz is usually better"), r.text)
    }

    func testOwnNetworkGuessedWhenNamesHidden() {
        let nets = [net(0, nil, -48, .ghz5, 36, 80), net(1, nil, -70, .ghz5, 36, 80), net(2, nil, -45, .ghz5, 149, 80)]
        let scan = WiFiScanResult(time: Date(), networks: nets, identifiersHidden: true, ownChannel: 36, ownBand: .ghz5)
        XCTAssertEqual(WiFiCongestion.ownIDs(scan, linkRSSI: -50), [0])
        XCTAssertEqual(WiFiCongestion.ownIDs(scan, linkRSSI: -20), [], "nothing on our channel within 8 dB")
        let r = WiFiCongestion.recommend(scan, band: .ghz5, channel: 36, widthMHz: 80, linkRSSI: -50)
        XCTAssertTrue(r?.text.contains("identified by its channel and signal") == true)
    }

    // MARK: Roaming

    func pt(_ t: Double, _ bssid: String?, _ band: WiFiBand = .ghz5, _ ch: Int = 36, rssi: Int = -60) -> WiFiLinkPoint {
        WiFiLinkPoint(time: Date(timeIntervalSince1970: t), rssi: rssi, noise: -95, txRate: 800, channel: ch, band: band, widthMHz: 80, bssid: bssid)
    }

    func testRoamDetection() {
        let pts = [pt(0, "aa"), pt(5, "aa"), pt(10, "bb", .ghz5, 149), pt(15, "bb", .ghz5, 149), pt(20, "cc", .ghz2, 6), pt(25, "cc", .ghz2, 11)]
        let ev = WiFiLinkHistory.events(pts)
        XCTAssertEqual(ev.map(\.kind), [.roam, .roam, .channelChange])
        XCTAssertTrue(ev[1].text.contains("5 GHz → 2.4 GHz"), ev[1].text)
        XCTAssertEqual(ev[0].time, Date(timeIntervalSince1970: 10))
    }

    func testChannelChangeWithoutBSSID() {
        let ev = WiFiLinkHistory.events([pt(0, nil), pt(5, nil, .ghz2, 6)])
        XCTAssertEqual(ev.map(\.kind), [.channelChange])
        XCTAssertTrue(ev[0].text.contains("BSSID is hidden"))
        XCTAssertTrue(WiFiLinkHistory.events([pt(0, nil), pt(5, nil)]).isEmpty)
    }

    func testDropsAndDedup() {
        var h = WiFiLinkHistory(capacity: 4)
        h.add(pt(0, "aa")); h.add(pt(1, "aa")); h.add(pt(2, "aa"))
        XCTAssertEqual(h.points.count, 1, "identical readings within 5 s are the sampler's cache")
        h.addAbsent(at: Date(timeIntervalSince1970: 8)); h.addAbsent(at: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(h.drops.count, 1)
        h.add(pt(12, "bb"))
        XCTAssertEqual(h.events.map(\.kind), [.disconnected, .reconnected], "a reconnect elsewhere isn't a roam")
        for t in 20..<30 { h.add(pt(Double(t * 6), "bb", rssi: -60 - t)) }
        XCTAssertEqual(h.points.count, 4)
    }

    // MARK: Health

    func testRatings() {
        XCTAssertEqual(WiFiHealth.signal(-50), .excellent); XCTAssertEqual(WiFiHealth.signal(-67), .good)
        XCTAssertEqual(WiFiHealth.signal(-72), .fair); XCTAssertEqual(WiFiHealth.signal(-80), .poor)
        XCTAssertEqual(WiFiHealth.snr(45), .excellent); XCTAssertEqual(WiFiHealth.snr(30), .good)
        XCTAssertEqual(WiFiHealth.snr(18), .fair); XCTAssertEqual(WiFiHealth.snr(10), .poor)
        XCTAssertEqual(WiFiHealth.width(20, band: .ghz2).0, .good); XCTAssertEqual(WiFiHealth.width(40, band: .ghz2).0, .fair)
        XCTAssertEqual(WiFiHealth.width(20, band: .ghz5).0, .poor); XCTAssertEqual(WiFiHealth.width(80, band: .ghz5).0, .excellent)
        XCTAssertEqual(WiFiHealth.width(320, band: .ghz6).0, .excellent); XCTAssertEqual(WiFiHealth.width(nil, band: .ghz6).0, .unknown)
        XCTAssertEqual(WiFiHealth.interference(score: nil, utilization: nil).0, .unknown)
        XCTAssertEqual(WiFiHealth.interference(score: 4, utilization: nil).0, .poor)
        XCTAssertEqual(WiFiHealth.interference(score: 4, utilization: 10).0, .excellent, "measured airtime wins over the scan estimate")
        XCTAssertEqual(WiFiHealth.expectedMax(phy: "802.11ax (Wi-Fi 6)", widthMHz: 80), 1201)
        XCTAssertEqual(WiFiHealth.expectedMax(phy: "802.11be (Wi-Fi 7)", widthMHz: 320), 5765)
        XCTAssertNil(WiFiHealth.expectedMax(phy: nil, widthMHz: 80))
    }

    func testLowRateReasons() {
        let weak = WiFiLinkPoint(time: Date(), rssi: -78, noise: -92, txRate: 39, channel: 6, band: .ghz2, widthMHz: 20, bssid: nil)
        let r = WiFiHealth.assess(weak, phy: "802.11n (Wi-Fi 4)", recommendation: nil)
        let all = r.rateReasons.joined(separator: " ")
        XCTAssertTrue(all.contains("signal is weak")); XCTAssertTrue(all.contains("SNR 14 dB")); XCTAssertTrue(all.contains("2.4 GHz"))
        XCTAssertTrue(all.contains("older standard"))
        XCTAssertEqual(r.items.map(\.aspect), ["Signal", "Signal to noise", "Interference", "Channel width"])
        let good = WiFiLinkPoint(time: Date(), rssi: -50, noise: -95, txRate: 1080, channel: 36, band: .ghz5, widthMHz: 80, bssid: nil)
        let g = WiFiHealth.assess(good, phy: "802.11ax (Wi-Fi 6)", recommendation: nil)
        XCTAssertTrue(g.rateReasons.isEmpty)
        XCTAssertTrue(g.rateSummary.contains("90% of the 1201 Mbps"), g.rateSummary)
    }
}
