import Foundation
// Reads a network's real channel width and centre from the information elements (IEs) in its beacon, which CoreWLAN
// hands over as raw bytes (`CWNetwork.informationElementData`). CoreWLAN's own `channelWidth` stops at 160 MHz and
// doesn't say where a wide block sits, so a Wi-Fi 7 network at 320 MHz, or a 2.4 GHz network whose 40 MHz secondary
// channel is below its primary, would otherwise be drawn in the wrong place.
//
// Deliberately not read: the SSID element (ID 0). macOS hides SSIDs from apps without Location permission, and reading
// it from the raw beacon would get around the user's choice.

/// What the beacon says about the operating channel. Each field is nil when no element said so.
public struct WiFiBeaconInfo: Equatable, Sendable {
    /// Operating width in MHz (20, 40, 80, 160 or 320).
    public var widthMHz: Int?
    /// Centre channel of the whole block (e.g. 42 for 80 MHz on 36–48), on the band's channel numbering.
    public var centerChannel: Int?
    /// 2.4/5 GHz HT: the 40 MHz secondary channel is above (true) or below (false) the primary.
    public var secondaryAbove: Bool?
    /// Highest standard advertised: "802.11n", "802.11ac", "802.11ax", "802.11be".
    public var standard: String?
    public init(widthMHz: Int? = nil, centerChannel: Int? = nil, secondaryAbove: Bool? = nil, standard: String? = nil) {
        self.widthMHz = widthMHz; self.centerChannel = centerChannel; self.secondaryAbove = secondaryAbove; self.standard = standard
    }
}

public enum WiFiIE {
    /// Splits the IE blob into (id, body) pairs. Element ID 255 is an "extension" element whose first body byte is
    /// the extension ID; those are returned as 256 + extension ID so callers can match them directly. A truncated
    /// element ends the walk (the rest can't be trusted).
    static func elements(_ d: [UInt8]) -> [(id: Int, body: ArraySlice<UInt8>)] {
        var out: [(Int, ArraySlice<UInt8>)] = []
        var i = 0
        while i + 2 <= d.count {
            let id = Int(d[i]), len = Int(d[i + 1])
            guard i + 2 + len <= d.count else { break }
            let body = d[(i + 2)..<(i + 2 + len)]
            if id == 255, let ext = body.first { out.append((256 + Int(ext), body.dropFirst())) } else { out.append((id, body)) }
            i += 2 + len
        }
        return out
    }

    /// Element IDs used below (IEEE 802.11-2020 §9.4.2).
    static let htOperation = 61, vhtOperation = 192, heOperation = 256 + 36, ehtOperation = 256 + 106

    /// Parses the beacon. The widest element present wins: EHT (Wi-Fi 7) over HE 6 GHz info (Wi-Fi 6E) over VHT
    /// (Wi-Fi 5) over HT (Wi-Fi 4), because a newer element describes the BSS's real width while older ones are kept
    /// for older clients (an EHT 320 MHz BSS still advertises 160 MHz in its HE element).
    public static func parse(_ data: Data?, primary: Int?) -> WiFiBeaconInfo {
        guard let data, !data.isEmpty else { return WiFiBeaconInfo() }
        var info = WiFiBeaconInfo()
        for (id, b) in elements([UInt8](data)) {
            let b = Array(b)
            switch id {
            case htOperation where b.count >= 2:
                info.standard = info.standard ?? "802.11n"
                // Byte 1 bits 0–1: secondary channel offset (1 above, 3 below, 0 none); bit 2: 40 MHz allowed.
                let offset = b[1] & 0x03, allows40 = b[1] & 0x04 != 0
                if allows40 && (offset == 1 || offset == 3), let p = primary {
                    info.secondaryAbove = offset == 1
                    if info.widthMHz == nil || info.widthMHz == 20 { info.widthMHz = 40; info.centerChannel = offset == 1 ? p + 2 : p - 2 }
                } else if info.widthMHz == nil { info.widthMHz = 20; info.centerChannel = primary }
            case vhtOperation where b.count >= 3:
                if info.standard == nil || info.standard == "802.11n" { info.standard = "802.11ac" }
                // Byte 0: 0 = 20/40 (HT decides), 1 = 80/160/80+80, 2 = 160 (deprecated), 3 = 80+80 (deprecated).
                // Bytes 1–2: centre frequency segments 0 and 1 as channel numbers.
                let w = b[0], s0 = Int(b[1]), s1 = Int(b[2])
                if w == 1 {
                    if s1 == 0 { info.widthMHz = 80; info.centerChannel = s0 }
                    else if abs(s1 - s0) == 8 { info.widthMHz = 160; info.centerChannel = s1 }
                    else { info.widthMHz = 80; info.centerChannel = s0 }   // 80+80: two separate blocks; the primary's is drawn
                } else if w == 2 { info.widthMHz = 160; info.centerChannel = s0 }
                else if w == 3 { info.widthMHz = 80; info.centerChannel = s0 }
            case heOperation where b.count >= 6:
                if info.standard != "802.11be" { info.standard = "802.11ax" }
                // HE Operation Parameters (3 bytes, little-endian): bit 14 VHT info present, bit 15 co-hosted BSS,
                // bit 17 6 GHz operation info present. Then BSS colour (1) and basic HE-MCS (2), then the optional parts.
                let params = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
                var at = 6
                if params & (1 << 14) != 0 { at += 3 }
                if params & (1 << 15) != 0 { at += 1 }
                if params & (1 << 17) != 0, b.count >= at + 5 {
                    // 6 GHz Operation Information: primary channel, control (bits 0–1 width 20/40/80/160), CCFS0, CCFS1.
                    let w = Int(b[at + 1] & 0x03), s0 = Int(b[at + 2]), s1 = Int(b[at + 3])
                    let mhz = [20, 40, 80, 160][w]
                    if (info.widthMHz ?? 0) <= mhz { info.widthMHz = mhz; info.centerChannel = mhz == 160 && s1 != 0 ? s1 : s0 }
                }
            case ehtOperation where b.count >= 5:
                info.standard = "802.11be"
                // EHT Operation Parameters bit 0: EHT Operation Information present, after the 4-byte basic MCS/NSS set.
                if b[0] & 0x01 != 0, b.count >= 8 {
                    let w = Int(b[5] & 0x07), s0 = Int(b[6]), s1 = Int(b[7])
                    if w <= 4 {
                        let mhz = [20, 40, 80, 160, 320][w]
                        if (info.widthMHz ?? 0) <= mhz { info.widthMHz = mhz; info.centerChannel = mhz >= 160 && s1 != 0 ? s1 : s0 }
                    }
                }
            default: break
            }
        }
        return info
    }
}
