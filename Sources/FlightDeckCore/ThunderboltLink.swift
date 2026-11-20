import Foundation
// Peripherals › link speeds, Thunderbolt/USB4: each connected router (dock, display, drive enclosure) and the link to
// it, from the IORegistry's IOThunderboltSwitch and IOThunderboltPort nodes. The lane adapter's "Current Link Speed",
// "Supported Link Speed", "Current Link Width" and "Supported Link Width" carry the USB4 lane-adapter register fields:
// speed 0x8 = Gen 2 (10 Gb/s per lane), 0x4 = Gen 3 (20 Gb/s; Thunderbolt 3's 20.6), 0x2 = Gen 4 (40 Gb/s), with the
// supported value a bit mask of those; width 1 = one lane, 2 = two bonded lanes, 4/8 = Thunderbolt 5's asymmetric
// 3-lanes-one-way. Total bandwidth = per-lane rate × lanes. Both ends of a link report it; the device's own upstream
// port says what the device supports and the Mac's (or upstream device's) port what that side supports.

public struct TBPortReading: Hashable, Sendable {
    public var currentSpeed: Int?
    public var currentWidth: Int?
    public var supportedSpeed: Int?
    public var supportedWidth: Int?
    public init(currentSpeed: Int?, currentWidth: Int?, supportedSpeed: Int?, supportedWidth: Int?) {
        self.currentSpeed = currentSpeed; self.currentWidth = currentWidth; self.supportedSpeed = supportedSpeed; self.supportedWidth = supportedWidth
    }
    public init(props d: [String: Any]) {
        func n(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        self.init(currentSpeed: n("Current Link Speed"), currentWidth: n("Current Link Width"),
                  supportedSpeed: n("Supported Link Speed"), supportedWidth: n("Supported Link Width"))
    }
}

/// One connected Thunderbolt/USB4 router (not the Mac's own).
public struct TBSwitchInput: Hashable, Sendable {
    public var id: UInt64
    public var name: String
    public var vendor: String?
    /// 1 = plugged into the Mac, 2 = daisy-chained behind another device, …
    public var depth: Int
    /// The Mac's (or the upstream device's) port the link starts at, and the device's own upstream port.
    public var hostSide: TBPortReading?
    public var deviceSide: TBPortReading?
    public var upstreamName: String?
    public init(id: UInt64, name: String, vendor: String?, depth: Int, hostSide: TBPortReading?, deviceSide: TBPortReading?, upstreamName: String? = nil) {
        self.id = id; self.name = name; self.vendor = vendor; self.depth = depth
        self.hostSide = hostSide; self.deviceSide = deviceSide; self.upstreamName = upstreamName
    }
}

public struct ThunderboltLink: Identifiable, Hashable, Sendable {
    public var id: UInt64
    public var name: String
    public var vendor: String?
    public var depth: Int
    public var upstreamName: String?
    public var currentGbps: Double?
    /// The fastest link both ends support (nil when either end doesn't say).
    public var maxGbps: Double?
    /// "Gen 3 ×2".
    public var currentMode: String?
    public var maxMode: String?
    public var diagnosis: LinkDiagnosis
}

public enum ThunderboltLinks {
    /// Per-lane Gb/s for a current-speed code.
    static func laneGbps(_ code: Int) -> Double? { switch code { case 0x2: 40; case 0x4: 20; case 0x8: 10; default: nil } }
    /// The fastest per-lane rate in a supported-speed mask.
    static func maxLaneGbps(_ mask: Int) -> Double? { [0x2, 0x4, 0x8].first { mask & $0 != 0 }.flatMap(laneGbps) }
    static func gen(_ lane: Double) -> String { lane >= 40 ? "Gen 4" : lane >= 20 ? "Gen 3" : "Gen 2" }
    /// Lanes carrying data one way for a current-width code; Thunderbolt 5's asymmetric modes use 3.
    static func lanes(_ width: Int) -> Int { width >= 4 ? 3 : width >= 2 ? 2 : 1 }
    /// Whether a supported-width value allows two bonded lanes.
    static func maxLanes(_ width: Int) -> Int { width & 0x2 != 0 || width >= 4 ? 2 : 1 }

    static func mode(_ lane: Double, _ n: Int) -> String { "\(gen(lane)) ×\(n)" }

    public static func analyze(_ inputs: [TBSwitchInput]) -> [ThunderboltLink] {
        inputs.sorted { ($0.depth, $0.name) < ($1.depth, $1.name) }.map(link)
    }

    static func link(_ s: TBSwitchInput) -> ThunderboltLink {
        // The current link is the same at both ends; prefer the host side's view, fall back to the device's.
        let cur = [s.hostSide, s.deviceSide].compactMap { $0 }.first { $0.currentSpeed.flatMap(laneGbps) != nil }
        let curLane = cur?.currentSpeed.flatMap(laneGbps)
        let curLanes = cur?.currentWidth.map(lanes)
        let current: Double? = curLane.flatMap { l in curLanes.map { l * Double($0) } }
        var maxLane: Double?, maxN: Int?
        if let h = s.hostSide?.supportedSpeed.flatMap(maxLaneGbps), let d = s.deviceSide?.supportedSpeed.flatMap(maxLaneGbps) { maxLane = min(h, d) }
        if let h = s.hostSide?.supportedWidth.map(maxLanes), let d = s.deviceSide?.supportedWidth.map(maxLanes) { maxN = min(h, d) }
        let maxTotal: Double? = maxLane.flatMap { l in maxN.map { l * Double($0) } }
        let curMode = curLane.flatMap { l in curLanes.map { mode(l, $0) } }
        let maxMode = maxLane.flatMap { l in maxN.map { mode(l, $0) } }
        return ThunderboltLink(id: s.id, name: s.name, vendor: s.vendor, depth: s.depth, upstreamName: s.upstreamName,
                               currentGbps: current, maxGbps: maxTotal, currentMode: curMode, maxMode: maxMode,
                               diagnosis: diagnose(s, current: current, max: maxTotal, curMode: curMode, maxMode: maxMode,
                                                   lanesUp: curLanes, lanesMax: maxN))
    }

    static func diagnose(_ s: TBSwitchInput, current: Double?, max: Double?, curMode: String?, maxMode: String?,
                         lanesUp: Int?, lanesMax: Int?) -> LinkDiagnosis {
        guard let current, let curMode else { return LinkDiagnosis(level: .note, summary: "\(s.name)'s link speed isn't reported.") }
        let kind = s.name.lowercased().contains("dock") ? "This Thunderbolt dock" : s.name
        let gb = { (g: Double) in LinkRate.text(g * 1000) }
        guard let max, let maxMode else {
            return LinkDiagnosis(level: .ok, summary: "\(kind) is linked at \(gb(current)) (\(curMode)); what both ends support isn't reported.")
        }
        if current + 0.5 >= max { return LinkDiagnosis(level: .ok, summary: "Full speed: \(gb(current)) (\(curMode)).") }
        let chain = s.depth > 1 ? " (it's daisy-chained behind \(s.upstreamName ?? "another device"); that hop sets the limit)" : ""
        let head = "\(kind) is linked at \(gb(current)) (\(curMode)), not \(gb(max)) (\(maxMode))\(chain)"
        if let up = lanesUp, let mx = lanesMax, up < mx {
            return LinkDiagnosis(level: .slow, summary: "\(head): only one of its two lanes is up.",
                                 advice: "Reseat the cable at both ends; if it persists, try another Thunderbolt or USB4 cable.")
        }
        return LinkDiagnosis(level: .slow, summary: "\(head): the cable is the usual cause.",
                             advice: "Use a cable rated \(gb(max)) (Thunderbolt 4/5 or USB4 \(gb(max))); passive USB-C cables longer than about 0.8 m often top out at 20 Gb/s.")
    }
}
