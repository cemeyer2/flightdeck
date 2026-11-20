// Tests for the Displays page: bandwidth arithmetic, link-rate decoding, IORegistry parsing (real and hand-written
// fixtures in DisplayFixtures), EDID parsing, pairing in DisplayCollector.assemble, the diagnoses, the session
// history and the MCP output. A live smoke test skips where no display is online (CI VMs may have only a virtual one).
import XCTest
@testable import FlightDeckCore

final class DisplayBandwidthTests: XCTestCase {
    func testCVTReducedBlanking() {
        // VESA CVT-RB2: 4K 60 Hz is 522.61 MHz, 2560 × 1440 at 60 Hz 234.59 MHz.
        XCTAssertEqual(DisplayBandwidth.cvtRB2PixelClock(width: 3840, height: 2160, refreshHz: 60) / 1e6, 522.6, accuracy: 1)
        XCTAssertEqual(DisplayBandwidth.cvtRB2PixelClock(width: 2560, height: 1440, refreshHz: 60) / 1e6, 234.59, accuracy: 0.1)
        XCTAssertEqual(DisplayBandwidth.cvtRB2PixelClock(width: 0, height: 1, refreshHz: 60), 0)
    }

    func testRequiredRates() {
        let cta4k60 = DisplayBandwidth.typicalPixelClock(width: 3840, height: 2160, refreshHz: 60)
        XCTAssertEqual(cta4k60, 594e6, accuracy: 1)
        XCTAssertEqual(DisplayBandwidth.requiredGbps(pixelClockHz: cta4k60, depth: 8, chroma: .rgb), 14.256, accuracy: 0.001)
        XCTAssertEqual(DisplayBandwidth.requiredGbps(pixelClockHz: cta4k60, depth: 8, chroma: .ycbcr422), 9.504, accuracy: 0.001)
        XCTAssertEqual(DisplayBandwidth.requiredGbps(pixelClockHz: cta4k60, depth: 8, chroma: .ycbcr420), 7.128, accuracy: 0.001)
        XCTAssertEqual(DisplayBandwidth.dscGbps(pixelClockHz: cta4k60), 7.128, accuracy: 0.001)
    }

    func testDisplayPortCapacity() {
        XCTAssertEqual(DisplayBandwidth.dpPayloadGbps(laneGbps: 8.1, lanes: 4), 25.92, accuracy: 0.01)
        XCTAssertEqual(DisplayBandwidth.dpPayloadGbps(laneGbps: 2.7, lanes: 2), 4.32, accuracy: 0.01)
        XCTAssertEqual(DisplayBandwidth.dpPayloadGbps(laneGbps: 20, lanes: 4), 77.58, accuracy: 0.01)   // 128b/132b
        // HBR2 × 4 (17.28) carries 4K60 RGB 8-bit but not 10-bit at CTA timing; HBR × 2 needs 4:2:0.
        let pclk = 594e6
        XCTAssertEqual(DisplayBandwidth.bestFormat(pixelClockHz: pclk, capacityGbps: 17.28)?.depth, 8)
        XCTAssertEqual(DisplayBandwidth.bestFormat(pixelClockHz: pclk, capacityGbps: 17.28)?.chroma, .rgb)
        XCTAssertNil(DisplayBandwidth.bestFormat(pixelClockHz: pclk, capacityGbps: 4.32))
        XCTAssertEqual(DisplayBandwidth.bestFormat(pixelClockHz: 297e6, capacityGbps: 4.32)?.chroma, .ycbcr420)
    }

    func testHDMI() {
        XCTAssertEqual(DisplayBandwidth.minimumHDMI(pixelClockHz: 297e6, depth: 8, chroma: .rgb), .v1_4)   // 4K30
        XCTAssertEqual(DisplayBandwidth.minimumHDMI(pixelClockHz: 594e6, depth: 8, chroma: .rgb), .v2_0)   // 4K60
        XCTAssertEqual(DisplayBandwidth.minimumHDMI(pixelClockHz: 594e6, depth: 10, chroma: .rgb), .v2_1)  // 4K60 10-bit
        XCTAssertEqual(DisplayBandwidth.minimumHDMI(pixelClockHz: 594e6, depth: 10, chroma: .ycbcr422), .v2_0)
        XCTAssertEqual(DisplayBandwidth.minimumHDMI(pixelClockHz: 594e6, depth: 8, chroma: .ycbcr420), .v1_4)  // 4K60 4:2:0 at 297 MHz
        XCTAssertEqual(DisplayBandwidth.tmdsHz(pixelClockHz: 594e6, depth: 10, chroma: .rgb), 742.5e6, accuracy: 1)
        XCTAssertNil(DisplayBandwidth.minimumHDMI(pixelClockHz: 2_000e6, depth: 10, chroma: .rgb))
    }

    func testLinkRateDecoding() {
        XCTAssertEqual(DisplayBandwidth.decodeLinkRate(raw: 0x1E, description: nil)?.name, "HBR3")
        XCTAssertEqual(DisplayBandwidth.decodeLinkRate(raw: 0x14, description: nil)?.gbps, 5.4)
        XCTAssertEqual(DisplayBandwidth.decodeLinkRate(raw: nil, description: "UHBR13.5")?.gbps, 13.5)
        XCTAssertEqual(DisplayBandwidth.decodeLinkRate(raw: nil, description: "HBR2")?.name, "HBR2")
        XCTAssertEqual(DisplayBandwidth.decodeLinkRate(raw: nil, description: "8.1 Gbps")?.name, "HBR3")
        XCTAssertEqual(DisplayBandwidth.decodeLinkRate(raw: 5400, description: nil)?.name, "HBR2")      // Mbit/s
        XCTAssertEqual(DisplayBandwidth.decodeLinkRate(raw: 810_000, description: nil)?.name, "HBR3")   // 10 kbit/s units
        XCTAssertNil(DisplayBandwidth.decodeLinkRate(raw: 0, description: "No Link"))
        XCTAssertNil(DisplayBandwidth.decodeLinkRate(raw: 77, description: nil))
    }
}

final class DisplayRegistryTests: XCTestCase {
    func testBuiltInFramebuffer() throws {
        let f = try XCTUnwrap(DisplayRegistry.parseFramebuffer(DisplayFixtures.builtInXDR))
        XCTAssertFalse(f.external)
        XCTAssertEqual(f.vendorID, 1552)
        XCTAssertFalse(f.hasSerial)
        XCTAssertNil(f.year)
        XCTAssertEqual(f.timings.count, 3)
        let t = try XCTUnwrap(f.currentTiming)
        XCTAssertEqual(t.width, 3456); XCTAssertEqual(t.height, 2234)
        XCTAssertEqual(t.refreshHz, 120, accuracy: 0.01)
        XCTAssertEqual(t.pixelClockHz / 1e6, 1042.1, accuracy: 0.5)
        XCTAssertEqual(f.nativeWidth, 3456)
        XCTAssertEqual(f.activeColor?.depth, 8)
        XCTAssertEqual(f.activeColor?.chroma, .rgb)
        XCTAssertEqual(f.minRefreshInterval ?? 0, 1.0 / 120, accuracy: 1e-5)
        XCTAssertEqual(f.maxRefreshInterval ?? 0, 1.0 / 24, accuracy: 1e-4)
        XCTAssertEqual(f.brightnessNits ?? 0, 167.9, accuracy: 0.1)
        XCTAssertEqual(f.peakNits ?? 0, 1600, accuracy: 0.1)
    }

    func testIdlePipeAndExternal() throws {
        XCTAssertNil(DisplayRegistry.parseFramebuffer(DisplayFixtures.idleExternalPipe))
        let f = try XCTUnwrap(DisplayRegistry.parseFramebuffer(DisplayFixtures.external4K30))
        XCTAssertTrue(f.external)
        XCTAssertEqual(f.productName, "LG HDR 4K")
        XCTAssertEqual(f.year, 2021); XCTAssertEqual(f.week, 14)
        XCTAssertTrue(f.hasSerial)
        XCTAssertEqual(f.imageWidthCm, 60)
        XCTAssertEqual(f.currentTiming?.refreshHz, 30)
        XCTAssertEqual(f.currentTiming?.pixelClockHz, 297e6)
        XCTAssertNil(f.brightnessNits, "backlight values are only read for built-in panels")
        let s = try XCTUnwrap(DisplayRegistry.parseFramebuffer(DisplayFixtures.external422))
        XCTAssertEqual(s.activeColor?.chroma, .ycbcr422)
    }

    func testLinks() {
        let idle = DisplayRegistry.parseLink(DisplayFixtures.hdmiPortIdle)
        XCTAssertFalse(idle.active)
        XCTAssertEqual(idle.port, "Port-HDMI@1")
        XCTAssertEqual(idle.transport, .hdmi)
        XCTAssertEqual(idle.summary, "no link trained")
        let hub = DisplayRegistry.parseLink(DisplayFixtures.usbCTwoLanesHBR)
        XCTAssertTrue(hub.active)
        XCTAssertEqual(hub.transport, .usbC)
        XCTAssertEqual(hub.capacityGbps ?? 0, 4.32, accuracy: 0.01)
        XCTAssertEqual(hub.summary, "HBR × 2 lanes (4.3 Gbit/s usable)")
        let tb = DisplayRegistry.parseLink(DisplayFixtures.thunderboltHBR3)
        XCTAssertEqual(tb.transport, .thunderbolt)
        XCTAssertEqual(tb.capacityGbps ?? 0, 25.92, accuracy: 0.01)
    }

    func testEDID() throws {
        let e = try XCTUnwrap(EDID.parse(DisplayFixtures.edid()))
        XCTAssertEqual(e.manufacturer, "GSM")
        XCTAssertEqual(e.productCode, 30471)
        XCTAssertEqual(e.year, 2021); XCTAssertEqual(e.week, 14)
        XCTAssertEqual(e.widthCm, 60); XCTAssertEqual(e.heightCm, 34)
        XCTAssertEqual(e.name, "LG HDR 4K")
        XCTAssertTrue(e.hasSerial)
        XCTAssertEqual(e.inputBitDepth, 8); XCTAssertEqual(e.inputInterface, "HDMI")
        XCTAssertTrue(e.hdmiSink); XCTAssertTrue(e.hdr)
        XCTAssertEqual(e.maxTMDSHz, 300e6)
        XCTAssertEqual(e.hdmiVersion, .v1_4)
        let f = try XCTUnwrap(EDID.parse(DisplayFixtures.edid(hdmiForum: true)))
        XCTAssertEqual(f.maxTMDSHz, 600e6)
        XCTAssertEqual(f.maxFRLGbps, 24)
        XCTAssertEqual(f.hdmiVersion, .v2_1)
        var bad = [UInt8](DisplayFixtures.edid()); bad[30] ^= 0xFF
        XCTAssertNil(EDID.parse(Data(bad)), "bad checksum")
        XCTAssertNil(EDID.parse(Data([1, 2, 3])))
        XCTAssertEqual(DisplayCollector.edidCode("GSM"), 7789)
        XCTAssertEqual(DisplayCollector.edidCode("APP"), 1552)
    }
}
