import Foundation
// Output of the read-only `wifi` MCP tool: the current Wi-Fi link with its health ratings, and a summary of the last
// scan the user ran on the Wi-Fi page. The tool never scans (a scan disrupts Wi-Fi briefly); the standalone CLI has no
// scans at all. Network names and BSSIDs appear only when FlightDeck has Location Services permission, which is also
// the only time macOS provides them; BSSIDs are additionally dropped whenever permission isn't granted.

extension MCPTools {
    func wifi() async throws -> JSON {
        guard let s = await source.snapshot() else { throw noSample() }
        let permission = await source.wifiPermission()
        let showIDs = permission == .granted
        let scan = await source.wifiScan()
        let link: JSON
        var rec: WiFiRecommendation?
        if let w = s.wifi {
            let p = WiFiLinkPoint(w, time: s.time)
            if let scan, let band = p.band, let ch = p.channel {
                rec = WiFiCongestion.recommend(scan, band: band, channel: ch, widthMHz: p.widthMHz, linkRSSI: p.rssi)
            }
            let health = WiFiHealth.assess(p, phy: w.phy, recommendation: rec)
            link = .object(dropping: [
                ("interface", .str(w.interface)),
                ("ssid", w.ssid.map(JSON.str) ?? F.unavailable("needs Location Services permission")),
                ("bssid", showIDs ? w.bssid.map(JSON.str) : nil),
                ("rssi_dbm", .int(w.rssi)), ("noise_dbm", .int(w.noise)), ("snr_db", .int(w.snr)),
                ("tx_rate_mbps", F.r1(w.txRate)), ("expected_max_mbps", health.expectedMaxMbps.map(F.r1)),
                ("band", w.band.map(JSON.str)), ("channel", w.channel.map(JSON.int)), ("width", w.width.map(JSON.str)),
                ("phy", w.phy.map(JSON.str)), ("security", w.security.map(JSON.str)),
                ("health", .array(health.items.map { i in ["aspect": .str(i.aspect), "rating": .str(i.rating.rawValue), "value": .str(i.value)] })),
                ("rate", .str(health.rateSummary)),
                ("rate_reasons", health.rateReasons.isEmpty ? nil : .strings(health.rateReasons)),
            ])
        } else {
            link = .str("Not connected to Wi-Fi (or Wi-Fi is off).")
        }

        let scanJSON: JSON
        if let scan {
            let own = WiFiCongestion.ownIDs(scan, linkRSSI: s.wifi?.rssi)
            let byBand: [(String, JSON)] = WiFiBand.allCases.map { b in
                let nets = scan.networks.filter { $0.band == b }
                let busiest = WiFiCongestion.loads(scan, band: b, own: own).filter { $0.score > 0 }.sorted { $0.score > $1.score }.prefix(3)
                return (b.rawValue, ["networks": .int(nets.count), "strong": .int(nets.filter { $0.rssi >= WiFiCongestion.strongDBm }.count),
                                     "busiest_channels": .array(busiest.map { ["channel": .int($0.channel), "score": F.r1($0.score)] })])
            }
            let strongest: [JSON] = scan.networks.prefix(15).map { n in
                .object(dropping: [
                    ("ssid", n.ssid.map(JSON.str) ?? (scan.identifiersHidden ? .str("hidden (no Location permission)") : .str("hidden network"))),
                    ("bssid", showIDs ? n.bssid.map(JSON.str) : nil),
                    ("vendor", showIDs ? n.vendor.name.map(JSON.str) : nil),
                    ("yours", own.contains(n.id) ? .bool(true) : nil),
                    ("rssi_dbm", .int(n.rssi)), ("band", n.band.map { .str($0.rawValue) }), ("channel", n.channel.map(JSON.int)),
                    ("width_mhz", n.widthMHz.map(JSON.int)), ("security", n.security.map(JSON.str)), ("phy", n.phy.map(JSON.str)),
                ])
            }
            scanJSON = .object(dropping: [
                ("time", F.time(scan.time)), ("networks", .int(scan.networks.count)),
                ("names_hidden", scan.identifiersHidden ? .bool(true) : nil),
                ("by_band", .object(byBand)),
                ("recommendation", rec.map { .str($0.text) }),
                ("strongest", .array(strongest)),
            ])
        } else {
            scanJSON = .str(source.standalone
                ? "No scan: scans run only from the FlightDeck app's Wi-Fi page (a scan briefly disrupts Wi-Fi, so this tool never starts one)."
                : "No scan yet: press Scan on FlightDeck's Wi-Fi page. This tool never starts one, since a scan briefly disrupts Wi-Fi.")
        }
        return object([
            ("location_permission", .str(permission.rawValue)),
            ("link", link),
            ("last_scan", scanJSON),
            ("note", "Scans are what this Mac hears from where it is; they're kept in memory only."),
        ])
    }
}
