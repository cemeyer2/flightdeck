import Foundation
// The Displays page's model: one DisplayFacts per connected display, built by DisplayCollector from CoreGraphics
// (modes), NSScreen (refresh range, EDR headroom; DisplayScreens.swift), the display coprocessor's framebuffer nodes
// in the IORegistry (AppleCLCD2: timings, colour mode, product attributes; DisplayRegistry.swift), the port transport
// nodes (IOPortTransportStateDisplayPort: link rate and lanes), the EDID where macOS hands it out, and DisplayServices
// for the built-in panel's brightness. Every field a source didn't give is nil (shown as unavailable), never 0.

/// How a display is attached.
public enum DisplayTransport: String, Codable, Sendable, Hashable {
    case builtIn = "Built-in panel"
    case hdmi = "HDMI (this Mac's HDMI port)"
    case usbC = "USB-C (DisplayPort Alt Mode)"
    case thunderbolt = "Thunderbolt / USB4 (DisplayPort tunnel)"
    case displayPort = "DisplayPort"
    case virtual = "Virtual or streamed (AirPlay, Sidecar or DisplayLink)"
    case unknown = "Not reported"

    public var short: String {
        switch self {
        case .builtIn: "Built-in"; case .hdmi: "HDMI"; case .usbC: "USB-C DP Alt Mode"; case .thunderbolt: "Thunderbolt"
        case .displayPort: "DisplayPort"; case .virtual: "Virtual"; case .unknown: "Unknown"
        }
    }
}

/// How colour is carried on the wire.
public enum DisplayChroma: String, Codable, Sendable, Hashable {
    case rgb = "RGB", ycbcr444 = "YCbCr 4:4:4", ycbcr422 = "YCbCr 4:2:2", ycbcr420 = "YCbCr 4:2:0"

    /// Components sent per pixel (4:2:2 halves the two colour components, 4:2:0 quarters them).
    public var componentsPerPixel: Double {
        switch self { case .rgb, .ycbcr444: 3; case .ycbcr422: 2; case .ycbcr420: 1.5 }
    }
    public var subsampled: Bool { self == .ycbcr422 || self == .ycbcr420 }

    /// The display coprocessor's `PixelEncoding` code. 0 (RGB) is confirmed on Apple silicon; the YCbCr codes follow
    /// the order of Apple's IOAVService pixel-encoding enum and are not confirmed against a live subsampled link.
    public static func fromIOMFB(_ code: Int) -> DisplayChroma? {
        switch code { case 0: .rgb; case 1: .ycbcr444; case 2: .ycbcr422; case 3: .ycbcr420; default: nil }
    }
}

/// One colour mode (bit depth, chroma, transfer function) the display coprocessor offers or uses.
public struct DisplayColorMode: Codable, Sendable, Hashable {
    public var id: Int
    /// Bits per colour component.
    public var depth: Int?
    public var chroma: DisplayChroma?
    /// Transfer function code: 0 is SDR (gamma); anything else is an HDR curve (PQ or HLG).
    public var eotf: Int?
    /// Whether the mode can be carried with Display Stream Compression.
    public var supportsDSC: Bool
    public var isHDR: Bool { (eotf ?? 0) != 0 }

    public init(id: Int, depth: Int?, chroma: DisplayChroma?, eotf: Int?, supportsDSC: Bool = false) {
        self.id = id; self.depth = depth; self.chroma = chroma; self.eotf = eotf; self.supportsDSC = supportsDSC
    }

    /// "10-bit RGB", "8-bit YCbCr 4:2:2", "HDR".
    public var summary: String {
        let d = depth.map { "\($0)-bit" } ?? "bit depth not reported"
        return "\(d) \(chroma?.rawValue ?? "colour format not reported")" + (isHDR ? ", HDR" : "")
    }
}

/// One video timing the display advertises over its current connection (from the framebuffer's TimingElements).
public struct DisplayTiming: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var width: Int, height: Int
    /// Totals including blanking, when reported; they give the exact pixel clock.
    public var hTotal: Int?, vTotal: Int?
    public var refreshHz: Double
    public var preferred: Bool
    /// Variable refresh range (Adaptive-Sync / ProMotion), when the timing has one.
    public var vrrMin: Double?, vrrMax: Double?
    public var colorModes: [DisplayColorMode]
    /// Colour modes that only fit this timing with DSC.
    public var dscRequired: [Int]

    public init(id: Int, width: Int, height: Int, hTotal: Int? = nil, vTotal: Int? = nil, refreshHz: Double, preferred: Bool = false,
                vrrMin: Double? = nil, vrrMax: Double? = nil, colorModes: [DisplayColorMode] = [], dscRequired: [Int] = []) {
        self.id = id; self.width = width; self.height = height; self.hTotal = hTotal; self.vTotal = vTotal; self.refreshHz = refreshHz
        self.preferred = preferred; self.vrrMin = vrrMin; self.vrrMax = vrrMax; self.colorModes = colorModes; self.dscRequired = dscRequired
    }

    /// Pixel clock in Hz: exact from the totals, else estimated with CVT reduced blanking v2.
    public var pixelClockHz: Double {
        if let h = hTotal, let v = vTotal, h > 0, v > 0 { return Double(h * v) * refreshHz }
        return DisplayBandwidth.cvtRB2PixelClock(width: width, height: height, refreshHz: refreshHz)
    }
}

/// What the display coprocessor's framebuffer node (AppleCLCD2 / IOMobileFramebuffer) says about one display.
public struct FramebufferFacts: Codable, Sendable, Hashable {
    public var external: Bool
    public var dcpIndex: Int?
    public var vendorID: Int?, productID: Int?
    /// True when the node carries a serial number. The number itself is used only to pair the node with its
    /// CoreGraphics display (two identical monitors); it is never shown or exported.
    public var hasSerial: Bool
    public var serialNumber: Int?
    public var productName: String?
    public var manufacturerID: String?
    public var year: Int?, week: Int?
    /// Maximum image size from the display's EDID, in cm.
    public var imageWidthCm: Double?, imageHeightCm: Double?
    public var nativeWidth: Int?, nativeHeight: Int?
    public var currentTimingID: Int?
    public var timings: [DisplayTiming]
    /// The colour mode in use (the node's ColorElements).
    public var activeColor: DisplayColorMode?
    /// The panel's refresh-interval range in seconds (shortest = fastest refresh), from IOMFBDisplayRefresh.
    public var minRefreshInterval: Double?, maxRefreshInterval: Double?
    /// Backlight level in nits as the driver reports it, and the panel's physical peak (built-in panels only).
    public var brightnessNits: Double?, peakNits: Double?

    public init(external: Bool, timings: [DisplayTiming] = []) {
        self.external = external; self.timings = timings; hasSerial = false
    }

    public var currentTiming: DisplayTiming? { timings.first { $0.id == currentTimingID } }
}

/// The video link from the Mac to an external display, from the port's DisplayPort transport node.
public struct DisplayLink: Codable, Sendable, Hashable {
    /// "Port-USB-C@2", "Port-HDMI@1".
    public var port: String?
    /// "USB-C", "HDMI", "MagSafe 3"…
    public var portType: String?
    public var active: Bool
    public var tunneled: Bool
    public var lanes: Int?, maxLanes: Int?
    /// Per-lane signalling rate in Gbit/s and its DisplayPort name ("HBR3").
    public var laneGbps: Double?
    public var rateName: String?
    /// The raw LinkRate value and LinkRateDescription, kept for display when they couldn't be decoded.
    public var rawRate: Int?, rawRateDescription: String?

    public init(port: String? = nil, portType: String? = nil, active: Bool, tunneled: Bool = false, lanes: Int? = nil, maxLanes: Int? = nil,
                laneGbps: Double? = nil, rateName: String? = nil, rawRate: Int? = nil, rawRateDescription: String? = nil) {
        self.port = port; self.portType = portType; self.active = active; self.tunneled = tunneled; self.lanes = lanes; self.maxLanes = maxLanes
        self.laneGbps = laneGbps; self.rateName = rateName; self.rawRate = rawRate; self.rawRateDescription = rawRateDescription
    }

    public var transport: DisplayTransport {
        if tunneled { return .thunderbolt }
        switch portType?.lowercased() {
        case "hdmi": return .hdmi
        case "usb-c": return .usbC
        default: return .displayPort
        }
    }

    /// Payload capacity in Gbit/s after line coding, when both rate and lanes are known.
    public var capacityGbps: Double? {
        guard let r = laneGbps, let l = lanes, l > 0 else { return nil }
        return DisplayBandwidth.dpPayloadGbps(laneGbps: r, lanes: l)
    }

    /// "HBR3 × 4 lanes (25.9 Gbit/s)".
    public var summary: String {
        guard active else { return "no link trained" }
        let rate = rateName ?? laneGbps.map { String(format: "%.2f Gbit/s per lane", $0) } ?? rawRateDescription ?? "rate not reported"
        let lanesText = lanes.map { " × \($0) lane\($0 == 1 ? "" : "s")" } ?? ""
        return rate + lanesText + (capacityGbps.map { String(format: " (%.1f Gbit/s usable)", $0) } ?? "")
    }
}

/// One mode CoreGraphics offers (what System Settings › Displays lists, plus duplicates it hides).
public struct DisplayModeInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(width)x\(height)@\(pixelWidth)x\(pixelHeight)@\(String(format: "%.2f", refreshHz))" }
    /// Size in points (what apps lay out in) and in pixels (what is sent to the display).
    public var width: Int, height: Int
    public var pixelWidth: Int, pixelHeight: Int
    /// 0 when CoreGraphics doesn't report a rate (some built-in and virtual displays).
    public var refreshHz: Double
    public var native: Bool
    public var current: Bool
    public var usable: Bool

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshHz: Double, native: Bool = false, current: Bool = false, usable: Bool = true) {
        self.width = width; self.height = height; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.refreshHz = refreshHz; self.native = native; self.current = current; self.usable = usable
    }

    public var scale: Double { width > 0 ? Double(pixelWidth) / Double(width) : 1 }
    public var hiDPI: Bool { scale >= 1.5 }
    /// "1728 × 1117 (3456 × 2234 px, HiDPI) at 120 Hz".
    public var summary: String {
        let px = pixelWidth == width ? "" : " (\(pixelWidth) × \(pixelHeight) px\(hiDPI ? ", HiDPI" : ""))"
        return "\(width) × \(height)\(px)" + (refreshHz > 0 ? " at \(DisplayFormat.hz(refreshHz))" : "")
    }
}

/// NSScreen's view of a display (read on the main thread; see DisplayScreens).
public struct DisplayScreenFacts: Codable, Sendable, Hashable {
    public var displayID: UInt32
    public var name: String
    public var maximumFPS: Int
    /// Seconds between frames at the fastest and slowest refresh the screen can run (equal when the rate is fixed).
    public var minimumRefreshInterval: Double, maximumRefreshInterval: Double
    /// Step between supported refresh intervals (0 = any interval in the range).
    public var updateGranularity: Double
    /// EDR headroom: brightness available above SDR white, now and at most. 1.0 = no HDR headroom.
    public var edrNow: Double, edrPotential: Double
    /// Reference-mode headroom (0 when no reference preset is active).
    public var edrReference: Double
    public var colorSpace: String?
    public var backingScale: Double

    public init(displayID: UInt32, name: String, maximumFPS: Int, minimumRefreshInterval: Double, maximumRefreshInterval: Double,
                updateGranularity: Double, edrNow: Double, edrPotential: Double, edrReference: Double, colorSpace: String?, backingScale: Double) {
        self.displayID = displayID; self.name = name; self.maximumFPS = maximumFPS; self.minimumRefreshInterval = minimumRefreshInterval
        self.maximumRefreshInterval = maximumRefreshInterval; self.updateGranularity = updateGranularity; self.edrNow = edrNow
        self.edrPotential = edrPotential; self.edrReference = edrReference; self.colorSpace = colorSpace; self.backingScale = backingScale
    }

    /// The variable refresh range in Hz when the screen can change rate on its own (ProMotion, Adaptive-Sync).
    public var variableRange: ClosedRange<Double>? {
        guard minimumRefreshInterval > 0, maximumRefreshInterval > minimumRefreshInterval * 1.05 else { return nil }
        return (1 / maximumRefreshInterval)...(1 / minimumRefreshInterval)
    }
}
