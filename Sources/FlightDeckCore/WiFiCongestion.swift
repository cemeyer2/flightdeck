import Foundation
// Channel congestion from one scan, and a plain-English channel recommendation. Only what this Mac hears from where
// it is: the access point may hear different neighbours, and a scan sees networks, not how busy they are. A loud
// neighbour that's idle costs nothing, so the scores are a hint of where contention is likely, not a measurement of
// airtime (a UniFi console's channel utilization is that measurement, and the page shows it when available).

/// How crowded one 20 MHz channel looks.
public struct WiFiChannelLoad: Sendable, Hashable, Identifiable {
    public var id: Int { channel }
    public var band: WiFiBand
    public var channel: Int
    /// Sum over neighbours of signal weight × overlap; about "one strong neighbour" per 1.0.
    public var score: Double
    /// Of `score`, the part from this Mac's own network (drawn highlighted).
    public var ownScore: Double
    /// Networks overlapping this channel, and how many of those are strong (≥ −70 dBm).
    public var networks: Int
    public var strong: Int
}

public struct WiFiRecommendation: Sendable, Hashable {
    public var band: WiFiBand
    public var channel: Int
    public var widthMHz: Int
    /// Other networks overlapping this network's channels at ≥ −70 dBm.
    public var strongNeighbours: Int
    public var currentScore: Double
    /// A clearer primary channel at the same width (20 MHz on 2.4 GHz), or nil when the current one is as good as any.
    public var suggestion: Int?
    public var suggestionScore: Double?
    public var suggestionIsDFS: Bool
    /// One or two sentences for the page and the MCP tool.
    public var text: String
}

public enum WiFiCongestion {
    /// Signals at or above this count as "strong neighbours" in text.
    public static let strongDBm = -70

    /// How much a neighbour matters by its signal: 1 at −55 dBm or louder, falling linearly to 0 at −90 dBm (below
    /// which other radios barely defer to it).
    public static func weight(rssi: Int) -> Double { min(1, max(0, Double(rssi + 90) / 35)) }

    /// The scan ids treated as this Mac's own network (excluded from "neighbours" and highlighted). With identifiers:
    /// `WiFiScanResult.isOwn`. Without them (no Location permission) it can only be inferred: the strongest network
    /// on this Mac's own channel whose signal is within 8 dB of the link's, plus that radio's other SSIDs. That is a
    /// guess, and callers say so.
    public static func ownIDs(_ scan: WiFiScanResult, linkRSSI: Int?) -> Set<Int> {
        let named = scan.networks.filter(scan.isOwn).map(\.id)
        if !named.isEmpty || !scan.identifiersHidden { return Set(named) }
        guard let ch = scan.ownChannel, let band = scan.ownBand, let r = linkRSSI else { return [] }
        let guess = scan.networks.filter { $0.band == band && $0.channel == ch && abs($0.rssi - r) <= 8 }.max { $0.rssi < $1.rssi }
        guard let g = guess else { return [] }
        // An AP's extra SSIDs (guest, OWE transition) come from the same radio: same channel and width, and the same
        // signal to within a dB. Those are counted as ours too rather than as loud neighbours.
        return Set(scan.networks.filter { $0.band == band && $0.channel == ch && $0.widthMHz == g.widthMHz && abs($0.rssi - g.rssi) <= 1 }.map(\.id))
    }

    /// Fraction of the narrower of the two ranges that overlaps the other: a 20 MHz neighbour wholly inside an
    /// 80 MHz block counts fully (they collide whenever both transmit), as does an 80 MHz neighbour covering a 20 MHz
    /// channel.
    static func share(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
        let narrower = min(a.upperBound - a.lowerBound, b.upperBound - b.lowerBound)
        return narrower > 0 ? WiFiChannels.overlap(a, b) / narrower : 0
    }

    /// Load on every 20 MHz channel of `band`.
    public static func loads(_ scan: WiFiScanResult, band: WiFiBand, own: Set<Int>) -> [WiFiChannelLoad] {
        let nets = scan.networks.filter { $0.band == band }.compactMap { n in n.span.map { (n, $0) } }
        return band.channels.compactMap { c in
            guard let f = band.frequency(channel: c) else { return nil }
            // The channel itself is 20 MHz wide (22 on 2.4 GHz, as in `WiFiChannels.span`).
            let half = band == .ghz2 ? 11.0 : 10.0
            let ch = Double(f) - half ... Double(f) + half
            var load = WiFiChannelLoad(band: band, channel: c, score: 0, ownScore: 0, networks: 0, strong: 0)
            for (n, s) in nets {
                let k = share(s, ch)
                guard k > 0.05 else { continue }   // a sliver of a 2.4 GHz skirt isn't "on" the channel
                let v = weight(rssi: n.rssi) * k
                load.score += v; load.networks += 1
                if own.contains(n.id) { load.ownScore += v } else if n.rssi >= strongDBm { load.strong += 1 }
            }
            return load
        }
    }

    /// Neighbour score for a block (excluding this Mac's own network).
    static func blockScore(_ block: ClosedRange<Double>, _ nets: [(WiFiNetwork, ClosedRange<Double>)], own: Set<Int>) -> (score: Double, strong: Int) {
        var score = 0.0, strong = 0
        for (n, s) in nets where !own.contains(n.id) {
            let k = share(s, block)
            guard k > 0.05 else { continue }
            score += weight(rssi: n.rssi) * k
            if n.rssi >= strongDBm { strong += 1 }
        }
        return (score, strong)
    }

    /// Candidate primary channels at `width`: on 2.4 GHz only 1, 6 and 11 (the non-overlapping ones; 40 MHz there
    /// overlaps everything); elsewhere the first channel of each valid block. 5 GHz 169–177 is left out (allowed in
    /// few countries) unless the network is already there.
    static func candidates(_ band: WiFiBand, width: Int, current: Int) -> [Int] {
        switch band {
        case .ghz2: return [1, 6, 11]
        case .ghz5, .ghz6:
            return band.channels.filter { c in
                guard band != .ghz5 || c < 169 || c == current else { return false }
                guard let center = WiFiChannels.centerChannel(band: band, primary: c, width: width),
                      let span = WiFiChannels.span(band: band, primary: c, width: width, center: center) else { return false }
                // One candidate per block: its lowest channel. Blocks reaching into 169–177 count as that range too.
                let members = WiFiChannels.members(band: band, span: span)
                if band == .ghz5, members.contains(where: { $0 >= 169 }), !members.contains(current) { return false }
                return members.first == c
            }
        }
    }

    /// The recommendation for this Mac's network, or nil without a scan entry to judge (not on Wi-Fi, or its channel
    /// unknown). `widthMHz` is the link's width (from CoreWLAN; the scan entry's is used when the beacon said more).
    public static func recommend(_ scan: WiFiScanResult, band: WiFiBand, channel: Int, widthMHz: Int?, linkRSSI: Int?) -> WiFiRecommendation? {
        let own = ownIDs(scan, linkRSSI: linkRSSI)
        let mine = scan.networks.first { own.contains($0.id) && $0.channel == channel }
        let width = band == .ghz2 ? 20 : (mine?.widthMHz ?? widthMHz ?? 20)
        let nets = scan.networks.filter { $0.band == band }.compactMap { n in n.span.map { (n, $0) } }
        guard let curSpan = mine?.span ?? WiFiChannels.span(band: band, primary: channel, width: width) else { return nil }
        let cur = blockScore(curSpan, nets, own: own)
        // DFS channels get a small handicap: a radar event forces the AP off them, and some devices can't use them.
        var best: (ch: Int, score: Double, dfs: Bool)?
        for c in candidates(band, width: width, current: channel) {
            guard let s = WiFiChannels.span(band: band, primary: c, width: width) else { continue }
            let dfs = WiFiChannels.isDFS(band, c)
            let score = blockScore(s, nets, own: own).score
            if best == nil || score + (dfs ? 0.3 : 0) < best!.score + (best!.dfs ? 0.3 : 0) { best = (c, score, dfs) }
        }
        // Only suggest a move that clearly helps: at least ~one strong neighbour fewer and well under the current load.
        let worthIt = best.map { b in !curSpan.contains(Double(band.frequency(channel: b.ch) ?? 0)) && b.score + 0.75 <= cur.score && b.score <= cur.score * 0.6 } ?? false
        let widthText = band == .ghz2 ? "" : " (\(width) MHz)"
        let neighbours = cur.strong == 0 ? "no strong neighbours" : "\(cur.strong) strong neighbour\(cur.strong == 1 ? "" : "s")"
        var text = "Your network is on \(band.rawValue) channel \(channel)\(widthText) with \(neighbours) overlapping it"
        if worthIt, let b = best {
            text += "; channel \(b.ch) looks clearer" + (b.dfs ? " (a DFS channel: the router must support it and may have to leave it if it detects radar)" : "") + "."
        } else if cur.strong == 0 {
            text += ". That looks good."
        } else {
            text += "; no other channel looks clearly better."
        }
        if band == .ghz2 && (mine?.widthMHz ?? widthMHz ?? 20) > 20 {
            text += " It uses 40 MHz on 2.4 GHz, which overlaps most of the band; 20 MHz is usually better there."
        }
        text += " This is only what this Mac hears from where it is now; your router may hear different neighbours."
        if scan.identifiersHidden { text += " Network names are hidden, so your own access point was identified by its channel and signal." }
        return WiFiRecommendation(band: band, channel: channel, widthMHz: width, strongNeighbours: cur.strong, currentScore: cur.score,
                                  suggestion: worthIt ? best?.ch : nil, suggestionScore: worthIt ? best?.score : nil,
                                  suggestionIsDFS: worthIt ? (best?.dfs ?? false) : false, text: text)
    }
}
