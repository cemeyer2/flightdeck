import Foundation
// Plain-English health of the Wi-Fi link: signal, signal-to-noise, interference and channel width each rated, and the
// likely reasons a link rate is low. The thresholds are the usual rules of thumb (e.g. around −67 dBm is the floor for
// reliable calls and video); they describe what's typical, not a guarantee.

public enum WiFiRating: String, Sendable, Hashable, Codable {
    case excellent = "Excellent", good = "Good", fair = "Fair", poor = "Poor", unknown = "Unknown"
}

public struct WiFiHealthItem: Sendable, Hashable, Identifiable {
    public var id: String { aspect }
    public var aspect: String
    public var rating: WiFiRating
    /// The reading behind the rating ("−58 dBm"), or why it's unknown.
    public var value: String
    public var detail: String
}

public struct WiFiHealthReport: Sendable, Hashable {
    public var items: [WiFiHealthItem]
    /// Theoretical top PHY rate for this standard and width with two spatial streams, in Mbps; nil if unknown.
    public var expectedMaxMbps: Double?
    /// One line about the link rate (how it compares with the maximum).
    public var rateSummary: String
    /// Likely reasons the rate is lower than it could be; empty when it looks fine.
    public var rateReasons: [String]
}

public enum WiFiHealth {
    public static func signal(_ rssi: Int) -> WiFiRating {
        switch rssi { case (-55)...: .excellent; case (-67)...: .good; case (-75)...: .fair; default: .poor }
    }

    /// SNR in dB: above ~40 the link can use its fastest rates, below ~15 it struggles.
    public static func snr(_ snr: Int) -> WiFiRating {
        switch snr { case 40...: .excellent; case 25...: .good; case 15...: .fair; default: .poor }
    }

    /// Interference from the neighbour score of the channel (`WiFiRecommendation.currentScore`, about one strong
    /// neighbour per 1.0), or better, the access point's own measured channel utilization (% busy airtime).
    public static func interference(score: Double?, utilization: Double?) -> (WiFiRating, String, String) {
        if let u = utilization {
            let r: WiFiRating = u < 25 ? .excellent : u < 45 ? .good : u < 65 ? .fair : .poor
            return (r, String(format: "%.0f%% busy", u), "Channel utilization measured by your access point (UniFi): the share of time the channel is busy.")
        }
        guard let s = score else { return (.unknown, "no scan yet", "Press Scan to see which networks share your channel.") }
        let r: WiFiRating = s < 0.5 ? .excellent : s < 1.5 ? .good : s < 3 ? .fair : .poor
        return (r, String(format: "score %.1f", s), "Estimated from the neighbours this Mac heard on your channels, weighted by their signal. It can't tell how busy they are.")
    }

    public static func width(_ mhz: Int?, band: WiFiBand?) -> (WiFiRating, String) {
        guard let mhz, let band else { return (.unknown, "CoreWLAN didn't report the channel width.") }
        switch (band, mhz) {
        case (.ghz2, 20): return (.good, "20 MHz is the right width on 2.4 GHz.")
        case (.ghz2, _): return (.fair, "\(mhz) MHz on 2.4 GHz overlaps most of the band and neighbours; 20 MHz is usually better there.")
        case (.ghz5, 20): return (.poor, "20 MHz limits speed to about a quarter of 80 MHz.")
        case (.ghz5, 40): return (.fair, "40 MHz gives about half the speed of 80 MHz.")
        case (.ghz5, 80): return (.excellent, "80 MHz is the usual best balance of speed and interference on 5 GHz.")
        case (.ghz5, _): return (.excellent, "\(mhz) MHz is the fastest, but it is more exposed to interference and usually needs DFS channels.")
        case (.ghz6, 20), (.ghz6, 40): return (.fair, "\(mhz) MHz is narrow for 6 GHz, which has room for 160 MHz or more.")
        case (.ghz6, 80): return (.good, "80 MHz; 6 GHz has room for 160 MHz if the router supports it.")
        case (.ghz6, _): return (.excellent, "\(mhz) MHz: the widest channels, possible because 6 GHz is uncrowded.")
        }
    }

    /// Top PHY rate (Mbps) for two spatial streams at the top modulation, which is what most Macs have. nil when the
    /// standard or width is unknown.
    public static func expectedMax(phy: String?, widthMHz: Int?) -> Double? {
        guard let phy, let w = widthMHz else { return nil }
        let table: [(String, [Int: Double])] = [
            ("802.11be", [20: 344, 40: 688, 80: 1441, 160: 2882, 320: 5765]),
            ("802.11ax", [20: 287, 40: 574, 80: 1201, 160: 2402]),
            ("802.11ac", [20: 173, 40: 400, 80: 867, 160: 1733]),
            ("802.11n", [20: 144, 40: 300]),
            ("802.11a", [20: 54]), ("802.11g", [20: 54]), ("802.11b", [20: 11]),
        ]
        return table.first { phy.hasPrefix($0.0) }?.1[w]
    }

    public static func assess(_ link: WiFiLinkPoint, phy: String?, recommendation: WiFiRecommendation?, utilization: Double? = nil) -> WiFiHealthReport {
        let snrDB = link.snr
        let (ir, iv, id) = interference(score: recommendation?.currentScore, utilization: utilization)
        let (wr, wd) = width(link.widthMHz, band: link.band)
        let items = [
            WiFiHealthItem(aspect: "Signal", rating: signal(link.rssi), value: "\(link.rssi) dBm",
                           detail: "−67 dBm or better is what calls and video need; every 3 dB weaker halves the power received."),
            WiFiHealthItem(aspect: "Signal to noise", rating: snr(snrDB), value: "\(snrDB) dB",
                           detail: "How far the signal stands above the background noise (\(link.noise) dBm). The fastest rates need about 30–40 dB."),
            WiFiHealthItem(aspect: "Interference", rating: ir, value: iv, detail: id),
            WiFiHealthItem(aspect: "Channel width", rating: wr, value: link.widthMHz.map { "\($0) MHz" } ?? "unknown", detail: wd),
        ]
        let maxRate = expectedMax(phy: phy, widthMHz: link.widthMHz)
        var reasons: [String] = []
        // "Low" is under half the maximum. With the maximum unknown, the factors that always cost speed are still listed.
        let low = maxRate.map { link.txRate < $0 * 0.5 } ?? true
        if link.txRate <= 0 {
            reasons.append("No transmit rate is reported right now; the link may be idle or just reconnected.")
        } else if low {
            if link.rssi < -67 { reasons.append("The signal is weak (\(link.rssi) dBm), so Wi-Fi drops to slower, sturdier rates. Moving closer to the access point, or adding one, helps most.") }
            if snrDB < 25 { reasons.append("Noise is high relative to the signal (SNR \(snrDB) dB); interference from other radios, microwaves or USB 3 devices near the Mac can cause this.") }
            if link.band == .ghz2 { reasons.append("The Mac is on 2.4 GHz, which is narrower and more crowded. 5 or 6 GHz is faster where its signal reaches.") }
            if let w = link.widthMHz, w <= 40, link.band != .ghz2 { reasons.append("The channel is only \(w) MHz wide; the router may be set to a narrow width, or it narrowed it because of neighbours.") }
            if let p = phy, p.hasPrefix("802.11n") || p.hasPrefix("802.11a") || p.hasPrefix("802.11g") || p.hasPrefix("802.11b") {
                reasons.append("The link uses \(p), an older standard; a newer router (or its newer band) would be faster.")
            }
            if let r = recommendation, r.strongNeighbours >= 3 { reasons.append("\(r.strongNeighbours) strong networks overlap your channel, so the airtime is shared.") }
            if reasons.isEmpty && maxRate != nil { reasons.append("Nothing obvious from this Mac's side: the link may be lightly used (the rate falls when idle), or the router may be limiting it.") }
        }
        let rateText = String(format: "%.0f Mbps", link.txRate)
        let summary: String
        if let m = maxRate, link.txRate > 0 {
            summary = "Link rate \(rateText) is about \(Int((link.txRate / m * 100).rounded()))% of the \(Int(m)) Mbps maximum for \(phy ?? "this standard") at \(link.widthMHz ?? 0) MHz (assuming two spatial streams, as most Macs have). macOS reports the rate of recent traffic, so it reads low while the link is idle."
        } else {
            summary = "Link rate \(rateText). The maximum isn't known because the standard or channel width wasn't reported."
        }
        return WiFiHealthReport(items: items, expectedMaxMbps: maxRate, rateSummary: summary, rateReasons: reasons)
    }
}
