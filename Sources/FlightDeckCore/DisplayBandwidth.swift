import Foundation
// Video bandwidth arithmetic behind the Displays page's diagnoses: what a mode needs (pixel clock × bits per pixel)
// against what a DisplayPort link or an HDMI version can carry. Figures follow the VESA CVT reduced-blanking v2
// timing formula, DisplayPort's line codes (8b/10b up to HBR3, 128b/132b for UHBR) and HDMI's TMDS clock limits
// (340 MHz for 1.4, 600 MHz for 2.0) and FRL rate (48 Gbit/s for 2.1). Overheads such as FEC, MST and audio are
// ignored, so a mode that "fits" by a few percent may still not be offered.

public enum DisplayBandwidth {
    /// DisplayPort per-lane rates (Gbit/s) and their names.
    public static let dpRates: [(gbps: Double, name: String)] = [
        (1.62, "RBR"), (2.7, "HBR"), (5.4, "HBR2"), (8.1, "HBR3"), (10, "UHBR10"), (13.5, "UHBR13.5"), (20, "UHBR20"),
    ]

    /// Payload Gbit/s of a DisplayPort link: 8b/10b (80%) up to HBR3, 128b/132b (~97%) for UHBR rates.
    public static func dpPayloadGbps(laneGbps: Double, lanes: Int) -> Double {
        let efficiency = laneGbps > 8.2 ? 128.0 / 132.0 : 0.8
        return laneGbps * Double(lanes) * efficiency
    }

    /// Pixel clock (Hz) for a mode without known blanking, by CVT reduced blanking v2: 80 pixels of horizontal
    /// blanking and at least 460 µs of vertical blanking per frame.
    public static func cvtRB2PixelClock(width: Int, height: Int, refreshHz: Double) -> Double {
        guard width > 0, height > 0, refreshHz > 0 else { return 0 }
        let frame = 1 / refreshHz
        let linePeriod = (frame - 460e-6) / Double(height)
        guard linePeriod > 0 else { return 0 }
        let vBlank = max((460e-6 / linePeriod).rounded(.up), 14)
        let vTotal = Double(height) + vBlank
        return Double(width + 80) * vTotal * refreshHz
    }

    /// Uncompressed data rate in Gbit/s for a pixel clock, bit depth and chroma.
    public static func requiredGbps(pixelClockHz: Double, depth: Int, chroma: DisplayChroma) -> Double {
        pixelClockHz * Double(depth) * chroma.componentsPerPixel / 1e9
    }

    /// Data rate with Display Stream Compression at a typical 12 bits per pixel (visually lossless target).
    public static func dscGbps(pixelClockHz: Double, bitsPerPixel: Double = 12) -> Double { pixelClockHz * bitsPerPixel / 1e9 }

    /// Decodes the transport node's LinkRate / LinkRateDescription into a per-lane rate and name. The description
    /// is preferred ("HBR3", "UHBR10", "8.1 Gbps"); a numeric value is read as a DPCD link-rate code (0x06, 0x0A,
    /// 0x14, 0x1E; 0x01/0x04/0x02 for UHBR10/13.5/20), as Mbit/s (1620…20000) or as kbit/s (162000…). Nil when
    /// neither can be read; 0 or "No Link" means no trained link.
    public static func decodeLinkRate(raw: Int?, description: String?) -> (gbps: Double, name: String)? {
        if let d = description?.uppercased().replacingOccurrences(of: " ", with: "") {
            for r in dpRates.reversed() where d.contains(r.name.uppercased()) { return r }
            if let n = Double(d.prefix { "0123456789.".contains($0) }), d.contains("GB"), n > 0 { return named(n) }
        }
        guard let v = raw, v > 0 else { return nil }
        switch v {
        case 0x06: return named(1.62)
        case 0x0A: return named(2.7)
        case 0x14: return named(5.4)
        case 0x1E: return named(8.1)
        case 0x01: return named(10)
        case 0x04: return named(13.5)
        case 0x02: return named(20)
        case 1_000...20_000: return named(Double(v) / 1000)
        case 100_000...2_000_000: return named(Double(v) / 100_000)
        default: return nil
        }
    }

    /// The rate with its DisplayPort name when it is a standard one (within 1%).
    static func named(_ gbps: Double) -> (gbps: Double, name: String) {
        dpRates.first { abs($0.gbps - gbps) / $0.gbps < 0.01 } ?? (gbps, String(format: "%.2f Gbit/s", gbps))
    }

    // MARK: HDMI

    public enum HDMIVersion: String, Codable, Sendable, CaseIterable {
        case v1_4 = "HDMI 1.4", v2_0 = "HDMI 2.0", v2_1 = "HDMI 2.1"
        /// Highest TMDS character rate (Hz); 2.1's FRL modes are checked by data rate instead.
        public var maxTMDSHz: Double { switch self { case .v1_4: 340e6; case .v2_0, .v2_1: 600e6 } }
        /// Payload capacity in Gbit/s (TMDS: 3 channels × 8 bits per character; FRL: 48 Gbit/s at 16b/18b).
        public var payloadGbps: Double { self == .v2_1 ? 48 * 16 / 18 : maxTMDSHz * 24 / 1e9 }
    }

    /// TMDS character rate needed for a mode. Deep colour raises it for RGB/4:4:4; 4:2:2 is carried at the 8-bit
    /// rate up to 12 bits; 4:2:0 halves it.
    public static func tmdsHz(pixelClockHz: Double, depth: Int, chroma: DisplayChroma) -> Double {
        let deep = Double(max(depth, 8)) / 8
        switch chroma {
        case .rgb, .ycbcr444: return pixelClockHz * deep
        case .ycbcr422: return pixelClockHz
        case .ycbcr420: return pixelClockHz / 2 * deep
        }
    }

    /// Whether a mode fits an HDMI version.
    public static func hdmiFits(pixelClockHz: Double, depth: Int, chroma: DisplayChroma, version: HDMIVersion) -> Bool {
        if version == .v2_1 { return requiredGbps(pixelClockHz: pixelClockHz, depth: depth, chroma: chroma) <= version.payloadGbps }
        return tmdsHz(pixelClockHz: pixelClockHz, depth: depth, chroma: chroma) <= version.maxTMDSHz * 1.005
    }

    /// The oldest HDMI version that carries a mode, or nil if even 2.1 can't (without DSC).
    public static func minimumHDMI(pixelClockHz: Double, depth: Int, chroma: DisplayChroma) -> HDMIVersion? {
        HDMIVersion.allCases.first { hdmiFits(pixelClockHz: pixelClockHz, depth: depth, chroma: chroma, version: $0) }
    }

    /// Pixel clock of a mode as the CTA-861 standard timing when it is a common TV format (what HDMI sinks
    /// usually advertise), else by CVT-RB2. 4K (3840×2160) uses 4400×2250 totals, 1080p 2200×1125.
    public static func typicalPixelClock(width: Int, height: Int, refreshHz: Double) -> Double {
        switch (width, height) {
        case (3840, 2160), (4096, 2160): return 4400 * 2250 * refreshHz
        case (1920, 1080): return 2200 * 1125 * refreshHz
        case (1280, 720): return 1650 * 750 * refreshHz
        default: return cvtRB2PixelClock(width: width, height: height, refreshHz: refreshHz)
        }
    }

    // MARK: Formats

    /// The richest uncompressed formats, best first, used to say which one a link could carry.
    public static let formats: [(depth: Int, chroma: DisplayChroma)] = [
        (10, .rgb), (8, .rgb), (10, .ycbcr422), (8, .ycbcr422), (8, .ycbcr420),
    ]

    /// The best format of `formats` that fits `capacityGbps` at this pixel clock.
    public static func bestFormat(pixelClockHz: Double, capacityGbps: Double) -> (depth: Int, chroma: DisplayChroma)? {
        formats.first { requiredGbps(pixelClockHz: pixelClockHz, depth: $0.depth, chroma: $0.chroma) <= capacityGbps }
    }
}
