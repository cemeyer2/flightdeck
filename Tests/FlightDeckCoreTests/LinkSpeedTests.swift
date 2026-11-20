import XCTest
@testable import FlightDeckCore

final class LinkSpeedTests: XCTestCase {
    typealias Fx = PeripheralFixtures

    func rootPort(_ d: [String: Any] = Fx.hsPort) -> USBPortInfo {
        USBPortInfo(props: d, name: "port", usbC: USBCPortInfo(props: Fx.usbCPort, name: "Port-USB-C@3"))
    }

    func testRates() {
        XCTAssertEqual(LinkRate.text(480), "480 Mb/s")
        XCTAssertEqual(LinkRate.text(1.5), "1.5 Mb/s")
        XCTAssertEqual(LinkRate.text(10000), "10 Gb/s")
        XCTAssertEqual(LinkRate.usbName(480), "USB 2 (480 Mb/s)")
        XCTAssertEqual(LinkRate.usbName(5000), "USB 3 (5 Gb/s)")
        XCTAssertEqual(LinkRate.usbSpeedCode(5), 10000)
        XCTAssertNil(LinkRate.usbSpeedCode(0))
        XCTAssertEqual(LinkRate.usbStorageMBps(480), 40)
    }

    func testRealPortFixtures() {
        let hs = rootPort(), ss = rootPort(Fx.ssPort)
        XCTAssertEqual(hs.name, "usb-drd2-port-hs")
        XCTAssertEqual(hs.superSpeedCapable, true, "a USB 2 port with a 3.x companion is part of a USB 3 port")
        XCTAssertEqual(ss.superSpeedCapable, true)
        XCTAssertEqual(hs.usbC?.supportsThunderbolt, true)
        XCTAssertEqual(hs.maxMbps, 10000)
        XCTAssertEqual(hs.usbC?.cableText, "passive cable")
        let usb2Only = USBPortInfo(props: ["UsbProtocol (2.0)": true], name: "p")
        XCTAssertEqual(usb2Only.superSpeedCapable, false)
        XCTAssertEqual(usb2Only.maxMbps, 480)
        XCTAssertNil(USBPortInfo(props: [:], name: "p").superSpeedCapable)
    }

    func testDeviceParsing() {
        let d = USBLinkInput(id: 1, parent: nil, props: Fx.ssdAtUSB2, interfaceClasses: [8], port: rootPort())
        XCTAssertEqual(d.name, "Portable SSD T7")
        XCTAssertEqual(d.negotiatedMbps, 480)
        XCTAssertEqual(d.bcdUSB, 0x0210)
        XCTAssertTrue(d.isStorage)
        XCTAssertFalse(d.isHub)
        // UsbLinkSpeed wins over the code; the legacy key is the last resort.
        XCTAssertEqual(USBLinkInput(id: 2, parent: nil, props: ["USBSpeed": 4, "UsbLinkSpeed": 10_000_000_000]).negotiatedMbps, 10000)
        XCTAssertEqual(USBLinkInput(id: 3, parent: nil, props: ["Device Speed": 2]).negotiatedMbps, 480)
        XCTAssertNil(USBLinkInput(id: 4, parent: nil, props: [:]).negotiatedMbps)
    }

    func testSSDStuckAtUSB2() throws {
        let links = USBLinks.analyze([USBLinkInput(id: 1, parent: nil, props: Fx.ssdAtUSB2, interfaceClasses: [8], port: rootPort())])
        let l = try XCTUnwrap(links.first)
        XCTAssertEqual(l.diagnosis.level, .slow)
        XCTAssertTrue(l.device.inferred)
        XCTAssertEqual(l.port.mbps, 10000)
        XCTAssertTrue(l.diagnosis.summary.hasPrefix("Portable SSD T7 is running at USB 2 (480 Mb/s) but supports 5 Gb/s (probably)"), l.diagnosis.summary)
        XCTAssertTrue(l.diagnosis.summary.contains("cable or adapter"))
        XCTAssertTrue(l.diagnosis.summary.contains("about 40 MB/s"))
        XCTAssertTrue(l.diagnosis.advice?.contains("10 Gb/s") == true)
        let f = USBLinks.findings(links, now: Date())
        XCTAssertEqual(f.map(\.id), ["usb-slow:1"])
        XCTAssertEqual(f.first?.destination, "Peripherals")
    }

    func testDriveAtFullSpeed() throws {
        let l = try XCTUnwrap(USBLinks.analyze([USBLinkInput(id: 1, parent: nil, props: Fx.driveAt10G, interfaceClasses: [8], port: rootPort(Fx.ssPort))]).first)
        XCTAssertEqual(l.diagnosis.level, .ok)
        XCTAssertEqual(l.effectiveMBps, 1000)
        XCTAssertTrue(l.diagnosis.summary.hasPrefix("Running at full speed: USB 3 (10 Gb/s)"))
        XCTAssertTrue(USBLinks.findings([l], now: Date()).isEmpty)
    }

    func testUSB3DriveBehindUSB2Hub() throws {
        let hub = USBLinkInput(id: 10, parent: nil, props: Fx.usb2Hub, port: rootPort())
        let drive = USBLinkInput(id: 11, parent: 10, props: Fx.flashBehindHub, interfaceClasses: [8])
        let links = USBLinks.analyze([hub, drive])
        let d = try XCTUnwrap(links.first { $0.id == 11 })
        XCTAssertEqual(d.hubs, ["USB2.0 Hub"])
        XCTAssertFalse(d.device.inferred, "the descriptor says USB 3")
        XCTAssertEqual(d.diagnosis.level, .slow)
        XCTAssertTrue(d.diagnosis.summary.contains("the hub USB2.0 Hub is USB 2-only"), d.diagnosis.summary)
        XCTAssertTrue(d.diagnosis.advice?.contains("straight into the Mac") == true)
        XCTAssertEqual(links.first { $0.id == 10 }?.diagnosis.level, .ok)
    }

    func testUSB3HubWithUSB2Cable() throws {
        // A USB 3 hub's two halves; the drive hangs off the USB 2 half, so the cable from drive to hub is to blame.
        var hs = Fx.usb2Hub; hs["kUSBProductString"] = "USB2.1 Hub"; hs["bcdUSB"] = 0x0210
        var ss = Fx.usb2Hub; ss["kUSBProductString"] = "USB3.1 Hub"; ss["USBSpeed"] = 5; ss["bcdUSB"] = 0x0310
        let links = USBLinks.analyze([USBLinkInput(id: 1, parent: nil, props: hs, port: rootPort()),
                                      USBLinkInput(id: 2, parent: nil, props: ss, port: rootPort(Fx.ssPort)),
                                      USBLinkInput(id: 3, parent: 1, props: Fx.flashBehindHub, interfaceClasses: [8])])
        let d = try XCTUnwrap(links.first { $0.id == 3 })
        XCTAssertEqual(d.port.mbps, 10000)
        XCTAssertTrue(d.diagnosis.summary.contains("USB2.1 Hub has USB 3, so the cable between them"), d.diagnosis.summary)
    }

    func testSlowInputDeviceIsFine() throws {
        let l = try XCTUnwrap(USBLinks.analyze([USBLinkInput(id: 1, parent: nil, props: Fx.keyboard, interfaceClasses: [3], port: rootPort())]).first)
        XCTAssertEqual(l.diagnosis.level, .ok)
        XCTAssertNil(l.effectiveMBps)
        XCTAssertTrue(l.diagnosis.summary.contains("plenty"))
    }

    func testUnknownCapabilityIsNotDiagnosed() throws {
        // A USB 2.1 thumb drive with no SSD-like name: it may be a USB 3 device that fell back, but that can't be known.
        let props: [String: Any] = ["kUSBProductString": "Flash Disk", "USBSpeed": 3, "bcdUSB": 0x0210]
        let l = try XCTUnwrap(USBLinks.analyze([USBLinkInput(id: 1, parent: nil, props: props, interfaceClasses: [8], port: rootPort())]).first)
        XCTAssertNil(l.device.mbps)
        XCTAssertNotEqual(l.diagnosis.level, .slow)
    }

    func testUSB2OnlyPort() throws {
        let port = USBPortInfo(props: ["UsbProtocol (2.0)": true], name: "p")
        let l = try XCTUnwrap(USBLinks.analyze([USBLinkInput(id: 1, parent: nil, props: Fx.flashBehindHub, interfaceClasses: [8], port: port)]).first)
        XCTAssertTrue(l.diagnosis.summary.contains("this port is USB 2 only"))
    }

    func testThunderboltCodes() {
        XCTAssertEqual(ThunderboltLinks.laneGbps(8), 10)
        XCTAssertEqual(ThunderboltLinks.laneGbps(4), 20)
        XCTAssertEqual(ThunderboltLinks.maxLaneGbps(12), 20, "the Mac's real supported mask: Gen 2 and Gen 3")
        XCTAssertEqual(ThunderboltLinks.maxLaneGbps(14), 40)
        XCTAssertEqual(ThunderboltLinks.maxLanes(2), 2)
        XCTAssertEqual(ThunderboltLinks.lanes(1), 1)
        XCTAssertEqual(ThunderboltLinks.lanes(4), 3)
    }

    func tb(_ host: [String: Any], _ dev: [String: Any], name: String = "TB4 Dock", depth: Int = 1) -> ThunderboltLink {
        ThunderboltLinks.analyze([TBSwitchInput(id: 7, name: name, vendor: "Dockmaker", depth: depth,
                                                hostSide: TBPortReading(props: host), deviceSide: TBPortReading(props: dev), upstreamName: "Display")])[0]
    }

    func testDockAt20() {
        let l = tb(Fx.hostLaneSlow, Fx.dockUpstreamSlow)
        XCTAssertEqual(l.currentGbps, 20)
        XCTAssertEqual(l.maxGbps, 40)
        XCTAssertEqual(l.currentMode, "Gen 2 ×2")
        XCTAssertEqual(l.diagnosis.level, .slow)
        XCTAssertTrue(l.diagnosis.summary.hasPrefix("This Thunderbolt dock is linked at 20 Gb/s (Gen 2 ×2), not 40 Gb/s (Gen 3 ×2)"), l.diagnosis.summary)
        XCTAssertTrue(l.diagnosis.advice?.contains("40 Gb/s") == true)
    }

    func testDockAtFullSpeed() {
        let l = tb(Fx.hostLaneFull, Fx.dockUpstreamFull)
        XCTAssertEqual(l.currentGbps, 40)
        XCTAssertEqual(l.diagnosis.level, .ok)
        XCTAssertEqual(l.diagnosis.summary, "Full speed: 40 Gb/s (Gen 3 ×2).")
    }

    func testSingleLaneAndChain() {
        let l = tb(Fx.singleLane, Fx.dockUpstreamFull.merging(["Current Link Width": 1]) { $1 }, name: "SSD Enclosure", depth: 2)
        XCTAssertEqual(l.currentGbps, 20)
        XCTAssertTrue(l.diagnosis.summary.contains("only one of its two lanes"))
        XCTAssertTrue(l.diagnosis.summary.contains("daisy-chained behind Display"))
    }

    func testThunderboltMissingSide() {
        let l = ThunderboltLinks.analyze([TBSwitchInput(id: 1, name: "Display", vendor: nil, depth: 1, hostSide: TBPortReading(props: Fx.hostLaneFull), deviceSide: nil)])[0]
        XCTAssertEqual(l.currentGbps, 40)
        XCTAssertNil(l.maxGbps)
        XCTAssertEqual(l.diagnosis.level, .ok)
    }

    func testWatchRaisesOncePerPlugIn() {
        let w = PeripheralWatch()
        let slow = USBLinks.analyze([USBLinkInput(id: 1, parent: nil, props: Fx.ssdAtUSB2, interfaceClasses: [8], port: rootPort())])
        let t = Date()
        w.ingest(LinkReport(usb: slow), now: t)
        XCTAssertEqual(w.findings(now: t).count, 1)
        w.ingest(LinkReport(usb: slow), now: t.addingTimeInterval(60))
        XCTAssertEqual(w.findings(now: t.addingTimeInterval(60)).first?.since, t, "not raised again")
        XCTAssertTrue(w.findings(now: t.addingTimeInterval(PeripheralWatch.linger + 1)).isEmpty, "expires")
        w.ingest(LinkReport(usb: slow), now: t.addingTimeInterval(PeripheralWatch.linger + 2))
        XCTAssertTrue(w.findings(now: t.addingTimeInterval(PeripheralWatch.linger + 2)).isEmpty, "same plug-in: not again")
        // Unplugged and plugged in again: a new registry entry ID, so a new finding.
        var again = slow; again[0].id = 2
        w.ingest(LinkReport(usb: []), now: t.addingTimeInterval(4000))
        w.ingest(LinkReport(usb: again), now: t.addingTimeInterval(4010))
        XCTAssertEqual(w.findings(now: t.addingTimeInterval(4010)).map(\.id), ["usb-slow:2"])
    }

    func testLiveReadDoesNotCrash() throws {
        let r = LinkSpeedReader.read()
        if r.usb.isEmpty && r.thunderbolt.isEmpty { throw XCTSkip("no USB or Thunderbolt devices connected") }
        for l in r.usb { XCTAssertFalse(l.diagnosis.summary.isEmpty) }
    }
}
