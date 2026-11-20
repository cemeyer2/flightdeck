import Foundation
import CoreGraphics
import Metal
// Builds the Displays report. `collect` reads CoreGraphics (online displays and their modes), the IORegistry
// (DisplayRegistry), the EDIDs, the GPU driving each display and the built-in panel's brightness; NSScreen facts are
// read by the caller on the main thread (DisplayScreens) and passed in. `assemble` pairs the sources up and is pure,
// so tests run it on fixtures. Called when the Displays page appears, on a reconfiguration and on Refresh, never polled.

/// CoreGraphics' facts about one online display.
public struct CGDisplayData: Sendable, Hashable {
    public var id: UInt32
    public var builtIn: Bool, main: Bool
    public var mirrorOf: UInt32?
    public var vendor: UInt32, model: UInt32
    /// Used only to pair with the framebuffer node; never shown.
    public var serial: UInt32
    public var widthMM: Double, heightMM: Double
    public var mode: DisplayModeInfo?
    public var modes: [DisplayModeInfo]

    public init(id: UInt32, builtIn: Bool, main: Bool, mirrorOf: UInt32? = nil, vendor: UInt32, model: UInt32, serial: UInt32 = 0,
                widthMM: Double, heightMM: Double, mode: DisplayModeInfo?, modes: [DisplayModeInfo]) {
        self.id = id; self.builtIn = builtIn; self.main = main; self.mirrorOf = mirrorOf; self.vendor = vendor; self.model = model
        self.serial = serial; self.widthMM = widthMM; self.heightMM = heightMM; self.mode = mode; self.modes = modes
    }
}

public enum DisplayCollector {
    public static let limits = [
        "HDR reference presets (System Settings › Displays › Preset) are readable only through private APIs, so only the reference headroom NSScreen reports is shown.",
        "The colour format codes for YCbCr follow the order of Apple's AV pixel-encoding enum; RGB is confirmed, the others are not.",
        "The HDMI version of this Mac's own HDMI port isn't reported; the display's EDID is used when macOS hands it out.",
        "With several external displays, active links are listed separately because the registry doesn't say which link drives which display.",
    ]

    /// Reads everything except NSScreen. Off the main thread is fine.
    public static func collect(screens: [DisplayScreenFacts], history: [DisplayEvent], now: Date = Date()) -> DisplaysReport {
        let cg = onlineIDs().map(cgData)
        let gpus = Dictionary(uniqueKeysWithValues: cg.map { ($0.id, gpuName($0.id)) })
        let builtIn = cg.first(where: \.builtIn)?.id
        return assemble(cg: cg, screens: screens, framebuffers: DisplayRegistry.framebuffers(), links: DisplayRegistry.links(),
                        edids: DisplayRegistry.externalEDIDs(), gpus: gpus, brightness: builtIn.map(brightness),
                        history: history, now: now)
    }

    /// Pairs CoreGraphics displays with their framebuffer, link, EDID and screen facts, then diagnoses each.
    public static func assemble(cg: [CGDisplayData], screens: [DisplayScreenFacts], framebuffers: [FramebufferFacts], links: [DisplayLink],
                                edids: [EDIDInfo], gpus: [UInt32: String?], brightness: (Double?, String)?, history: [DisplayEvent], now: Date) -> DisplaysReport {
        var fbs = framebuffers
        func take(_ match: (FramebufferFacts) -> Bool) -> FramebufferFacts? { fbs.firstIndex(where: match).map { fbs.remove(at: $0) } }
        var paired: [UInt32: FramebufferFacts] = [:]
        for d in cg where d.builtIn { paired[d.id] = take { !$0.external } }
        for d in cg where !d.builtIn {
            paired[d.id] = take { $0.external && $0.vendorID == Int(d.vendor) && $0.productID == Int(d.model) && ($0.serialNumber == nil || d.serial == 0 || $0.serialNumber == Int(d.serial)) }
        }
        let unpairedExternal = cg.filter { !$0.builtIn && paired[$0.id] == nil }
        let leftover = fbs.filter(\.external)
        if unpairedExternal.count == 1, leftover.count == 1 { paired[unpairedExternal[0].id] = leftover[0] }

        let active = links.filter(\.active)
        let wired = cg.filter { !$0.builtIn && paired[$0.id] != nil }
        let linkFor: [UInt32: DisplayLink] = wired.count == 1 && active.count == 1 ? [wired[0].id: active[0]] : [:]
        let unassigned = linkFor.isEmpty ? active : []

        let displays = cg.map { d -> DisplayFacts in
            var f = DisplayFacts(id: d.id, name: "", builtIn: d.builtIn, main: d.main, transport: .unknown, mode: d.mode, modes: d.modes)
            f.mirrorOf = d.mirrorOf
            f.vendorID = d.vendor; f.modelID = d.model
            f.framebuffer = paired[d.id]
            f.screen = screens.first { $0.displayID == d.id }
            f.link = linkFor[d.id]
            f.edid = d.builtIn ? nil : edids.first { edidCode($0.manufacturer) == d.vendor && UInt32($0.productCode) == d.model }
            f.transport = transport(d, framebuffer: f.framebuffer, link: f.link, anyFramebuffers: !framebuffers.isEmpty)
            f.name = f.screen?.name ?? f.framebuffer?.productName ?? f.edid?.name ?? (d.builtIn ? "Built-in display" : "External display")
            fillSize(&f, d)
            f.year = f.framebuffer?.year ?? f.edid?.year
            f.week = f.framebuffer?.week ?? f.edid?.week
            f.colorProfile = f.screen?.colorSpace
            f.gpu = gpus[d.id] ?? nil
            if d.builtIn, let b = brightness { f.brightness = b.0; f.brightnessNote = b.1 }
            f.panelHint = panelHint(f)
            f.diagnoses = DisplayDiagnostics.diagnose(f)
            return f
        }.sorted { ($0.main ? 0 : 1, $0.builtIn ? 0 : 1, $0.id) < ($1.main ? 0 : 1, $1.builtIn ? 0 : 1, $1.id) }
        return DisplaysReport(time: now, displays: displays, unassignedLinks: unassigned, history: history, limits: limits)
    }

    static func transport(_ d: CGDisplayData, framebuffer: FramebufferFacts?, link: DisplayLink?, anyFramebuffers: Bool) -> DisplayTransport {
        if d.builtIn { return .builtIn }
        if let l = link { return l.transport }
        // On Apple silicon every wired display has a framebuffer node; one without is drawn by software.
        if anyFramebuffers && framebuffer == nil { return .virtual }
        return .unknown
    }

    /// Physical size: CoreGraphics' (from the EDID), else the EDID's or the framebuffer's image size in cm.
    static func fillSize(_ f: inout DisplayFacts, _ d: CGDisplayData) {
        if d.widthMM > 0, d.heightMM > 0 { f.widthMM = d.widthMM; f.heightMM = d.heightMM; return }
        if let w = f.edid?.widthCm, let h = f.edid?.heightCm { f.widthMM = Double(w) * 10; f.heightMM = Double(h) * 10; return }
        if let w = f.framebuffer?.imageWidthCm, let h = f.framebuffer?.imageHeightCm { f.widthMM = w * 10; f.heightMM = h * 10 }
    }

    /// The 16-bit PNP code CoreGraphics reports as the vendor number, from the three-letter ID.
    static func edidCode(_ pnp: String) -> UInt32 {
        pnp.uppercased().unicodeScalars.prefix(3).reduce(0) { $0 << 5 | (($1.value - 64) & 31) }
    }

    /// Panel technology where something says so; nil otherwise (never guessed from size alone).
    static func panelHint(_ f: DisplayFacts) -> String? {
        let n = f.name.lowercased()
        if n.contains("oled") { return "OLED" }
        if n.contains("pro display xdr") { return "LCD with full-array local dimming (XDR)" }
        if f.builtIn {
            if (f.screen?.edrPotential ?? 0) >= 8 || (f.framebuffer?.peakNits ?? 0) >= 1000 { return "mini-LED with local dimming (Liquid Retina XDR)" }
            return f.screen != nil ? "LCD (no local dimming)" : nil
        }
        if n.contains("studio display") { return "LCD (5K Retina)" }
        return nil
    }

    // MARK: Live CoreGraphics

    public static func onlineIDs() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &n) == .success, n > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    static func cgData(_ id: CGDirectDisplayID) -> CGDisplayData {
        let cur = CGDisplayCopyDisplayMode(id)
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        func info(_ m: CGDisplayMode) -> DisplayModeInfo {
            DisplayModeInfo(width: m.width, height: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight, refreshHz: m.refreshRate,
                            native: m.ioFlags & 0x0200_0000 != 0, current: cur.map { $0.ioDisplayModeID == m.ioDisplayModeID } ?? false,
                            usable: m.isUsableForDesktopGUI())
        }
        let mirror = CGDisplayMirrorsDisplay(id)
        let size = CGDisplayScreenSize(id)
        return CGDisplayData(id: id, builtIn: CGDisplayIsBuiltin(id) != 0, main: CGDisplayIsMain(id) != 0,
                             mirrorOf: mirror == kCGNullDirectDisplay ? nil : mirror, vendor: CGDisplayVendorNumber(id),
                             model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                             widthMM: Double(size.width), heightMM: Double(size.height),
                             mode: cur.map { var m = info($0); m.current = true; return m }, modes: all.map(info))
    }

    /// The Metal device driving the display (the GPU's name), when Metal answers.
    static func gpuName(_ id: CGDirectDisplayID) -> String? { CGDirectDisplayCopyCurrentMetalDevice(id)?.name }

    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private static let getBrightness: GetBrightness? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: GetBrightness.self)
    }()

    /// Built-in brightness 0…1 through DisplayServices (private, read-only, resolved with dlsym), or nil with a reason.
    static func brightness(_ id: CGDirectDisplayID) -> (Double?, String) {
        guard let f = getBrightness else { return (nil, "DisplayServices isn't available on this macOS") }
        var v: Float = -1
        guard f(id, &v) == 0, v >= 0, v <= 1 else { return (nil, "DisplayServices didn't report a level") }
        return (Double(v), "DisplayServices (read-only)")
    }
}
