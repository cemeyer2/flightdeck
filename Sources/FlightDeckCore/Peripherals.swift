import Foundation
import IOKit
import CoreGraphics

// The Peripherals destination: what is plugged into or paired with this Mac. USB comes straight from the IORegistry
// (IOUSBHostDevice nodes, which carry speed and power in documented keys); Thunderbolt, displays, Bluetooth, audio and
// the power adapter come from one `system_profiler -json` call, which takes about a second, so it runs only when the
// page appears or Refresh is pressed, off the main thread. Fields a device doesn't report stay nil and are shown as
// "not reported", never filled in.

public struct USBDevice: Identifiable, Hashable, Sendable {
    public var id: UInt64            // IORegistry entry ID
    public var parent: UInt64?       // nearest IOUSBHostDevice ancestor (a hub), nil for root-port devices
    public var name: String
    public var vendor: String?
    public var vendorID: Int?
    public var productID: Int?
    /// Negotiated connection speed, e.g. "480 Mb/s (High Speed)".
    public var speed: String?
    /// mA the device is expected to draw from VBUS (5 V), and the most it may draw (UsbPowerSinkAllocation/Capability).
    public var powerAllocatedmA: Int?
    public var powerCapabilitymA: Int?
    public init(id: UInt64, parent: UInt64?, name: String, vendor: String?, vendorID: Int?, productID: Int?, speed: String?,
         powerAllocatedmA: Int?, powerCapabilitymA: Int?) {
        self.id = id; self.parent = parent; self.name = name; self.vendor = vendor; self.vendorID = vendorID; self.productID = productID
        self.speed = speed; self.powerAllocatedmA = powerAllocatedmA; self.powerCapabilitymA = powerCapabilitymA
    }
}

public struct ThunderboltBus: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    /// Per receptacle (physical port): its id, link speed and status ("No device connected" …).
    public var ports: [String]
    /// Connected devices (name, vendor, speed where reported), in chain order.
    public var devices: [String]
    public init(name: String, ports: [String], devices: [String]) { self.name = name; self.ports = ports; self.devices = devices }
}

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public var id: String { "\(displayID ?? 0)-\(name)" }
    public var name: String
    public var gpu: String?
    public var displayID: UInt32?
    public var pixels: String?           // native panel pixels "3456 x 2234"
    public var resolution: String?       // UI resolution "1728 x 1117"
    public var refreshHz: Double?
    public var connection: String?       // "Internal", "DisplayPort", …
    public var isMain: Bool
    /// Filled in by the UI from NSScreen (which belongs on the main thread): nil = not determined.
    public var hdr: Bool?
    public init(name: String, gpu: String?, displayID: UInt32?, pixels: String?, resolution: String?, refreshHz: Double?, connection: String?,
         isMain: Bool, hdr: Bool?) {
        self.name = name; self.gpu = gpu; self.displayID = displayID; self.pixels = pixels; self.resolution = resolution
        self.refreshHz = refreshHz; self.connection = connection; self.isMain = isMain; self.hdr = hdr
    }
}

public struct BluetoothDevice: Identifiable, Hashable, Sendable {
    public var id: String { address ?? name }
    public var name: String
    public var address: String?
    public var kind: String?
    public var connected: Bool
    /// e.g. ["Main": 80] or ["Left": 70, "Right": 75, "Case": 40], in %.
    public var battery: [String: Int]
    public init(name: String, address: String?, kind: String?, connected: Bool, battery: [String: Int]) {
        self.name = name; self.address = address; self.kind = kind; self.connected = connected; self.battery = battery
    }
}

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var manufacturer: String?
    public var inputs: Int?
    public var outputs: Int?
    public var sampleRate: Double?
    public var transport: String?
    public var defaultInput: Bool
    public var defaultOutput: Bool
    public init(name: String, manufacturer: String?, inputs: Int?, outputs: Int?, sampleRate: Double?, transport: String?,
         defaultInput: Bool, defaultOutput: Bool) {
        self.name = name; self.manufacturer = manufacturer; self.inputs = inputs; self.outputs = outputs; self.sampleRate = sampleRate
        self.transport = transport; self.defaultInput = defaultInput; self.defaultOutput = defaultOutput
    }
}

public struct PowerAdapterInfo: Hashable, Sendable {
    public var connected: Bool?
    public var charging: Bool?
    public var name: String?
    public var watts: Int?
    public var manufacturer: String?
    public init(connected: Bool?, charging: Bool?, name: String?, watts: Int?, manufacturer: String?) {
        self.connected = connected; self.charging = charging; self.name = name; self.watts = watts; self.manufacturer = manufacturer
    }
}

public struct PeripheralsReport: Sendable {
    public var usb: [USBDevice]
    public var thunderbolt: [ThunderboltBus]
    public var displays: [DisplayInfo]
    public var bluetooth: [BluetoothDevice]
    public var bluetoothState: String?
    public var audio: [AudioDevice]
    public var power: PowerAdapterInfo?
    /// Set when system_profiler couldn't be run or its output didn't parse; the IOKit sections still fill.
    public var profilerError: String?
    /// Negotiated vs supported link speeds with diagnoses (LinkAnalysis.swift, ThunderboltLink.swift).
    public var links = LinkReport()
    /// Accessory batteries now and their saved history (AccessoryBattery.swift).
    public var accessories: [AccessoryBattery] = []
    public init(usb: [USBDevice], thunderbolt: [ThunderboltBus], displays: [DisplayInfo], bluetooth: [BluetoothDevice], bluetoothState: String? = nil,
         audio: [AudioDevice], power: PowerAdapterInfo?) {
        self.usb = usb; self.thunderbolt = thunderbolt; self.displays = displays; self.bluetooth = bluetooth
        self.bluetoothState = bluetoothState; self.audio = audio; self.power = power
    }
}

public enum Peripherals {
    /// Blocking: system_profiler (~1 s) plus IORegistry walks. Call off the main thread.
    /// With a recorder, this load's battery levels are saved and the saved history joins the report.
    public static func collect(recorder: AccessoryRecorder? = nil) -> PeripheralsReport {
        var r = collectDevices()
        r.links = LinkSpeedReader.read()
        r.accessories = accessories(bluetooth: r.bluetooth, hid: hidBatteries(), recorder: recorder)
        return r
    }

    /// Bluetooth levels (system_profiler, plus the IORegistry for Apple's HID accessories) and USB HID accessories
    /// that only the IORegistry reports, recorded and joined with up to 60 days of history.
    static func accessories(bluetooth: [BluetoothDevice], hid: [String: Int], recorder: AccessoryRecorder?, now: Date = Date()) -> [AccessoryBattery] {
        var current = bluetooth.filter { $0.connected && !$0.battery.isEmpty }.map { (name: $0.name, kind: $0.kind, levels: $0.battery) }
        for (name, pct) in hid.sorted(by: { $0.key < $1.key }) where !current.contains(where: { $0.name == name }) {
            current.append((name: name, kind: nil, levels: ["Main": pct]))
        }
        recorder?.record(Dictionary(current.map { ($0.name, $0.levels) }, uniquingKeysWith: { a, _ in a }), now: now)
        let history = recorder?.store.history(since: now.addingTimeInterval(-Double(AccessoryStore.retentionDays) * 86_400), now: now) ?? [:]
        return AccessoryForecast.combine(current: current, history: history, since: now.addingTimeInterval(-Double(AccessoryStore.retentionDays) * 86_400))
    }

    static func collectDevices() -> PeripheralsReport {
        var r = PeripheralsReport(usb: usbDevices(), thunderbolt: [], displays: [], bluetooth: [], audio: [], power: nil)
        let types = ["SPThunderboltDataType", "SPDisplaysDataType", "SPBluetoothDataType", "SPAudioDataType", "SPPowerDataType"]
        guard let out = Shell.run("/usr/sbin/system_profiler", ["-json"] + types, timeout: 30),
              let root = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
            r.profilerError = "system_profiler didn't return data"
            return r
        }
        r.thunderbolt = parseThunderbolt(root)
        r.displays = parseDisplays(root).map { d in
            var d = d
            // system_profiler's refresh rate is in the resolution string; CoreGraphics is asked when it's missing.
            if d.refreshHz == nil, let id = d.displayID, let m = CGDisplayCopyDisplayMode(id), m.refreshRate > 0 { d.refreshHz = m.refreshRate }
            return d
        }
        (r.bluetooth, r.bluetoothState) = parseBluetooth(root)
        mergeHIDBatteries(&r.bluetooth, hidBatteries())
        r.audio = parseAudio(root)
        r.power = parsePower(root)
        return r
    }

    // MARK: USB (IOKit)

    /// tIOUSBHostConnectionSpeed (IOUSBHostFamilyDefinitions.h) as text.
    static func speedName(_ s: Int) -> String? {
        switch s {
        case 1: "12 Mb/s (Full Speed)"; case 2: "1.5 Mb/s (Low Speed)"; case 3: "480 Mb/s (High Speed)"
        case 4: "5 Gb/s (SuperSpeed)"; case 5: "10 Gb/s (SuperSpeed+)"; case 6: "20 Gb/s (SuperSpeed+ 2x2)"
        default: nil
        }
    }

    /// One device from its IORegistry properties. Names prefer the device's own string descriptors.
    static func usbDevice(id: UInt64, parent: UInt64?, props d: [String: Any]) -> USBDevice {
        func n(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        let name = (d["kUSBProductString"] as? String) ?? (d["USB Product Name"] as? String) ?? "USB device"
        return USBDevice(id: id, parent: parent, name: name, vendor: (d["kUSBVendorString"] as? String) ?? (d["USB Vendor Name"] as? String),
                         vendorID: n("idVendor"), productID: n("idProduct"), speed: n("USBSpeed").flatMap(speedName),
                         powerAllocatedmA: n("UsbPowerSinkAllocation"), powerCapabilitymA: n("UsbPowerSinkCapability"))
    }

    static func usbDevices() -> [USBDevice] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [USBDevice] = []
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            var id: UInt64 = 0; IORegistryEntryGetRegistryEntryID(s, &id)
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = props?.takeRetainedValue() as? [String: Any] else { continue }
            out.append(usbDevice(id: id, parent: usbParent(s), props: d))
        }
        return out
    }

    /// Walks up the IOService plane to the nearest ancestor that is itself a USB device (i.e. the hub it hangs off).
    static func usbParent(_ s: io_registry_entry_t) -> UInt64? {
        var cur = s; IOObjectRetain(cur)
        defer { IOObjectRelease(cur) }
        while true {
            var p: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(cur, kIOServicePlane, &p) == KERN_SUCCESS else { return nil }
            IOObjectRelease(cur); cur = p
            if IOObjectConformsTo(p, "IOUSBHostDevice") != 0 { var id: UInt64 = 0; IORegistryEntryGetRegistryEntryID(p, &id); return id }
        }
    }

    /// Depth-first order with nesting depth, for drawing the tree. Devices whose parent isn't in the list are roots.
    public static func usbTree(_ devices: [USBDevice]) -> [(device: USBDevice, depth: Int)] {
        let ids = Set(devices.map(\.id))
        let kids = Dictionary(grouping: devices) { d in d.parent.flatMap { ids.contains($0) ? $0 : nil } ?? 0 }
        var out: [(USBDevice, Int)] = []
        func walk(_ p: UInt64, _ depth: Int) {
            for d in (kids[p] ?? []).sorted(by: { $0.name < $1.name }) { out.append((d, depth)); walk(d.id, depth + 1) }
        }
        walk(0, 0)
        return out
    }

    // MARK: system_profiler JSON

    /// system_profiler uses localisation keys as values ("spdisplays_yes", "attrib_on", "receptacle_no_devices_connected");
    /// this turns them into readable text by dropping the prefix and underscores.
    static func readable(_ s: String) -> String {
        var v = s
        for p in ["spdisplays_", "spaudio_", "coreaudio_device_type_", "attrib_", "receptacle_", "sppower_"] where v.hasPrefix(p) { v = String(v.dropFirst(p.count)) }
        v = v.replacingOccurrences(of: "_", with: " ")
        return v.prefix(1).uppercased() + v.dropFirst()
    }

    static func items(_ root: [String: Any], _ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }

    public static func parseThunderbolt(_ root: [String: Any]) -> [ThunderboltBus] {
        items(root, "SPThunderboltDataType").map { bus in
            let ports = bus.keys.filter { $0.hasPrefix("receptacle_") }.sorted().compactMap { k -> String? in
                guard let r = bus[k] as? [String: Any] else { return nil }
                let id = (r["receptacle_id_key"] as? String).map { "Port \($0)" } ?? "Port"
                return [id, r["current_speed_key"] as? String, (r["receptacle_status_key"] as? String).map(readable)].compactMap { $0 }.joined(separator: " · ")
            }
            var devices: [String] = []
            // Daisy-chained devices nest: each device's own `_items` holds the next one down the chain.
            func walk(_ list: [[String: Any]]) {
                for d in list {
                    let name = (d["device_name_key"] as? String) ?? (d["_name"] as? String) ?? "Device"
                    devices.append([name, d["vendor_name_key"] as? String, d["mode_key"].flatMap { $0 as? String }.map(readable)].compactMap { $0 }.joined(separator: " · "))
                    walk(d["_items"] as? [[String: Any]] ?? [])
                }
            }
            walk(bus["_items"] as? [[String: Any]] ?? [])
            let name = ((bus["_name"] as? String) ?? "Bus").replacingOccurrences(of: "thunderboltusb4_bus_", with: "Thunderbolt/USB4 bus ")
            return ThunderboltBus(name: name, ports: ports, devices: devices)
        }
    }

    /// "1728 x 1117 @ 120.00Hz" -> ("1728 x 1117", 120).
    static func splitResolution(_ s: String) -> (String, Double?) {
        let parts = s.components(separatedBy: " @ ")
        let hz = parts.count > 1 ? Double(parts[1].replacingOccurrences(of: "Hz", with: "").trimmingCharacters(in: .whitespaces)) : nil
        return (parts[0], hz)
    }

    public static func parseDisplays(_ root: [String: Any]) -> [DisplayInfo] {
        items(root, "SPDisplaysDataType").flatMap { gpu in
            (gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? []).map { d in
                let (res, hz) = (d["_spdisplays_resolution"] as? String).map(splitResolution) ?? (nil, nil)
                return DisplayInfo(name: d["_name"] as? String ?? "Display", gpu: gpu["sppci_model"] as? String ?? gpu["_name"] as? String,
                                   displayID: (d["_spdisplays_displayID"] as? String).flatMap { UInt32($0) },
                                   pixels: d["_spdisplays_pixels"] as? String, resolution: res, refreshHz: hz,
                                   connection: (d["spdisplays_connection_type"] as? String).map(readable),
                                   isMain: (d["spdisplays_main"] as? String) == "spdisplays_yes", hdr: nil)
            }
        }
    }

    /// Bluetooth devices: "device_connected"/"device_not_connected" are arrays of single-key dictionaries {name: props}.
    /// Battery keys are "device_batteryLevelMain|Left|Right|Case" with values like "80%".
    public static func parseBluetooth(_ root: [String: Any]) -> ([BluetoothDevice], String?) {
        guard let bt = items(root, "SPBluetoothDataType").first else { return ([], nil) }
        let state = ((bt["controller_properties"] as? [String: Any])?["controller_state"] as? String).map(readable)
        var out: [BluetoothDevice] = []
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in bt[key] as? [[String: Any]] ?? [] {
                for (name, v) in entry {
                    let p = v as? [String: Any] ?? [:]
                    var battery: [String: Int] = [:]
                    for (k, val) in p where k.hasPrefix("device_batteryLevel") {
                        if let s = val as? String, let n = Int(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) {
                            battery[String(k.dropFirst("device_batteryLevel".count))] = n
                        } else if let n = val as? NSNumber { battery[String(k.dropFirst("device_batteryLevel".count))] = n.intValue }
                    }
                    out.append(BluetoothDevice(name: name, address: p["device_address"] as? String, kind: p["device_minorType"] as? String,
                                               connected: connected, battery: battery))
                }
            }
        }
        return (out.sorted { ($0.connected ? 0 : 1, $0.name.lowercased()) < ($1.connected ? 0 : 1, $1.name.lowercased()) }, state)
    }

    /// Battery levels that Apple's own Bluetooth accessories (Magic Mouse/Keyboard/Trackpad) publish in the IORegistry
    /// as "BatteryPercent" on AppleDeviceManagementHIDEventService, keyed by product name.
    static func hidBatteries() -> [String: Int] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iter) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iter) }
        var out: [String: Int] = [:]
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            if let name = prop("Product") as? String, let pct = (prop("BatteryPercent") as? NSNumber)?.intValue { out[name] = pct }
        }
        return out
    }

    /// Adds IORegistry battery levels to connected devices of the same name that system_profiler gave none for.
    static func mergeHIDBatteries(_ devices: inout [BluetoothDevice], _ hid: [String: Int]) {
        for i in devices.indices where devices[i].connected && devices[i].battery.isEmpty {
            if let pct = hid[devices[i].name] { devices[i].battery["Main"] = pct }
        }
    }

    public static func parseAudio(_ root: [String: Any]) -> [AudioDevice] {
        items(root, "SPAudioDataType").flatMap { $0["_items"] as? [[String: Any]] ?? [] }.map { d in
            AudioDevice(name: d["_name"] as? String ?? "Audio device", manufacturer: d["coreaudio_device_manufacturer"] as? String,
                        inputs: (d["coreaudio_device_input"] as? NSNumber)?.intValue, outputs: (d["coreaudio_device_output"] as? NSNumber)?.intValue,
                        sampleRate: (d["coreaudio_device_srate"] as? NSNumber)?.doubleValue,
                        transport: (d["coreaudio_device_transport"] as? String).map(readable),
                        defaultInput: (d["coreaudio_default_audio_input_device"] as? String) == "spaudio_yes",
                        defaultOutput: (d["coreaudio_default_audio_output_device"] as? String) == "spaudio_yes")
        }
    }

    /// The "sppower_ac_charger_information" section. Booleans are the strings "TRUE"/"FALSE"; watts is a string.
    /// nil when the section is absent.
    public static func parsePower(_ root: [String: Any]) -> PowerAdapterInfo? {
        guard let c = items(root, "SPPowerDataType").first(where: { ($0["_name"] as? String) == "sppower_ac_charger_information" }) else { return nil }
        func b(_ k: String) -> Bool? { (c[k] as? String).map { $0 == "TRUE" } }
        return PowerAdapterInfo(connected: b("sppower_battery_charger_connected"), charging: b("sppower_battery_is_charging"),
                                name: c["sppower_ac_charger_name"] as? String,
                                watts: (c["sppower_ac_charger_watts"] as? String).flatMap { Int($0) } ?? (c["sppower_ac_charger_watts"] as? NSNumber)?.intValue,
                                manufacturer: c["sppower_ac_charger_manufacturer"] as? String)
    }
}
