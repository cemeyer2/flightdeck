import Foundation
// The assembled per-display facts, the plain-English diagnoses about them, the session's connect / mode-change
// history and the formatting shared by the page and the `displays` MCP tool.

/// A plain-English finding about one display, backed by numbers where it makes a claim about bandwidth.
public struct DisplayDiagnosis: Codable, Sendable, Hashable, Identifiable {
    public enum Severity: String, Codable, Sendable, Comparable {
        case info, caution, warning
        var rank: Int { switch self { case .info: 0; case .caution: 1; case .warning: 2 } }
        public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    }
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    /// What to do about it, when there is something to do.
    public var advice: String?

    public init(id: String, severity: Severity, title: String, detail: String, advice: String? = nil) {
        self.id = id; self.severity = severity; self.title = title; self.detail = detail; self.advice = advice
    }
}

/// Everything known about one connected display.
public struct DisplayFacts: Codable, Sendable, Identifiable, Hashable {
    public var id: UInt32
    public var name: String
    public var builtIn: Bool
    public var main: Bool
    public var online: Bool
    /// The display this one mirrors, if mirroring.
    public var mirrorOf: UInt32?
    public var vendorID: UInt32?, modelID: UInt32?
    /// Physical size from CoreGraphics (EDID image size), in mm.
    public var widthMM: Double?, heightMM: Double?
    public var year: Int?, week: Int?
    /// "mini-LED (Liquid Retina XDR)"; nil when nothing hints at the panel technology.
    public var panelHint: String?
    public var transport: DisplayTransport
    public var mode: DisplayModeInfo?
    public var modes: [DisplayModeInfo]
    public var screen: DisplayScreenFacts?
    public var framebuffer: FramebufferFacts?
    public var link: DisplayLink?
    public var edid: EDIDInfo?
    /// Built-in brightness 0…1 from DisplayServices, or why it isn't known.
    public var brightness: Double?
    public var brightnessNote: String?
    public var colorProfile: String?
    public var gpu: String?
    public var diagnoses: [DisplayDiagnosis]

    public init(id: UInt32, name: String, builtIn: Bool, main: Bool = false, transport: DisplayTransport, mode: DisplayModeInfo? = nil, modes: [DisplayModeInfo] = []) {
        self.id = id; self.name = name; self.builtIn = builtIn; self.main = main; online = true; self.transport = transport
        self.mode = mode; self.modes = modes; diagnoses = []
    }

    /// Diagonal in inches from the physical size.
    public var diagonalInches: Double? {
        guard let w = widthMM, let h = heightMM, w > 0, h > 0 else { return nil }
        return (w * w + h * h).squareRoot() / 25.4
    }
    /// The panel's native pixel size: the native-flagged mode, else the framebuffer's, else the largest mode.
    public var nativePixels: (width: Int, height: Int)? {
        if let n = modes.first(where: \.native) { return (n.pixelWidth, n.pixelHeight) }
        if let w = framebuffer?.nativeWidth, let h = framebuffer?.nativeHeight { return (w, h) }
        return modes.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }.map { ($0.pixelWidth, $0.pixelHeight) }
    }
    /// Highest refresh any mode offers at the current pixel size.
    public var bestRefreshAtCurrentSize: Double? {
        guard let m = mode else { return nil }
        let same = modes.filter { $0.pixelWidth == m.pixelWidth && $0.pixelHeight == m.pixelHeight }.map(\.refreshHz)
        let timings = (framebuffer?.timings ?? []).filter { $0.width == m.pixelWidth && $0.height == m.pixelHeight }.map(\.refreshHz)
        return (same + timings).max()
    }
    /// HDR state in words.
    public var hdrState: String {
        guard let s = screen else { return "unavailable (screen not reported by AppKit)" }
        if s.edrPotential <= 1.0 { return "off (no HDR headroom)" }
        return builtIn ? "available (the XDR panel shows HDR whenever content asks for it)" : "on"
    }
    public var worstSeverity: DisplayDiagnosis.Severity? { diagnoses.map(\.severity).max() }
}

/// One display reconfiguration seen this session (from CGDisplayRegisterReconfigurationCallback).
public struct DisplayEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case connected, disconnected, modeChanged, mainChanged, mirroring, enabled, disabled, baseline }
    public var id: String { "\(time.timeIntervalSince1970)-\(display)-\(kind.rawValue)" }
    public var time: Date
    public var display: UInt32
    public var name: String
    public var kind: Kind
    public var detail: String

    public init(time: Date, display: UInt32, name: String, kind: Kind, detail: String) {
        self.time = time; self.display = display; self.name = name; self.kind = kind; self.detail = detail
    }

    public var title: String {
        switch kind {
        case .connected: "Connected"; case .disconnected: "Disconnected"; case .modeChanged: "Mode changed"
        case .mainChanged: "Became main display"; case .mirroring: "Mirroring changed"; case .enabled: "Enabled"
        case .disabled: "Disabled"; case .baseline: "Present at launch"
        }
    }
}

/// The Displays page's data: every display, links that couldn't be tied to one, and this session's history.
public struct DisplaysReport: Codable, Sendable, Hashable {
    public var time: Date
    public var displays: [DisplayFacts]
    /// Active video links when there are several external displays and FlightDeck can't tell which link drives which.
    public var unassignedLinks: [DisplayLink]
    public var history: [DisplayEvent]
    /// What this Mac's sources can't tell (shown at the bottom of the page and in the MCP tool).
    public var limits: [String]

    public init(time: Date, displays: [DisplayFacts], unassignedLinks: [DisplayLink] = [], history: [DisplayEvent] = [], limits: [String] = []) {
        self.time = time; self.displays = displays; self.unassignedLinks = unassignedLinks; self.history = history; self.limits = limits
    }
}

/// Number formatting shared by the page and the MCP tool.
public enum DisplayFormat {
    /// "120 Hz", "59.94 Hz".
    public static func hz(_ v: Double) -> String {
        abs(v - v.rounded()) < 0.005 ? "\(Int(v.rounded())) Hz" : String(format: "%.2f Hz", v)
    }
    /// "12.5 Gbit/s".
    public static func gbps(_ v: Double) -> String { String(format: v < 10 ? "%.2f Gbit/s" : "%.1f Gbit/s", v) }
    /// "533 MHz".
    public static func mhz(_ hz: Double) -> String { String(format: "%.0f MHz", hz / 1e6) }
    /// "16.0×".
    public static func headroom(_ v: Double) -> String { String(format: "%.1f×", v) }
}
