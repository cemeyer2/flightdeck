// Demo mode's Peripherals: an invented desk. A portable SSD stuck at USB 2 behind a charging cable, a Thunderbolt dock
// at full speed with a hub and keyboard behind it, a mouse at 18% after two weeks of draining, AirPods with per-bud
// and case levels, a display, audio devices and a charger. Nothing here comes from this Mac; the link inputs go
// through the real analysis, so the diagnoses are exactly what the page would say for such devices.
import Foundation
import FlightDeckCore

enum DemoPeripherals {
    static func usbInputs() -> [USBLinkInput] {
        let usbC = USBCPortInfo(name: "Port-USB-C@1", transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
                                transportsActive: ["CC", "USB2"], activeCable: false, opticalCable: false)
        let port = USBPortInfo(name: "usb-drd0-port-hs", superSpeedCapable: true, usbC: usbC)
        return [
            USBLinkInput(id: 0x1001, name: "Ridgeline Portable SSD", vendor: "Ridgeline", vendorID: 0x1d6b, productID: 0x7a01,
                         negotiatedMbps: 480, bcdUSB: 0x0210, deviceClass: 0, interfaceClasses: [8], port: port),
            USBLinkInput(id: 0x1002, name: "Harbor USB3 Hub", vendor: "Harbor", vendorID: 0x2e8a, negotiatedMbps: 10000,
                         bcdUSB: 0x0320, deviceClass: 9, tunnelled: true),
            USBLinkInput(id: 0x1003, parent: 0x1002, name: "Keyline Mechanical Keyboard", vendor: "Keyline", vendorID: 0x3a11,
                         negotiatedMbps: 12, bcdUSB: 0x0200, deviceClass: 0, interfaceClasses: [3]),
            USBLinkInput(id: 0x1004, parent: 0x1002, name: "Archive Drive 4TB", vendor: "Stonefield", vendorID: 0x4b22,
                         negotiatedMbps: 5000, bcdUSB: 0x0300, deviceClass: 0, interfaceClasses: [8]),
        ]
    }

    static func thunderbolt() -> [TBSwitchInput] {
        let full = TBPortReading(currentSpeed: 4, currentWidth: 2, supportedSpeed: 12, supportedWidth: 2)
        return [TBSwitchInput(id: 0x2001, name: "Northgate TB4 Dock", vendor: "Northgate", depth: 1, hostSide: full, deviceSide: full, upstreamName: "the Mac")]
    }

    /// Two weeks of a mouse draining ~5.5 points a day from a charge 15 days ago, read every 20 minutes (only changes and
    /// two-hourly repeats are kept, as the real store does).
    static func mouseHistory(now: Date) -> [AccessoryReading] {
        let start = now.addingTimeInterval(-15 * 86_400)
        var out: [AccessoryReading] = []
        var t = start
        while t <= now {
            let days = t.timeIntervalSince(start) / 86_400
            let level = Int((100 - 5.47 * days + (Int(days * 7) % 3 == 0 ? 1 : 0)).rounded())
            if out.last?.levels["Main"] != level || t.timeIntervalSince(out.last!.time) >= 7200 {
                out.append(AccessoryReading(time: t, levels: ["Main": max(18, level)]))
            }
            t = t.addingTimeInterval(1200)
        }
        return out
    }

    static func keyboardHistory(now: Date) -> [AccessoryReading] {
        stride(from: 40.0, through: 0, by: -1).map { (d: Double) -> AccessoryReading in
            let level: Double = 92 - (40 - d) * 0.9
            return AccessoryReading(time: now.addingTimeInterval(-d * 86_400), levels: ["Main": Int(level.rounded())])
        }
    }

    static func airPodsHistory(now: Date) -> [AccessoryReading] {
        [(-3.0, 100, 100, 85), (-2.0, 62, 60, 70), (-1.2, 100, 100, 52), (-0.1, 74, 71, 46)].map { d, l, r, c in
            AccessoryReading(time: now.addingTimeInterval(d * 86_400), levels: ["Left": l, "Right": r, "Case": c])
        }
    }

    static func report(now: Date = Date()) -> PeripheralsReport {
        var r = PeripheralsReport(
            usb: usbInputs().map { d in
                USBDevice(id: d.id, parent: d.parent, name: d.name, vendor: d.vendor, vendorID: d.vendorID, productID: d.productID,
                          speed: d.negotiatedMbps.map(LinkRate.usbName), powerAllocatedmA: d.isHub ? 0 : 500, powerCapabilitymA: 900)
            },
            thunderbolt: [ThunderboltBus(name: "Thunderbolt/USB4 bus 0", ports: ["Port 1 · Up to 40 Gb/s · Device connected"],
                                         devices: ["Northgate TB4 Dock · Northgate"])],
            displays: [DisplayInfo(name: "Built-in Retina Display", gpu: "Apple GPU", displayID: 1, pixels: "3024 x 1964", resolution: "1512 x 982",
                                   refreshHz: 120, connection: "Internal", isMain: true, hdr: true),
                       DisplayInfo(name: "Studio 27 (demo)", gpu: "Apple GPU", displayID: 2, pixels: "5120 x 2880", resolution: "2560 x 1440",
                                   refreshHz: 60, connection: "Thunderbolt/DisplayPort", isMain: false, hdr: false)],
            bluetooth: [BluetoothDevice(name: "AirPods Pro", address: "00:11:22:AA:BB:01", kind: "Headphones", connected: true,
                                        battery: ["Left": 74, "Right": 71, "Case": 46]),
                        BluetoothDevice(name: "Magic Mouse", address: "00:11:22:AA:BB:02", kind: "Mouse", connected: true, battery: ["Main": 18]),
                        BluetoothDevice(name: "Magic Keyboard", address: "00:11:22:AA:BB:03", kind: "Keyboard", connected: true, battery: ["Main": 56]),
                        BluetoothDevice(name: "Travel Speaker", address: "00:11:22:AA:BB:04", kind: "Speaker", connected: false, battery: [:])],
            bluetoothState: "On",
            audio: [AudioDevice(name: "AirPods Pro", manufacturer: "Apple Inc.", inputs: 1, outputs: 2, sampleRate: 48000, transport: "Bluetooth",
                                defaultInput: false, defaultOutput: true),
                    AudioDevice(name: "MacBook Pro Microphone", manufacturer: "Apple Inc.", inputs: 1, outputs: nil, sampleRate: 48000,
                                transport: "Built-in", defaultInput: true, defaultOutput: false)],
            power: PowerAdapterInfo(connected: true, charging: false, name: "96W USB-C Power Adapter", watts: 96, manufacturer: "Apple Inc."))
        r.links = LinkReport(usb: USBLinks.analyze(usbInputs()), thunderbolt: ThunderboltLinks.analyze(thunderbolt()))
        let history = ["Magic Mouse": mouseHistory(now: now), "Magic Keyboard": keyboardHistory(now: now), "AirPods Pro": airPodsHistory(now: now)]
        let current = r.bluetooth.filter(\.connected).map { (name: $0.name, kind: $0.kind, levels: $0.battery) }
        r.accessories = AccessoryForecast.combine(current: current, history: history, since: now.addingTimeInterval(-60 * 86_400))
        return r
    }
}
