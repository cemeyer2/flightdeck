import Foundation
import IOKit
// Reads Apple silicon's display coprocessor nodes from the IORegistry, without root:
// - IOMobileFramebuffer (AppleCLCD2) — one per display pipe; an active one carries DisplayAttributes (EDID-derived
//   product facts), TimingElements (every timing offered over the connection, with colour modes), DPTimingModeId
//   (the timing in use), ColorElements (the colour mode in use) and IOMFBDisplayRefresh (refresh-interval range).
// - IOPortTransportStateDisplayPort — one per port able to carry DisplayPort (HDMI port, USB-C ports); while a
//   display is attached it reports LinkRate, LaneCount and whether the stream is tunneled (Thunderbolt / USB4).
// - DCPAVServiceProxy (Location = External) — the EDID through IOAVServiceCopyEDID (IOKit SPI, resolved with dlsym).
// Parsing takes plain property dictionaries so tests can feed fixtures; fixed-point values are converted here
// (refresh rates are 16.16, refresh intervals 32.32 seconds, nits 16.16).

public enum DisplayRegistry {
    // MARK: Parsing

    /// Facts from one framebuffer node's properties; nil for an idle pipe (no DisplayAttributes).
    public static func parseFramebuffer(_ p: [String: Any]) -> FramebufferFacts? {
        guard let attrs = p["DisplayAttributes"] as? [String: Any], !attrs.isEmpty else { return nil }
        var f = FramebufferFacts(external: bool(p["external"]) ?? false)
        f.dcpIndex = int(p["DCPIndex"])
        let prod = attrs["ProductAttributes"] as? [String: Any] ?? [:]
        f.vendorID = int(prod["LegacyManufacturerID"])
        f.productID = int(prod["ProductID"])
        f.serialNumber = int(prod["SerialNumber"]).flatMap { $0 == 0 ? nil : $0 }
        f.hasSerial = f.serialNumber != nil || (prod["AlphanumericSerialNumber"] as? String).map { !$0.isEmpty } == true
        f.productName = (prod["ProductName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        f.manufacturerID = prod["ManufacturerID"] as? String
        f.year = int(prod["YearOfManufacture"]).flatMap { $0 > 1990 ? $0 : nil }
        f.week = int(prod["WeekOfManufacture"]).flatMap { (1...54).contains($0) ? $0 : nil }
        f.imageWidthCm = double(attrs["MaxHorizontalImageSize"]).flatMap { $0 > 0 ? $0 : nil }
        f.imageHeightCm = double(attrs["MaxVerticalImageSize"]).flatMap { $0 > 0 ? $0 : nil }
        f.nativeWidth = int(attrs["NativeFormatHorizontalPixels"])
        f.nativeHeight = int(attrs["NativeFormatVerticalPixels"])
        f.timings = (p["TimingElements"] as? [[String: Any]] ?? []).compactMap(parseTiming)
        f.currentTimingID = int(p["DPTimingModeId"])
        if f.nativeWidth == nil, let pref = f.timings.first(where: \.preferred) { f.nativeWidth = pref.width; f.nativeHeight = pref.height }
        f.activeColor = (p["ColorElements"] as? [[String: Any]])?.first.flatMap(parseColor)
        if let r = p["IOMFBDisplayRefresh"] as? [String: Any] {
            f.minRefreshInterval = double(r["displayMinRefreshInterval"]).flatMap { $0 > 0 ? $0 / 4_294_967_296 : nil }
            f.maxRefreshInterval = double(r["displayMaxRefreshInterval"]).flatMap { $0 > 0 ? $0 / 4_294_967_296 : nil }
        }
        if !f.external {   // the backlight values only mean something on a built-in panel
            f.brightnessNits = double(p["IOMFBBrightnessLevel"]).flatMap { $0 > 0 && $0 < 1e12 ? $0 / 65536 : nil }
            f.peakNits = double(p["limit_max_physical_brightness"]).flatMap { $0 > 0 && $0 < 1e12 ? $0 / 65536 : nil }
        }
        return f
    }

    static func parseTiming(_ t: [String: Any]) -> DisplayTiming? {
        guard let id = int(t["ID"]), let h = t["HorizontalAttributes"] as? [String: Any], let v = t["VerticalAttributes"] as? [String: Any],
              let w = int(h["Active"]), let ht = int(v["Active"]) else { return nil }
        let rate = double(v["PreciseSyncRate"]).flatMap { $0 > 0 ? $0 : nil } ?? double(v["SyncRate"]) ?? 0
        guard rate > 0 else { return nil }
        func vrr(_ x: Any?) -> Double? {
            guard let d = double(x), d > 0 else { return nil }
            return d > 1000 ? d / 65536 : d
        }
        let colors = (t["ColorModes"] as? [[String: Any]] ?? []).compactMap(parseColor)
        return DisplayTiming(id: id, width: w, height: ht, hTotal: int(h["Total"]), vTotal: int(v["Total"]), refreshHz: rate / 65536,
                             preferred: bool(t["IsPreferred"]) ?? false, vrrMin: vrr(t["MinimumVariableRefreshRate"]),
                             vrrMax: vrr(t["MaximumVariableRefreshRate"]), colorModes: colors,
                             dscRequired: (t["DSCRequiredColorElementIDs"] as? [Any] ?? []).compactMap(int))
    }

    static func parseColor(_ c: [String: Any]) -> DisplayColorMode? {
        guard let id = int(c["ID"]) else { return nil }
        return DisplayColorMode(id: id, depth: int(c["Depth"]).flatMap { $0 > 0 ? $0 : nil }, chroma: int(c["PixelEncoding"]).flatMap(DisplayChroma.fromIOMFB),
                                eotf: int(c["EOTF"]), supportsDSC: (int(c["SupportsDSC"]) ?? 0) != 0 || bool(c["SupportsDSC"]) == true)
    }

    /// One DisplayPort transport node.
    public static func parseLink(_ p: [String: Any]) -> DisplayLink {
        let desc = p["LinkRateDescription"] as? String
        let raw = int(p["LinkRate"])
        let decoded = DisplayBandwidth.decodeLinkRate(raw: raw, description: desc)
        let lanes = int(p["LaneCount"]).flatMap { $0 > 0 ? $0 : nil }
        let noLink = desc?.lowercased().contains("no link") == true
        let active = !noLink && ((bool(p["Active"]) ?? false) || (decoded != nil && lanes != nil))
        let port = (p["TransportDescription"] as? String).map { String($0.split(separator: "/").first ?? Substring($0)) }
        return DisplayLink(port: port, portType: p["ParentPortTypeDescription"] as? String, active: active,
                           tunneled: bool(p["Tunneled"]) ?? false, lanes: lanes, maxLanes: int(p["MaxLaneCount"]),
                           laneGbps: decoded?.gbps, rateName: decoded?.name,
                           rawRate: raw, rawRateDescription: desc)
    }

    // MARK: Live reads

    static let framebufferKeys = ["external", "DCPIndex", "DisplayAttributes", "TimingElements", "DPTimingModeId", "ColorElements",
                                  "IOMFBDisplayRefresh", "IOMFBBrightnessLevel", "limit_max_physical_brightness"]
    static let linkKeys = ["TransportDescription", "ParentPortTypeDescription", "Active", "Tunneled", "LaneCount", "MaxLaneCount",
                           "LinkRate", "LinkRateDescription"]

    /// Active framebuffers (empty on Intel Macs, which have no display coprocessor).
    public static func framebuffers() -> [FramebufferFacts] { nodes("IOMobileFramebuffer", keys: framebufferKeys).compactMap(parseFramebuffer) }

    /// Every DisplayPort transport, with or without a link.
    public static func links() -> [DisplayLink] { nodes("IOPortTransportStateDisplayPort", keys: linkKeys).map(parseLink) }

    /// Reads only the named properties of each node of a class (some framebuffer properties are large).
    static func nodes(_ cls: String, keys: [String]) -> [[String: Any]] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [[String: Any]] = []
        while case let s = IOIteratorNext(it), s != 0 {
            var d: [String: Any] = [:]
            for k in keys {
                if let v = IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() { d[k] = v }
            }
            out.append(d)
            IOObjectRelease(s)
        }
        return out
    }

    private typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias AVCopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> Int32
    private static let avFunctions: (AVCreate, AVCopyEDID)? = {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(h, "IOAVServiceCreateWithService"), let e = dlsym(h, "IOAVServiceCopyEDID") else { return nil }
        return (unsafeBitCast(c, to: AVCreate.self), unsafeBitCast(e, to: AVCopyEDID.self))
    }()

    /// EDIDs of external displays from the display coprocessor's AV services. Empty when the SPI is missing or
    /// refuses (it does for the built-in panel); callers then fall back to the framebuffer's product attributes.
    public static func externalEDIDs() -> [EDIDInfo] {
        guard let (create, copy) = avFunctions else { return [] }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [EDIDInfo] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard loc == "External", let av = create(kCFAllocatorDefault, s)?.takeRetainedValue() else { continue }
            var data: Unmanaged<CFData>?
            if copy(av, &data) == 0, let d = data?.takeRetainedValue() as Data?, let e = EDID.parse(d) { out.append(e) }
        }
        return out
    }

    // MARK: Property helpers (NSNumber / CFBoolean bridging)

    static func int(_ x: Any?) -> Int? {
        if let n = x as? NSNumber { return n.intValue }
        return x as? Int
    }
    static func double(_ x: Any?) -> Double? {
        if let n = x as? NSNumber { return n.doubleValue }
        return x as? Double
    }
    static func bool(_ x: Any?) -> Bool? {
        if let b = x as? Bool { return b }
        return (x as? NSNumber)?.boolValue
    }
}
