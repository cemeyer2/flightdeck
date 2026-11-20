import Foundation
// Plain-English diagnoses for one display: a refresh rate held below 60 Hz (and why: a mode not chosen, an HDMI 1.4
// input or adapter, a DisplayPort link with too few lanes or too low a rate), subsampled chroma or low bit depth for
// lack of bandwidth, DSC in use, HiDPI not offered, a scaled resolution, ProMotion turned off and virtual displays.
// Bandwidth claims are backed by DisplayBandwidth's numbers, which are quoted in the text.

public enum DisplayDiagnostics {
    public static func diagnose(_ d: DisplayFacts) -> [DisplayDiagnosis] {
        var out: [DisplayDiagnosis] = []
        if let x = lowRefresh(d) { out.append(x) }
        if let x = chroma(d) { out.append(x) }
        if let x = bitDepth(d) { out.append(x) }
        if let x = dsc(d) { out.append(x) }
        if let x = hiDPI(d) { out.append(x) }
        if let x = scaled(d) { out.append(x) }
        if let x = proMotion(d) { out.append(x) }
        if d.transport == .virtual {
            out.append(.init(id: "virtual", severity: .info, title: "Virtual or streamed display",
                             detail: "macOS drives this display through software (AirPlay, Sidecar or a DisplayLink driver), so there is no video link to inspect. Streamed displays are compressed and add latency.",
                             advice: "For full quality and low latency, connect the display by USB-C, Thunderbolt, DisplayPort or HDMI."))
        }
        return out.sorted { $0.severity > $1.severity }
    }

    /// Pixel size of the signal sent to the display: the timing in use, else CoreGraphics' current mode.
    static func signalSize(_ d: DisplayFacts) -> (w: Int, h: Int)? {
        if let t = d.framebuffer?.currentTiming { return (t.width, t.height) }
        return d.mode.map { ($0.pixelWidth, $0.pixelHeight) }
    }
    static func currentRefresh(_ d: DisplayFacts) -> Double? {
        if let r = d.mode?.refreshHz, r > 0 { return r }
        return d.framebuffer?.currentTiming?.refreshHz
    }
    /// Whether the signal goes to an HDMI input (this Mac's HDMI port, or an HDMI sink behind an adapter).
    static func hdmiPath(_ d: DisplayFacts) -> Bool { d.transport == .hdmi || d.edid?.hdmiSink == true }

    // MARK: Refresh

    static func lowRefresh(_ d: DisplayFacts) -> DisplayDiagnosis? {
        guard !d.builtIn, d.transport != .virtual, let hz = currentRefresh(d), hz < 48, let size = signalSize(d),
              size.w * size.h >= 2560 * 1440 else { return nil }
        let now = "\(size.w) × \(size.h) at \(DisplayFormat.hz(hz))"
        if let best = d.bestRefreshAtCurrentSize, best >= 59 {
            return .init(id: "refresh", severity: .caution, title: "Running at \(DisplayFormat.hz(hz)) though \(DisplayFormat.hz(best)) is offered",
                         detail: "The display is at \(now); the connection offers \(DisplayFormat.hz(best)) at this resolution, so this was chosen in settings rather than forced by the link.",
                         advice: "System Settings › Displays › Refresh Rate: choose \(DisplayFormat.hz(best)).")
        }
        let pclk = DisplayBandwidth.typicalPixelClock(width: size.w, height: size.h, refreshHz: 60)
        let need = DisplayBandwidth.requiredGbps(pixelClockHz: pclk, depth: 8, chroma: .rgb)
        if hdmiPath(d) { return hdmiRefresh(d, now: now, hz: hz, size: size, pclk: pclk) }
        if let link = d.link, let cap = link.capacityGbps, need > cap {
            return linkRefresh(link, now: now, hz: hz, capacity: cap, need: need)
        }
        return .init(id: "refresh", severity: .warning, title: "Running at \(DisplayFormat.hz(hz)): 60 Hz isn't offered at this resolution",
                     detail: "The display is at \(now) and the connection offers nothing faster at this size. 60 Hz needs about \(DisplayFormat.gbps(need)) (8-bit RGB), more than the cable, adapter, dock or the display's input is offering\(d.link?.capacityGbps.map { "; the link itself reports \(DisplayFormat.gbps($0))" } ?? "").",
                     advice: "Connect directly with a USB-C to DisplayPort cable or a Thunderbolt cable rated for 4K 60 Hz, and check the display's input settings (DisplayPort 1.2+ / HDMI 2.0 mode).")
    }

    static func hdmiRefresh(_ d: DisplayFacts, now: String, hz: Double, size: (w: Int, h: Int), pclk: Double) -> DisplayDiagnosis {
        let needed = DisplayBandwidth.minimumHDMI(pixelClockHz: pclk, depth: 8, chroma: .rgb) ?? .v2_1
        let tmds = DisplayFormat.mhz(DisplayBandwidth.tmdsHz(pixelClockHz: pclk, depth: 8, chroma: .rgb))
        let reported = d.edid?.hdmiVersion
        let input = reported.map { v in
            "The display's HDMI input reports \(v.rawValue)" + (d.edid?.maxTMDSHz.map { " (at most \(DisplayFormat.mhz($0)))" } ?? "") + ". "
        } ?? ""
        let via = d.transport == .hdmi ? "the HDMI link" : "the HDMI adapter or input"
        let detail = input + "\(size.w) × \(size.h) at 60 Hz needs a \(tmds) TMDS clock (\(needed.rawValue)); HDMI 1.4 tops out at 340 MHz, which carries this resolution only at 30 Hz. The display is at \(now)."
        let advice = "Use DisplayPort or USB-C (a USB-C to DisplayPort cable) if the display has it, or an \(needed.rawValue) (\"4K 60 Hz\") cable and adapter, and set the display's HDMI input to \(needed.rawValue) / \"Enhanced\" mode in its own menu."
        return .init(id: "refresh", severity: .warning, title: "Running at \(DisplayFormat.hz(hz)): \(via) can't carry \(size.w) × \(size.h) at 60 Hz",
                     detail: detail, advice: advice)
    }

    static func linkRefresh(_ link: DisplayLink, now: String, hz: Double, capacity: Double, need: Double) -> DisplayDiagnosis {
        let lanes = link.lanes ?? 0, max = link.maxLanes ?? 4
        let advice = lanes > 0 && lanes < max
            ? "Only \(lanes) of \(max) DisplayPort lanes are in use: USB-C hubs and docks often keep 2 lanes for USB 3 data. Use a direct USB-C to DisplayPort cable, a Thunderbolt dock, or a dock setting that favours video."
            : "The link trained at a low rate: try a shorter, certified cable (DP8K or Thunderbolt 4) and avoid passive adapters in between."
        return .init(id: "refresh", severity: .warning, title: "Running at \(DisplayFormat.hz(hz)): the DisplayPort link is too slow for 60 Hz",
                     detail: "The display is at \(now). The link trained at \(link.summary); 60 Hz at this resolution needs about \(DisplayFormat.gbps(need)) uncompressed (8-bit RGB).",
                     advice: advice)
    }

    // MARK: Colour

    static func chroma(_ d: DisplayFacts) -> DisplayDiagnosis? {
        guard let c = d.framebuffer?.activeColor, let ch = c.chroma, ch.subsampled else { return nil }
        let depth = c.depth ?? 8
        var why = ""
        if let t = d.framebuffer?.currentTiming {
            let rgb = DisplayBandwidth.requiredGbps(pixelClockHz: t.pixelClockHz, depth: depth, chroma: .rgb)
            if let cap = d.link?.capacityGbps, rgb > cap {
                why = " RGB at this mode would need \(DisplayFormat.gbps(rgb)) and the link carries \(DisplayFormat.gbps(cap)): link bandwidth limited."
            } else if hdmiPath(d) {
                let tmds = DisplayBandwidth.tmdsHz(pixelClockHz: t.pixelClockHz, depth: depth, chroma: .rgb)
                why = " RGB at this mode would need a \(DisplayFormat.mhz(tmds)) TMDS clock, more than HDMI 1.4's 340 MHz\(tmds > 600e6 ? " and HDMI 2.0's 600 MHz" : ""): link bandwidth limited."
            }
        }
        return .init(id: "chroma", severity: .caution, title: "\(depth)-bit colour with \(ch.rawValue) chroma",
                     detail: "Colour detail is sent at reduced resolution, so small coloured text and thin lines can look fringed or blurry." + why,
                     advice: "Lower the refresh rate or resolution one step, or use a faster connection (DisplayPort / USB-C / Thunderbolt, or HDMI 2.0+), to get full RGB.")
    }

    static func bitDepth(_ d: DisplayFacts) -> DisplayDiagnosis? {
        guard !d.builtIn, let c = d.framebuffer?.activeColor, let depth = c.depth else { return nil }
        if depth < 8 {
            return .init(id: "depth", severity: .caution, title: "\(depth)-bit colour",
                         detail: "Fewer than 8 bits per colour: gradients can band. This usually means the link is short of bandwidth.",
                         advice: "Lower the refresh rate, or use a faster cable or port.")
        }
        if c.isHDR && depth == 8 {
            return .init(id: "depth", severity: .info, title: "HDR over 8-bit colour",
                         detail: "HDR is on but the link carries 8 bits per colour; HDR gradients may band (the display may dither).")
        }
        return nil
    }

    static func dsc(_ d: DisplayFacts) -> DisplayDiagnosis? {
        guard let f = d.framebuffer, let c = f.activeColor, let t = f.currentTiming, t.dscRequired.contains(c.id) else { return nil }
        let raw = DisplayBandwidth.requiredGbps(pixelClockHz: t.pixelClockHz, depth: c.depth ?? 8, chroma: c.chroma ?? .rgb)
        return .init(id: "dsc", severity: .info, title: "Display Stream Compression on",
                     detail: "This mode needs about \(DisplayFormat.gbps(raw)) uncompressed, so it is compressed (visually lossless) to fit the link\(d.link?.capacityGbps.map { " (\(DisplayFormat.gbps($0)))" } ?? "").")
    }

    // MARK: Resolution

    static func hiDPI(_ d: DisplayFacts) -> DisplayDiagnosis? {
        guard !d.builtIn, d.transport != .virtual, let m = d.mode, !m.hiDPI, let native = d.nativePixels, native.width >= 2560 else { return nil }
        let hidpi = d.modes.filter(\.hiDPI)
        guard !hidpi.contains(where: { $0.width == m.width && $0.height == m.height }) else { return nil }
        let offered = Set(hidpi.map { "\($0.width) × \($0.height)" }).sorted().prefix(4).joined(separator: ", ")
        return .init(id: "hidpi", severity: .info, title: "HiDPI not available at this resolution",
                     detail: "Text and images are drawn at 1× at \(m.width) × \(m.height): macOS offers HiDPI (\"Retina\") rendering only at sizes up to about half the panel's \(native.width) × \(native.height) pixels." + (offered.isEmpty ? " This display offers no HiDPI sizes." : " HiDPI sizes offered: \(offered)."),
                     advice: offered.isEmpty ? nil : "System Settings › Displays: choose a smaller \"looks like\" size for sharper text.")
    }

    static func scaled(_ d: DisplayFacts) -> DisplayDiagnosis? {
        guard d.transport != .virtual, let m = d.mode, let native = d.nativePixels,
              m.pixelWidth != native.width || m.pixelHeight != native.height else { return nil }
        return .init(id: "scaled", severity: .info, title: "Scaled resolution",
                     detail: "macOS renders \(m.pixelWidth) × \(m.pixelHeight) pixels and resamples them to the panel's native \(native.width) × \(native.height): slightly softer than native, and a little more GPU work.")
    }

    static func proMotion(_ d: DisplayFacts) -> DisplayDiagnosis? {
        guard d.builtIn, let s = d.screen, s.maximumFPS >= 100, let hz = d.mode?.refreshHz, hz > 0, hz < 100 else { return nil }
        return .init(id: "promotion", severity: .info, title: "ProMotion is off",
                     detail: "The panel can refresh at up to \(s.maximumFPS) Hz but is fixed at \(DisplayFormat.hz(hz)).",
                     advice: "System Settings › Displays › Refresh Rate: ProMotion.")
    }
}
