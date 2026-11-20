import Foundation
// Peripherals › link speeds: what each USB device negotiated, what the device supports and what the port (or the hub
// in front of it) supports, and a plain-English diagnosis when the link is slower than both ends could do.
//
// Inputs come from documented IORegistry keys (IOUSBHostFamilyDefinitions.h): "UsbLinkSpeed" (bits/s) or
// "USBSpeed" (tIOUSBHostConnectionSpeed), "bcdUSB", "bDeviceClass", "UsbTunnel", and the interfaces' bInterfaceClass;
// the port's "UsbProtocol (3.x)" / "UsbProtocolCompanion (3.x)" and the USB-C port it maps to ("UsbIOPort").
// What a device *supports* is only partly knowable: a USB 3 device that fell back to USB 2 reports bcdUSB 0x0210 like
// a real USB 2 device does, so that case is only diagnosed when the descriptor says USB 3, or the device is an SSD
// (USB 2-only SSDs essentially don't exist), and the latter is marked as inferred. Parsing and maths are pure, so
// tests run on fixture dictionaries; LinkSpeedRead.swift does the IOKit walk.

public enum LinkRate {
    /// "480 Mb/s", "10 Gb/s", "1.5 Mb/s".
    public static func text(_ mbps: Double) -> String {
        if mbps >= 1000 { let g = mbps / 1000; return (g == g.rounded() ? String(format: "%.0f", g) : String(format: "%.1f", g)) + " Gb/s" }
        return (mbps == mbps.rounded() ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps)) + " Mb/s"
    }

    /// "USB 2 (480 Mb/s)", "USB 3 (10 Gb/s)".
    public static func usbName(_ mbps: Double) -> String {
        let gen = mbps <= 12 ? "USB 1" : mbps <= 480 ? "USB 2" : "USB 3"
        return "\(gen) (\(text(mbps)))"
    }

    /// tIOUSBHostConnectionSpeed ("USBSpeed") in Mb/s.
    public static func usbSpeedCode(_ code: Int) -> Double? {
        switch code { case 1: 12; case 2: 1.5; case 3: 480; case 4: 5000; case 5: 10000; case 6: 20000; default: nil }
    }

    /// The legacy IOUSBFamily "Device Speed" key (0 low, 1 full, 2 high, 3 super, 4 super+).
    public static func legacySpeedCode(_ code: Int) -> Double? {
        switch code { case 0: 1.5; case 1: 12; case 2: 480; case 3: 5000; case 4: 10000; default: nil }
    }

    /// Roughly the best sustained transfer a drive gets over a USB link of this rate, in MB/s (protocol overhead
    /// included: USB 2 bulk transfers top out near 40 MB/s, 5 Gb/s near 450, 10 Gb/s near 1,000).
    public static func usbStorageMBps(_ mbps: Double) -> Double {
        switch mbps {
        case ..<13: return 1
        case ..<500: return 40
        case ..<5500: return 450
        case ..<11000: return 1000
        default: return 2000
        }
    }
}

/// The USB-C receptacle a USB port belongs to (AppleHPM "Port-USB-C@n").
public struct USBCPortInfo: Hashable, Sendable, Codable {
    public var name: String
    /// "CC", "USB2", "USB3", "CIO" (Thunderbolt/USB4), "DisplayPort".
    public var transportsSupported: [String] = []
    public var transportsActive: [String] = []
    public var activeCable: Bool?
    public var opticalCable: Bool?
    /// The e-marker's cable type where the port reports one.
    public var cableType: String?
    public var superSpeedActive: Bool?
    public var supportsThunderbolt: Bool { transportsSupported.contains("CIO") }

    public init(name: String, transportsSupported: [String] = [], transportsActive: [String] = [], activeCable: Bool? = nil,
                opticalCable: Bool? = nil, cableType: String? = nil, superSpeedActive: Bool? = nil) {
        self.name = name; self.transportsSupported = transportsSupported; self.transportsActive = transportsActive
        self.activeCable = activeCable; self.opticalCable = opticalCable; self.cableType = cableType; self.superSpeedActive = superSpeedActive
    }

    public init(props d: [String: Any], name fallback: String) {
        self.init(name: (d["Description"] as? String) ?? fallback,
                  transportsSupported: d["TransportsSupported"] as? [String] ?? [], transportsActive: d["TransportsActive"] as? [String] ?? [],
                  activeCable: d["ActiveCable"] as? Bool, opticalCable: d["OpticalCable"] as? Bool,
                  cableType: (d["CableType"] as? String) ?? (d["Cable Type"] as? String),
                  superSpeedActive: d["IOAccessoryUSBSuperSpeedActive"] as? Bool)
    }

    /// "passive cable", "active cable", "optical cable", plus the e-marker type when known.
    public var cableText: String? {
        var parts: [String] = []
        if opticalCable == true { parts.append("optical cable") } else if activeCable == true { parts.append("active cable") }
        else if activeCable == false { parts.append("passive cable") }
        if let cableType { parts.append(cableType) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The root (xHCI) port a USB device is plugged into.
public struct USBPortInfo: Hashable, Sendable, Codable {
    public var name: String
    /// True when the port speaks USB 3 (it is the 3.x port, or a 2.0 port with a 3.x companion); nil = not reported.
    public var superSpeedCapable: Bool?
    public var usbC: USBCPortInfo?

    public init(name: String, superSpeedCapable: Bool?, usbC: USBCPortInfo? = nil) {
        self.name = name; self.superSpeedCapable = superSpeedCapable; self.usbC = usbC
    }

    public init(props d: [String: Any], name fallback: String, usbC: USBCPortInfo? = nil) {
        let ss: Bool? = (d["UsbProtocol (3.x)"] as? Bool) == true || d["UsbProtocolCompanion (3.x)"] != nil ? true
            : (d["UsbProtocol (2.0)"] as? Bool) == true || d["UsbProtocolCompanion (2.0)"] != nil ? false : nil
        let raw = (d["name"] as? Data).flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        self.init(name: raw ?? fallback, superSpeedCapable: ss, usbC: usbC)
    }

    /// The most the port carries for USB, when it can be known: Mac Thunderbolt/USB4 ports carry USB at 10 Gb/s.
    public var maxMbps: Double? {
        if superSpeedCapable == false { return 480 }
        if usbC?.supportsThunderbolt == true { return 10000 }
        return nil
    }
}

/// One IOUSBHostDevice, reduced to what the link analysis needs.
public struct USBLinkInput: Hashable, Sendable {
    public var id: UInt64
    public var parent: UInt64?
    public var name: String
    public var vendor: String?
    public var vendorID: Int?
    public var productID: Int?
    public var negotiatedMbps: Double?
    public var bcdUSB: Int?
    public var deviceClass: Int?
    public var interfaceClasses: [Int] = []
    /// Reached through a Thunderbolt/USB4 tunnel (a dock), so the Mac's own port doesn't set the limit.
    public var tunnelled = false
    /// The root port, for devices plugged straight into the Mac; nil behind a hub.
    public var port: USBPortInfo?

    public var isHub: Bool { deviceClass == 9 }
    public var isStorage: Bool { deviceClass == 8 || interfaceClasses.contains(8) }

    public init(id: UInt64, parent: UInt64? = nil, name: String, vendor: String? = nil, vendorID: Int? = nil, productID: Int? = nil,
                negotiatedMbps: Double?, bcdUSB: Int? = nil, deviceClass: Int? = nil, interfaceClasses: [Int] = [],
                tunnelled: Bool = false, port: USBPortInfo? = nil) {
        self.id = id; self.parent = parent; self.name = name; self.vendor = vendor; self.vendorID = vendorID; self.productID = productID
        self.negotiatedMbps = negotiatedMbps; self.bcdUSB = bcdUSB; self.deviceClass = deviceClass; self.interfaceClasses = interfaceClasses
        self.tunnelled = tunnelled; self.port = port
    }

    /// From an IOUSBHostDevice's properties. "UsbLinkSpeed" (bits/s) wins over the speed codes.
    public init(id: UInt64, parent: UInt64?, props d: [String: Any], interfaceClasses: [Int] = [], port: USBPortInfo? = nil) {
        func n(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        let link = (d["UsbLinkSpeed"] as? NSNumber).map { $0.doubleValue / 1e6 }.flatMap { $0 > 0 ? $0 : nil }
        let mbps = link ?? n("USBSpeed").flatMap(LinkRate.usbSpeedCode) ?? n("Device Speed").flatMap(LinkRate.legacySpeedCode)
        self.init(id: id, parent: parent, name: (d["kUSBProductString"] as? String) ?? (d["USB Product Name"] as? String) ?? "USB device",
                  vendor: (d["kUSBVendorString"] as? String) ?? (d["USB Vendor Name"] as? String),
                  vendorID: n("idVendor"), productID: n("idProduct"), negotiatedMbps: mbps, bcdUSB: n("bcdUSB"),
                  deviceClass: n("bDeviceClass"), interfaceClasses: interfaceClasses,
                  tunnelled: (d["UsbTunnel"] as? Bool) ?? false, port: port)
    }
}

/// What one end of a link supports: a rate when known, and how it is known.
public struct LinkSupport: Hashable, Sendable {
    public var mbps: Double?
    public var text: String
    /// True when the rate is an inference (e.g. "it's an SSD"), not read from the device or port.
    public var inferred = false
    public init(mbps: Double?, text: String, inferred: Bool = false) { self.mbps = mbps; self.text = text; self.inferred = inferred }
}

public struct LinkDiagnosis: Hashable, Sendable {
    public enum Level: String, Sendable, Comparable {
        case ok, note, slow
        public static func < (a: Level, b: Level) -> Bool { [Level.ok, .note, .slow].firstIndex(of: a)! < [Level.ok, .note, .slow].firstIndex(of: b)! }
    }
    public var level: Level
    /// One sentence: what's happening and why.
    public var summary: String
    /// What to try, when there is something to try.
    public var advice: String?
    public init(level: Level, summary: String, advice: String? = nil) { self.level = level; self.summary = summary; self.advice = advice }
    public var text: String { [summary, advice].compactMap { $0 }.joined(separator: " — ") }
}

public struct USBLink: Identifiable, Hashable, Sendable {
    public var id: UInt64
    /// The hub it hangs off, nil on a root port.
    public var parent: UInt64?
    public var name: String
    public var vendor: String?
    public var isHub: Bool
    public var isStorage: Bool
    public var negotiatedMbps: Double?
    public var device: LinkSupport
    public var port: LinkSupport
    /// Hubs between the Mac and the device, nearest the Mac first.
    public var hubs: [String]
    /// For drives: the most they can transfer over this link, about, in MB/s.
    public var effectiveMBps: Double?
    public var diagnosis: LinkDiagnosis
}
