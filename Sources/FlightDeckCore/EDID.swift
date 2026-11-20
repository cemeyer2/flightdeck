import Foundation
// A small EDID parser: the 128-byte base block (manufacturer, product, manufacture week/year, physical size, name,
// input bit depth and interface) and CTA-861 extensions for the HDMI facts that explain link limits: the HDMI
// vendor block's maximum TMDS clock (HDMI 1.x), the HDMI Forum block's maximum TMDS rate and FRL rate (HDMI 2.x),
// and HDR static metadata. The serial number is detected but never kept.

public struct EDIDInfo: Codable, Sendable, Hashable {
    /// Three-letter PNP ID ("DEL", "GSM", "APP").
    public var manufacturer: String
    public var productCode: Int
    public var week: Int?
    public var year: Int?
    public var widthCm: Int?, heightCm: Int?
    public var name: String?
    public var hasSerial: Bool
    /// Bits per colour the input accepts (digital inputs, EDID 1.4).
    public var inputBitDepth: Int?
    /// "HDMI", "DisplayPort", "DVI" from the base block (EDID 1.4); nil when undefined.
    public var inputInterface: String?
    /// The sink has an HDMI vendor block (it is an HDMI input, possibly behind a DisplayPort adapter).
    public var hdmiSink: Bool
    /// Highest TMDS clock the HDMI input accepts (Hz), from the HDMI or HDMI Forum vendor block.
    public var maxTMDSHz: Double?
    /// Highest HDMI 2.1 FRL rate in Gbit/s (0 = FRL not supported).
    public var maxFRLGbps: Double?
    /// The display advertises HDR transfer functions (PQ or HLG).
    public var hdr: Bool

    public init(manufacturer: String, productCode: Int, week: Int?, year: Int?, widthCm: Int?, heightCm: Int?, name: String?, hasSerial: Bool,
                inputBitDepth: Int?, inputInterface: String?, hdmiSink: Bool, maxTMDSHz: Double?, maxFRLGbps: Double?, hdr: Bool) {
        self.manufacturer = manufacturer; self.productCode = productCode; self.week = week; self.year = year; self.widthCm = widthCm
        self.heightCm = heightCm; self.name = name; self.hasSerial = hasSerial; self.inputBitDepth = inputBitDepth
        self.inputInterface = inputInterface; self.hdmiSink = hdmiSink; self.maxTMDSHz = maxTMDSHz; self.maxFRLGbps = maxFRLGbps; self.hdr = hdr
    }

    /// The HDMI version the input's limits imply.
    public var hdmiVersion: DisplayBandwidth.HDMIVersion? {
        guard hdmiSink else { return nil }
        if let f = maxFRLGbps, f > 0 { return .v2_1 }
        guard let t = maxTMDSHz else { return .v1_4 }
        return t > 340e6 ? .v2_0 : .v1_4
    }
}

public enum EDID {
    /// Parses an EDID (base block plus any extensions). Nil if the header or base checksum is wrong.
    public static func parse(_ data: Data) -> EDIDInfo? {
        let b = [UInt8](data)
        guard b.count >= 128, b[0...7] == [0, 255, 255, 255, 255, 255, 255, 0] else { return nil }
        guard b[0..<128].reduce(0, { ($0 + Int($1)) & 0xFF }) == 0 else { return nil }
        let m = Int(b[8]) << 8 | Int(b[9])
        let letters = [(m >> 10) & 31, (m >> 5) & 31, m & 31].map { Character(UnicodeScalar(UInt8(64 + $0))) }
        let product = Int(b[10]) | Int(b[11]) << 8
        let serialField = b[12...15].contains { $0 != 0 }
        let week = (1...54).contains(Int(b[16])) ? Int(b[16]) : nil
        let year = b[17] > 0 ? 1990 + Int(b[17]) : nil
        var info = EDIDInfo(manufacturer: String(letters), productCode: product, week: week, year: year,
                            widthCm: b[21] > 0 ? Int(b[21]) : nil, heightCm: b[22] > 0 ? Int(b[22]) : nil, name: nil,
                            hasSerial: serialField, inputBitDepth: nil, inputInterface: nil, hdmiSink: false,
                            maxTMDSHz: nil, maxFRLGbps: nil, hdr: false)
        if b[20] & 0x80 != 0, b[19] >= 4 {   // digital input, EDID 1.4 fields
            info.inputBitDepth = [1: 6, 2: 8, 3: 10, 4: 12, 5: 14, 6: 16][Int(b[20] >> 4) & 7]
            info.inputInterface = [1: "DVI", 2: "HDMI", 3: "HDMI", 5: "DisplayPort"][Int(b[20]) & 15]
        }
        for d in stride(from: 54, to: 126, by: 18) where b[d] == 0 && b[d + 1] == 0 {
            let text = String(bytes: b[(d + 5)..<(d + 18)].prefix { $0 != 0x0A }, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
            if b[d + 3] == 0xFC { info.name = text }
            if b[d + 3] == 0xFF { info.hasSerial = true }
        }
        var ext = 128
        while ext + 128 <= b.count {
            if b[ext] == 0x02 { parseCTA(Array(b[ext..<(ext + 128)]), into: &info) }
            ext += 128
        }
        return info
    }

    /// CTA-861 data blocks: vendor-specific (tag 3) and extended-tag HDR static metadata (tag 7, code 6).
    static func parseCTA(_ e: [UInt8], into info: inout EDIDInfo) {
        let end = min(Int(e[2]), 127)
        var i = 4
        while i < end {
            let tag = e[i] >> 5, len = Int(e[i] & 31)
            guard i + len < 128 else { break }
            let p = Array(e[(i + 1)..<(i + 1 + len)])
            if tag == 3, len >= 3 {
                let oui = Int(p[0]) | Int(p[1]) << 8 | Int(p[2]) << 16
                if oui == 0x000C03 {
                    info.hdmiSink = true
                    if len >= 7, p[6] > 0 { info.maxTMDSHz = max(info.maxTMDSHz ?? 0, Double(p[6]) * 5e6) }
                } else if oui == 0xC45DD8 {
                    info.hdmiSink = true
                    if len >= 5, p[4] > 0 { info.maxTMDSHz = max(info.maxTMDSHz ?? 0, Double(p[4]) * 5e6) }
                    if len >= 7 { info.maxFRLGbps = [0: 0, 1: 9, 2: 18, 3: 24, 4: 32, 5: 40, 6: 48][Int(p[6] >> 4)] }
                }
            } else if tag == 7, len >= 2, p[0] == 6 {
                info.hdr = p[1] & 0b1100 != 0   // SMPTE ST 2084 (PQ) or HLG
            }
            i += 1 + len
        }
    }
}
