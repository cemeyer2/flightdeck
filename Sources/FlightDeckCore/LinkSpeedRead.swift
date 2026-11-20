import Foundation
import IOKit
// Peripherals › link speeds, the IOKit side: reads IOUSBHostDevice nodes (with their interfaces and root port, and the
// USB-C port that port belongs to) and IOThunderboltSwitch routers into the pure inputs LinkAnalysis and
// ThunderboltLinks work on. Only IORegistry reads: a few milliseconds, no subprocess.

public struct LinkReport: Sendable {
    public var usb: [USBLink] = []
    public var thunderbolt: [ThunderboltLink] = []
    public init(usb: [USBLink] = [], thunderbolt: [ThunderboltLink] = []) { self.usb = usb; self.thunderbolt = thunderbolt }
    public var problems: Int { usb.filter { $0.diagnosis.level == .slow }.count + thunderbolt.filter { $0.diagnosis.level == .slow }.count }
}

public enum LinkSpeedReader {
    public static func read() -> LinkReport {
        LinkReport(usb: USBLinks.analyze(usbInputs()), thunderbolt: ThunderboltLinks.analyze(thunderboltInputs()))
    }

    static func props(_ s: io_registry_entry_t) -> [String: Any]? {
        var p: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(s, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return p?.takeRetainedValue() as? [String: Any]
    }

    static func entryID(_ s: io_registry_entry_t) -> UInt64 { var id: UInt64 = 0; IORegistryEntryGetRegistryEntryID(s, &id); return id }

    static func name(_ s: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(s, &buf)
        return String(cString: buf)
    }

    /// Calls `body` with each child in the service plane.
    static func children(_ s: io_registry_entry_t, _ body: (io_registry_entry_t) -> Void) {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(s, kIOServicePlane, &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let c = IOIteratorNext(it), c != 0 { body(c); IOObjectRelease(c) }
    }

    /// Each matching service; `body` must not keep the object.
    static func each(_ cls: String, _ body: (io_registry_entry_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 { body(s); IOObjectRelease(s) }
    }

    // MARK: USB

    static func usbInputs() -> [USBLinkInput] {
        var out: [USBLinkInput] = []
        each("IOUSBHostDevice") { s in
            guard let d = props(s) else { return }
            var classes: [Int] = []
            children(s) { c in
                if IOObjectConformsTo(c, "IOUSBHostInterface") != 0,
                   let n = IORegistryEntryCreateCFProperty(c, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                    classes.append(n.intValue)
                }
            }
            let parentHub = Peripherals.usbParent(s)
            out.append(USBLinkInput(id: entryID(s), parent: parentHub, props: d, interfaceClasses: classes, port: parentHub == nil ? rootPort(s) : nil))
        }
        return out
    }

    /// The port node directly above a root device, and the USB-C receptacle it names in "UsbIOPort".
    static func rootPort(_ s: io_registry_entry_t) -> USBPortInfo? {
        var p: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(s, kIOServicePlane, &p) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(p) }
        guard let d = props(p) else { return nil }
        var usbC: USBCPortInfo?
        if let path = d["UsbIOPort"] as? String {
            let c = IORegistryEntryFromPath(kIOMainPortDefault, path)
            if c != 0 {
                if let cp = props(c) { usbC = USBCPortInfo(props: cp, name: name(c)) }
                IOObjectRelease(c)
            }
        }
        return USBPortInfo(props: d, name: name(p), usbC: usbC)
    }

    // MARK: Thunderbolt

    static func tbProps(_ s: io_registry_entry_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }

    static func thunderboltInputs() -> [TBSwitchInput] {
        var out: [TBSwitchInput] = []
        each("IOThunderboltSwitch") { s in
            guard let d = props(s), let depth = (d["Depth"] as? NSNumber)?.intValue, depth >= 1 else { return }
            // The device's upstream lane adapter: its child port numbered "Upstream Port Number".
            let up = (d["Upstream Port Number"] as? NSNumber)?.intValue
            var deviceSide: TBPortReading?
            children(s) { c in
                if deviceSide == nil, IOObjectConformsTo(c, "IOThunderboltPort") != 0, let n = tbProps(c, "Port Number"), n == up, let cp = props(c) {
                    deviceSide = TBPortReading(props: cp)
                }
            }
            // The other end: the nearest IOThunderboltPort above, and the switch that owns it.
            var hostSide: TBPortReading?, upstreamName: String?
            var cur = s; IOObjectRetain(cur)
            while true {
                var p: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(cur, kIOServicePlane, &p) == KERN_SUCCESS else { break }
                IOObjectRelease(cur); cur = p
                if hostSide == nil, IOObjectConformsTo(p, "IOThunderboltPort") != 0 { hostSide = props(p).map(TBPortReading.init(props:)) }
                if IOObjectConformsTo(p, "IOThunderboltSwitch") != 0 {
                    upstreamName = IORegistryEntryCreateCFProperty(p, "Device Model Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                    if tbProps(p, "Depth") == 0 { upstreamName = "the Mac" }
                    break
                }
            }
            IOObjectRelease(cur)
            out.append(TBSwitchInput(id: entryID(s), name: (d["Device Model Name"] as? String) ?? "Thunderbolt device",
                                     vendor: d["Device Vendor Name"] as? String, depth: depth,
                                     hostSide: hostSide, deviceSide: deviceSide, upstreamName: upstreamName))
        }
        return out
    }
}
