import Foundation
// IORegistry dictionaries for the link-speed tests. "Real" ones were dumped with `ioreg -l -w0` on a MacBook Pro
// (M1 Pro, macOS 26) with nothing plugged in, and trimmed to the keys the parser reads (no serials or UIDs).
// Device dictionaries are hand-written in the same shape, since CI has no USB or Thunderbolt devices: an SSD stuck
// at USB 2, a USB 3 drive behind a USB 2 hub, a 10 Gb/s drive at full speed, a keyboard, and a dock at 20 Gb/s.

enum PeripheralFixtures {
    static let usbC3Path = "IOService:/AppleARMPE/arm-io/AppleT600xIO/i2c0@9B040000/AppleS5L8940XI2CController/hpmBusManager@6B/AppleHPMBusController/hpm2/AppleHPMARMI2C/AppleHPMDevice@3B/Port-USB-C@3"

    /// Real: the USB 2 side of a Thunderbolt port's xHCI (AppleUSB20XHCIARMPort), which names its USB 3 companion.
    static var hsPort: [String: Any] { [
        "UsbProtocol (1.x)": true, "UsbProtocol (2.0)": true, "UsbIOPort": usbC3Path, "PortType": 2,
        "UsbProtocolCompanion (3.x)": "IOService:/AppleARMPE/arm-io/AppleT600xIO/usb-drd2@2280000/AppleT6000USBXHCI@02000000/usb-drd2-port-ss@02200000",
        "name": Data("usb-drd2-port-hs\0".utf8), "locationID": 35651584,
    ] }

    /// Real: the USB 3 side (AppleT8103USB30XHCIPort).
    static var ssPort: [String: Any] { [
        "UsbProtocol (3.x)": true, "UsbIOPort": usbC3Path, "PortType": 2, "PortNumber": 3,
        "UsbProtocolCompanion (2.0)": "IOService:/AppleARMPE/arm-io/AppleT600xIO/usb-drd2@2280000/AppleT6000USBXHCI@02000000/usb-drd2-port-hs@02100000",
        "name": Data("usb-drd2-port-ss\0".utf8), "locationID": 35651584,
    ] }

    /// Real: AppleHPM's Port-USB-C@3 (AppleTCControllerType10), idle.
    static var usbCPort: [String: Any] { [
        "PortTypeDescription": "USB-C", "Description": "Port-USB-C@3", "ActiveCable": false, "OpticalCable": false,
        "TransportsSupported": ["CC", "USB2", "USB3", "CIO", "DisplayPort"], "TransportsActive": [String](),
        "IOAccessoryUSBSuperSpeedActive": false, "ConnectionActive": false, "PortNumber": 3,
    ] }

    /// Real: the Mac's own Thunderbolt lane adapter (IOThunderboltPort@1 on the root switch), nothing connected.
    static var hostLanePort: [String: Any] { [
        "Supported Link Width": 2, "Target Link Width": 1, "Current Link Width": 1, "Lane": 1, "Port Number": 1,
        "Target Link Speed": 12, "Link Bandwidth": 100, "Dual-Link Port": 2, "Supported Link Speed": 12, "Adapter Type": 1,
        "Dual-Link Port RID": 0, "Current Link Speed": 8,
    ] }

    // MARK: Hand-written devices

    /// An SSD that fell back to USB 2 (so it reports bcdUSB 0x0210), mass-storage interface.
    static var ssdAtUSB2: [String: Any] { [
        "kUSBProductString": "Portable SSD T7", "kUSBVendorString": "Samsung", "idVendor": 0x04e8, "idProduct": 0x4001,
        "USBSpeed": 3, "UsbLinkSpeed": 480_000_000, "bcdUSB": 0x0210, "bDeviceClass": 0,
        "UsbPowerSinkAllocation": 500, "locationID": 0x02100000,
    ] }

    /// A USB 3 descriptor (bcdUSB 0x0320) drive at full 10 Gb/s.
    static var driveAt10G: [String: Any] { [
        "kUSBProductString": "Extreme Pro", "kUSBVendorString": "SanDisk", "idVendor": 0x0781, "idProduct": 0x5591,
        "USBSpeed": 5, "UsbLinkSpeed": 10_000_000_000, "bcdUSB": 0x0320, "bDeviceClass": 0,
    ] }

    /// A USB 3.0 (0x0300) flash drive behind a USB 2-only hub.
    static var flashBehindHub: [String: Any] { [
        "kUSBProductString": "DataStick 3.0", "kUSBVendorString": "Generic", "idVendor": 0x1234, "idProduct": 0x0001,
        "USBSpeed": 3, "bcdUSB": 0x0300, "bDeviceClass": 0,
    ] }

    static var usb2Hub: [String: Any] { [
        "kUSBProductString": "USB2.0 Hub", "idVendor": 0x05e3, "idProduct": 0x0608, "USBSpeed": 3, "bcdUSB": 0x0200, "bDeviceClass": 9,
    ] }

    static var keyboard: [String: Any] { [
        "kUSBProductString": "Keyboard K120", "kUSBVendorString": "Logi", "idVendor": 0x046d, "idProduct": 0xc31c,
        "USBSpeed": 1, "bcdUSB": 0x0110, "bDeviceClass": 0,
    ] }

    /// A Thunderbolt 4 dock's upstream lane adapter, linked at Gen 2 ×2 (20 Gb/s) though both ends do Gen 3.
    static var dockUpstreamSlow: [String: Any] { [
        "Port Number": 1, "Adapter Type": 1, "Supported Link Speed": 12, "Supported Link Width": 2,
        "Current Link Speed": 8, "Current Link Width": 2,
    ] }
    static var hostLaneSlow: [String: Any] { hostLanePort.merging(["Current Link Speed": 8, "Current Link Width": 2]) { $1 } }
    static var hostLaneFull: [String: Any] { hostLanePort.merging(["Current Link Speed": 4, "Current Link Width": 2]) { $1 } }
    static var dockUpstreamFull: [String: Any] { dockUpstreamSlow.merging(["Current Link Speed": 4]) { $1 } }
    static var singleLane: [String: Any] { hostLanePort.merging(["Current Link Speed": 4, "Current Link Width": 1]) { $1 } }
}
