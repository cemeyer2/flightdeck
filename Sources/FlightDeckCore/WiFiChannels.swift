import Foundation
// Wi-Fi channel arithmetic for the Wi-Fi analyzer: band, channel ↔ centre frequency, and the slice of spectrum a network
// of a given width really occupies. Everything congestion scoring does is done in MHz, because channel numbers are
// 5 MHz apart while channels are 20 MHz (or wider) across: a 2.4 GHz network on channel 6 also overlaps 4, 5, 7 and 8,
// and an 80 MHz 5 GHz network on primary channel 36 also occupies 40, 44 and 48.

/// The three Wi-Fi bands. The raw value is the label used everywhere else (`WiFiInfo.band`, UniFi radios).
public enum WiFiBand: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case ghz2 = "2.4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz"

    public static func < (a: WiFiBand, b: WiFiBand) -> Bool { a.order < b.order }
    private var order: Int { switch self { case .ghz2: 0; case .ghz5: 1; case .ghz6: 2 } }

    /// Parses the labels CoreWLAN-derived and UniFi data use ("2.4 GHz", "5 GHz", "6 GHz"); nil for anything else.
    public init?(label: String?) {
        guard let label else { return nil }
        if label.hasPrefix("2.4") { self = .ghz2 } else if label.hasPrefix("5") { self = .ghz5 } else if label.hasPrefix("6") { self = .ghz6 } else { return nil }
    }

    /// Centre frequency in MHz of a 20 MHz channel number in this band (IEEE 802.11 channel numbering), or nil when the
    /// number isn't a channel of the band.
    public func frequency(channel c: Int) -> Int? {
        switch self {
        case .ghz2: return c == 14 ? 2484 : (1...13).contains(c) ? 2407 + 5 * c : nil
        case .ghz5: return (32...177).contains(c) ? 5000 + 5 * c : nil
        // 6 GHz channels are 1, 5, 9 … 233 (4k+1); channel 2 is a special 20 MHz-only channel at 5935 MHz.
        case .ghz6: return c == 2 ? 5935 : (1...233).contains(c) && c % 4 == 1 ? 5950 + 5 * c : nil
        }
    }

    /// The channel number whose centre is `mhz` in this band (the inverse of `frequency`), used for centre channels of
    /// wide blocks, which aren't primary channels themselves (e.g. 42 for 36–48).
    public func channel(frequency mhz: Int) -> Int {
        switch self {
        case .ghz2: return mhz == 2484 ? 14 : (mhz - 2407) / 5
        case .ghz5: return (mhz - 5000) / 5
        case .ghz6: return (mhz - 5950) / 5
        }
    }

    /// The 20 MHz primary channels a network can use in this band, as drawn on the congestion chart. 5 GHz lists the
    /// channels used worldwide (US/EU superset); a given country allows a subset.
    public var channels: [Int] {
        switch self {
        case .ghz2: return Array(1...13)
        case .ghz5: return [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144, 149, 153, 157, 161, 165, 169, 173, 177]
        case .ghz6: return Array(stride(from: 1, through: 233, by: 4))
        }
    }

    /// Band from a frequency in MHz.
    public static func of(frequency f: Int) -> WiFiBand? {
        switch f {
        case 2400..<2500: .ghz2
        case 5150..<5925: .ghz5
        case 5925...7125: .ghz6
        default: nil
        }
    }
}

public enum WiFiChannels {
    /// 5 GHz channels 52–144 need radar detection (DFS): an AP may have to leave them at short notice, and some
    /// clients and APs don't support them at all. Recommendations say so.
    public static func isDFS(_ band: WiFiBand, _ channel: Int) -> Bool { band == .ghz5 && (52...144).contains(channel) }

    /// The centre channel of the standard `width`-MHz block that contains primary channel `primary`, or nil when the
    /// band has no such block (e.g. 80 MHz on 2.4 GHz, or channel 165 at 160 MHz in a country without 169–177).
    ///
    /// Blocks are aligned the way the standards define them: on 5 GHz from channel 36 (and again from 149, which isn't
    /// on the same 20 MHz grid offset), on 6 GHz from channel 1. A block of n 20 MHz channels is 4n channel numbers
    /// wide and its centre is 2n − 2 above its first channel: 80 MHz at 36 → 36–48, centre 42.
    /// 2.4 GHz 40 MHz has no grid: the secondary channel is 4 above or below the primary. Without the beacon's HT
    /// information that direction isn't known; the caller passes `secondaryAbove`, and the default follows the usual
    /// rule (channels 1–7 can only go up, 8–13 only down).
    /// 6 GHz 320 MHz has two overlapping grids (320-1 centred on 31, 63 …, 320-2 on 63, 127 …); without the beacon's
    /// EHT information this returns the 320-1 block.
    public static func centerChannel(band: WiFiBand, primary: Int, width: Int, secondaryAbove: Bool? = nil) -> Int? {
        let n = width / 20
        guard n >= 1, band.frequency(channel: primary) != nil else { return nil }
        if n == 1 { return primary }
        switch band {
        case .ghz2:
            guard width == 40 else { return nil }
            let up = secondaryAbove ?? (primary <= 7)
            let c = up ? primary + 2 : primary - 2
            return (3...11).contains(c) ? c : nil
        case .ghz5:
            guard width <= 160 else { return nil }
            let base = primary >= 149 ? 149 : 36
            let start = base + ((primary - base) / (4 * n)) * (4 * n)
            let end = start + 4 * (n - 1)
            // The whole block must exist: e.g. 144 at 80 MHz is fine (132–144), but 165 at 80 MHz needs 165–177.
            guard band.frequency(channel: end) != nil, (start...end).contains(primary) else { return nil }
            return start + 2 * n - 2
        case .ghz6:
            guard width <= 320 else { return nil }
            let start = 1 + ((primary - 1) / (4 * n)) * (4 * n)
            let end = start + 4 * (n - 1)
            guard end <= 233 else { return nil }
            return start + 2 * n - 2
        }
    }

    /// The frequency range in MHz a network occupies. `center` is the block's centre channel when the beacon said so;
    /// otherwise it is derived with `centerChannel`. A 2.4 GHz 20 MHz signal is really about 22 MHz wide, which is why
    /// channels 1, 6 and 11 are the only three that don't overlap; that extra width is included.
    /// nil when the channel isn't valid for the band.
    public static func span(band: WiFiBand, primary: Int, width: Int, center: Int? = nil) -> ClosedRange<Double>? {
        let w = max(width, 20)
        guard let c = center ?? centerChannel(band: band, primary: primary, width: w) ?? (w == 20 ? primary : nil),
              let f = centerFrequency(band: band, channel: c) else {
            // An unknown block (unusual width for the band): fall back to the primary 20 MHz channel only.
            guard let f = band.frequency(channel: primary) else { return nil }
            return Double(f) - 10 ... Double(f) + 10
        }
        let half = Double(w) / 2 + (band == .ghz2 && w == 20 ? 1 : 0)
        return Double(f) - half ... Double(f) + half
    }

    /// Like `WiFiBand.frequency`, but also for centre channels of wide blocks, which aren't on the primary grid
    /// (6 GHz centre 3, 7, 15 … are 4k+3 or 8k+7). 2.4 and 5 GHz centres use the same formula as primaries.
    public static func centerFrequency(band: WiFiBand, channel c: Int) -> Int? {
        switch band {
        case .ghz2: return band.frequency(channel: c)
        case .ghz5: return (32...177).contains(c) ? 5000 + 5 * c : nil
        case .ghz6: return (1...233).contains(c) ? 5950 + 5 * c : nil
        }
    }

    /// MHz of overlap between two ranges (0 when they don't touch).
    public static func overlap(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    /// The 20 MHz primary channels inside a block (e.g. 36, 40, 44, 48 for 80 MHz centred on 42).
    public static func members(band: WiFiBand, span: ClosedRange<Double>) -> [Int] {
        band.channels.filter { c in band.frequency(channel: c).map { span.contains(Double($0)) } ?? false }
    }

    /// Parses "80 MHz" (WiFiInfo's label) to 80.
    public static func widthMHz(_ label: String?) -> Int? {
        label.flatMap { Int($0.split(separator: " ").first ?? "") }
    }
}
