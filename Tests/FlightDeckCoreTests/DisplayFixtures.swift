import Foundation
// IORegistry property dictionaries for the Displays tests. `builtInXDR` and `hdmiPortIdle` were dumped from a
// 16" MacBook Pro (M1 Max) with `ioreg -r -c AppleCLCD2 -a -d1` / `ioreg -r -c IOPortTransportStateDisplayPort -a`,
// trimmed to the keys FlightDeck reads and with ElementData blobs and Panel_ID (a serial) removed. The external
// display and active-link fixtures are hand-written in the same shape, since the dumping Mac had no external display.

enum DisplayFixtures {
    static func timing(_ id: Int, _ w: Int, _ h: Int, hTotal: Int, vTotal: Int, rate16: Int, preferred: Bool = false,
                       colors: [[String: Any]], dsc: [Int] = []) -> [String: Any] {
        ["ID": id, "IsPreferred": preferred, "MinimumVariableRefreshRate": 0, "MaximumVariableRefreshRate": 0,
         "HorizontalAttributes": ["Active": w, "Total": hTotal, "SyncRate": 0],
         "VerticalAttributes": ["Active": h, "Total": vTotal, "PreciseSyncRate": rate16, "SyncRate": rate16],
         "ColorModes": colors, "DSCRequiredColorElementIDs": dsc]
    }
    static func color(_ id: Int, depth: Int, encoding: Int = 0, eotf: Int = 0, dsc: Int = 0) -> [String: Any] {
        ["ID": id, "Depth": depth, "PixelEncoding": encoding, "EOTF": eotf, "SupportsDSC": dsc, "Colorimetry": 16, "DynamicRange": 0]
    }

    /// The built-in Liquid Retina XDR panel (real values).
    nonisolated(unsafe) static let builtInXDR: [String: Any] = [
        "IOClass": "AppleCLCD2", "DCPIndex": 0, "DPTimingModeId": 2,
        "DisplayAttributes": ["TiledDisplayInfo": [String: Any](),
                              "ProductAttributes": ["ManufacturerID": "00-10-fa", "ProductID": 53000704963649, "LegacyManufacturerID": 1552],
                              "DisplayAllocation": ["ExtraPipes": 0, "MainUFP": 0, "UseSingleTile": false, "PeerUFP": 0]],
        "ColorElements": [color(1, depth: 8)],
        "IOMFBDisplayRefresh": ["displayRefreshStepMachTime": 100000, "displayRefreshStep": 4166000, "displayMaxRefreshInterval": 178928337,
                                "displayMinRefreshInterval": 35785667, "displayMinRefreshIntervalMachTime": 200000, "displayMaxRefreshIntervalMachTime": 1000000],
        "IOMFBBrightnessLevel": 11004005, "limit_max_physical_brightness": 104857600,
        "TimingElements": [
            timing(2, 3456, 2234, hTotal: 3536, vTotal: 2456, rate16: 7864321, preferred: true, colors: [color(1, depth: 8)]),
            timing(3, 3456, 2234, hTotal: 3536, vTotal: 2456, rate16: 3932160, colors: [color(1, depth: 8)]),
            timing(4, 3456, 2234, hTotal: 3536, vTotal: 2456, rate16: 3145728, colors: [color(1, depth: 8)]),
        ],
    ]

    /// An idle external pipe (real): no DisplayAttributes.
    nonisolated(unsafe) static let idleExternalPipe: [String: Any] = [
        "external": true, "DCPIndex": 1, "IOMFBBrightnessLevel": 65536,
        "IOMFBDisplayRefresh": ["displayMaxRefreshInterval": 178956970, "displayMinRefreshInterval": 71582788],
    ]

    /// A 27" 4K monitor on HDMI offering only 30 Hz at 4K (hand-written).
    nonisolated(unsafe) static let external4K30: [String: Any] = [
        "external": true, "DCPIndex": 1, "DPTimingModeId": 10,
        "DisplayAttributes": ["ProductAttributes": ["ManufacturerID": "GSM", "LegacyManufacturerID": 7789, "ProductID": 30471,
                                                    "ProductName": "LG HDR 4K", "SerialNumber": 123456, "YearOfManufacture": 2021, "WeekOfManufacture": 14],
                              "MaxHorizontalImageSize": 60, "MaxVerticalImageSize": 34,
                              "NativeFormatHorizontalPixels": 3840, "NativeFormatVerticalPixels": 2160],
        "ColorElements": [color(1, depth: 8)],
        "TimingElements": [
            timing(10, 3840, 2160, hTotal: 4400, vTotal: 2250, rate16: 30 << 16, preferred: true, colors: [color(1, depth: 8)]),
            timing(11, 1920, 1080, hTotal: 2200, vTotal: 1125, rate16: 60 << 16, colors: [color(1, depth: 8)]),
        ],
    ]

    /// A 4K 60 Hz monitor sent 8-bit 4:2:2 (hand-written).
    nonisolated(unsafe) static let external422: [String: Any] = [
        "external": true, "DPTimingModeId": 20,
        "DisplayAttributes": ["ProductAttributes": ["LegacyManufacturerID": 4268, "ProductID": 41234, "ProductName": "DELL U2720Q"]],
        "ColorElements": [color(3, depth: 8, encoding: 2)],
        "TimingElements": [timing(20, 3840, 2160, hTotal: 4400, vTotal: 2250, rate16: 60 << 16, preferred: true, colors: [color(3, depth: 8, encoding: 2)])],
    ]

    /// This Mac's HDMI port with nothing attached (real).
    nonisolated(unsafe) static let hdmiPortIdle: [String: Any] = [
        "TransportDescription": "Port-HDMI@1/DisplayPort", "ParentPortTypeDescription": "HDMI", "Active": false, "Tunneled": false,
        "LaneCount": 0, "MaxLaneCount": 4, "LinkRate": 0, "LinkRateDescription": "No Link",
    ]

    /// USB-C DisplayPort Alt Mode through a hub keeping 2 lanes for USB 3 (hand-written).
    nonisolated(unsafe) static let usbCTwoLanesHBR: [String: Any] = [
        "TransportDescription": "Port-USB-C@2/DisplayPort", "ParentPortTypeDescription": "USB-C", "Active": true, "Tunneled": false,
        "LaneCount": 2, "MaxLaneCount": 4, "LinkRate": 0x0A, "LinkRateDescription": "HBR",
    ]

    /// Thunderbolt-tunneled HBR3 × 4 (hand-written).
    nonisolated(unsafe) static let thunderboltHBR3: [String: Any] = [
        "TransportDescription": "Port-USB-C@1/DisplayPort", "ParentPortTypeDescription": "USB-C", "Active": true, "Tunneled": true,
        "LaneCount": 4, "MaxLaneCount": 4, "LinkRate": 0x1E, "LinkRateDescription": "HBR3",
    ]

    /// A minimal EDID: base block for "GSM" product 30471, 2021 week 14, 60 × 34 cm, named "LG HDR 4K", with a
    /// CTA-861 extension holding an HDMI 1.4 vendor block (max TMDS 300 MHz) and HDR static metadata (PQ).
    static func edid(hdmiForum: Bool = false) -> Data {
        var b = [UInt8](repeating: 0, count: 256)
        b[0...7] = [0, 255, 255, 255, 255, 255, 255, 0]
        let pnp = (7 << 10) | (19 << 5) | 13   // G S M
        b[8] = UInt8(pnp >> 8); b[9] = UInt8(pnp & 0xFF)
        b[10] = UInt8(30471 & 0xFF); b[11] = UInt8(30471 >> 8)
        b[12] = 1   // a serial number is present
        b[16] = 14; b[17] = 31; b[18] = 1; b[19] = 4
        b[20] = 0x80 | (2 << 4) | 2   // digital, 8 bits per colour, HDMI
        b[21] = 60; b[22] = 34
        b[54...58] = [0, 0, 0, 0xFC, 0]
        let name = Array("LG HDR 4K\n".utf8)
        for (i, c) in name.enumerated() { b[59 + i] = c }
        for i in (59 + name.count)..<72 { b[i] = 0x20 }
        b[126] = 1
        b[127] = UInt8((256 - b[0..<127].reduce(0) { ($0 + Int($1)) & 0xFF }) & 0xFF)
        var e: [UInt8] = [0x02, 0x03, 0, 0]
        e += [0x67, 0x03, 0x0C, 0x00, 0x10, 0x00, 0x00, 60]   // HDMI VSDB: OUI 00-0C-03, max TMDS 60 × 5 MHz
        if hdmiForum { e += [0x67, 0xD8, 0x5D, 0xC4, 0x01, 120, 0x00, 0x30] }   // HF-VSDB: 600 MHz, FRL 24 Gbit/s
        e += [0xE3, 0x06, 0x05, 0x01]   // HDR static metadata: SDR + PQ
        e[2] = UInt8(e.count)
        for (i, v) in e.enumerated() { b[128 + i] = v }
        b[255] = UInt8((256 - b[128..<255].reduce(0) { ($0 + Int($1)) & 0xFF }) & 0xFF)
        return Data(b)
    }
}
