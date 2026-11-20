// Displays: pairing sources in DisplayCollector.assemble, the diagnoses, session history and the `displays` MCP output.
import XCTest
@testable import FlightDeckCore

final class DisplayDiagnosisTests: XCTestCase {
    static func mode(_ w: Int, _ h: Int, px: Int? = nil, pxh: Int? = nil, _ hz: Double, native: Bool = false, current: Bool = false) -> DisplayModeInfo {
        DisplayModeInfo(width: w, height: h, pixelWidth: px ?? w, pixelHeight: pxh ?? h, refreshHz: hz, native: native, current: current)
    }

    static let builtInCG: CGDisplayData = {
        let cur = mode(1728, 1117, px: 3456, pxh: 2234, 120, native: true, current: true)
        return CGDisplayData(id: 1, builtIn: true, main: true, vendor: 1552, model: 41040, widthMM: 344, heightMM: 223, mode: cur,
                             modes: [cur, mode(1728, 1117, px: 3456, pxh: 2234, 60, native: true)])
    }()
    static func externalCG(modes: [DisplayModeInfo], vendor: UInt32 = 7789, model: UInt32 = 30471) -> CGDisplayData {
        CGDisplayData(id: 5, builtIn: false, main: false, vendor: vendor, model: model, serial: 123456, widthMM: 0, heightMM: 0,
                      mode: modes.first(where: \.current), modes: modes)
    }
    static let xdrScreen = DisplayScreenFacts(displayID: 1, name: "Built-in Retina Display", maximumFPS: 120, minimumRefreshInterval: 1.0 / 120,
                                              maximumRefreshInterval: 1.0 / 24, updateGranularity: 0.004, edrNow: 1.2, edrPotential: 16, edrReference: 0,
                                              colorSpace: "Color LCD", backingScale: 2)

    func assemble(_ cg: [CGDisplayData], fbs: [[String: Any]], links: [[String: Any]] = [], edids: [EDIDInfo] = [], screens: [DisplayScreenFacts] = [xdrScreen]) -> DisplaysReport {
        DisplayCollector.assemble(cg: cg, screens: screens, framebuffers: fbs.compactMap(DisplayRegistry.parseFramebuffer),
                                  links: links.map(DisplayRegistry.parseLink), edids: edids, gpus: [1: "Apple M1 Max"],
                                  brightness: (0.5, "DisplayServices (read-only)"), history: [], now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testBuiltInOnly() throws {
        let r = assemble([Self.builtInCG], fbs: [DisplayFixtures.builtInXDR, DisplayFixtures.idleExternalPipe], links: [DisplayFixtures.hdmiPortIdle])
        let d = try XCTUnwrap(r.displays.first)
        XCTAssertEqual(d.name, "Built-in Retina Display")
        XCTAssertEqual(d.transport, .builtIn)
        XCTAssertNotNil(d.framebuffer)
        XCTAssertEqual(d.diagonalInches ?? 0, 16.1, accuracy: 0.1)
        XCTAssertEqual(d.panelHint, "mini-LED with local dimming (Liquid Retina XDR)")
        XCTAssertEqual(d.brightness, 0.5)
        XCTAssertEqual(d.screen?.variableRange?.lowerBound ?? 0, 24, accuracy: 0.01)
        XCTAssertEqual(d.gpu, "Apple M1 Max")
        XCTAssertTrue(d.diagnoses.isEmpty, "\(d.diagnoses.map(\.title))")
        XCTAssertTrue(r.unassignedLinks.isEmpty, "an idle port is not a link")
    }

    func testStuckAt30OverHDMI() throws {
        let modes = [Self.mode(3840, 2160, 30, native: true), Self.mode(1920, 1080, px: 3840, pxh: 2160, 30, current: true), Self.mode(1920, 1080, 60)]
        var hdmi = DisplayFixtures.hdmiPortIdle
        hdmi["Active"] = true; hdmi["LaneCount"] = 4; hdmi["LinkRate"] = 0x14; hdmi["LinkRateDescription"] = "HBR2"
        let edid = try XCTUnwrap(EDID.parse(DisplayFixtures.edid()))
        let r = assemble([Self.builtInCG, Self.externalCG(modes: modes)], fbs: [DisplayFixtures.builtInXDR, DisplayFixtures.external4K30], links: [hdmi], edids: [edid])
        let d = try XCTUnwrap(r.displays.first { !$0.builtIn })
        XCTAssertEqual(d.name, "LG HDR 4K", "framebuffer product name when AppKit has no screen")
        XCTAssertEqual(d.transport, .hdmi)
        XCTAssertNotNil(d.edid)
        XCTAssertEqual(d.year, 2021)
        XCTAssertEqual(d.widthMM, 600, "EDID size when CoreGraphics reports none")
        let x = try XCTUnwrap(d.diagnoses.first)
        XCTAssertEqual(x.severity, .warning)
        XCTAssertTrue(x.title.contains("30 Hz"), x.title)
        XCTAssertTrue(x.detail.contains("HDMI 1.4"), x.detail)
        XCTAssertTrue(x.detail.contains("594 MHz"), x.detail)
        XCTAssertTrue(x.advice?.contains("DisplayPort") == true)
        XCTAssertEqual(r.displays.first?.builtIn, true, "main display first")
    }

    func testThirtyHzChosenInSettings() throws {
        let modes = [Self.mode(3840, 2160, 30, native: true, current: true), Self.mode(3840, 2160, 60, native: true)]
        let r = assemble([Self.externalCG(modes: modes)], fbs: [DisplayFixtures.external4K30], screens: [])
        let x = try XCTUnwrap(r.displays.first?.diagnoses.first { $0.id == "refresh" })
        XCTAssertEqual(x.severity, .caution)
        XCTAssertTrue(x.advice?.contains("60 Hz") == true)
    }

    func testTwoLaneHub() throws {
        var fb = DisplayFixtures.external4K30
        fb["DisplayAttributes"] = ["ProductAttributes": ["LegacyManufacturerID": 4268, "ProductID": 41234]]
        let modes = [Self.mode(3840, 2160, 30, native: true, current: true)]
        let r = assemble([Self.externalCG(modes: modes, vendor: 4268, model: 41234)], fbs: [fb], links: [DisplayFixtures.usbCTwoLanesHBR], screens: [])
        let d = try XCTUnwrap(r.displays.first)
        XCTAssertEqual(d.transport, .usbC)
        let x = try XCTUnwrap(d.diagnoses.first { $0.id == "refresh" })
        XCTAssertTrue(x.title.contains("DisplayPort link"), x.title)
        XCTAssertTrue(x.advice?.contains("2 of 4") == true, x.advice ?? "")
    }

    func testSubsampledChroma() throws {
        let modes = [Self.mode(3840, 2160, 60, native: true, current: true)]
        var link = DisplayFixtures.thunderboltHBR3
        link["LinkRate"] = 0x0A; link["LinkRateDescription"] = "HBR"   // 4 × HBR = 8.64 Gbit/s: not enough for RGB
        let r = assemble([Self.externalCG(modes: modes, vendor: 4268, model: 41234)], fbs: [DisplayFixtures.external422], links: [link], screens: [])
        let x = try XCTUnwrap(r.displays.first?.diagnoses.first { $0.id == "chroma" })
        XCTAssertEqual(x.title, "8-bit colour with YCbCr 4:2:2 chroma")
        XCTAssertTrue(x.detail.contains("link bandwidth limited"), x.detail)
        XCTAssertEqual(r.displays.first?.transport, .thunderbolt)
    }

    func testHiDPIScaledProMotionVirtual() throws {
        // A 1440p display at native 1×: no HiDPI at 2560 × 1440.
        let qhd = [Self.mode(2560, 1440, 60, native: true, current: true), Self.mode(1280, 720, px: 2560, pxh: 1440, 60)]
        let r = assemble([Self.externalCG(modes: qhd)], fbs: [DisplayFixtures.external4K30], screens: [])
        XCTAssertTrue(r.displays[0].diagnoses.contains { $0.id == "hidpi" })
        // Built-in at 60 Hz with ProMotion available; a CoreGraphics display with no framebuffer is virtual.
        var cg = Self.builtInCG
        cg.mode = Self.mode(1728, 1117, px: 3456, pxh: 2234, 60, native: true, current: true)
        let virt = CGDisplayData(id: 9, builtIn: false, main: false, vendor: 1552, model: 1, widthMM: 0, heightMM: 0,
                                 mode: Self.mode(1366, 1024, px: 2732, pxh: 2048, 60, current: true), modes: [])
        let r2 = assemble([cg, virt], fbs: [DisplayFixtures.builtInXDR])
        XCTAssertTrue(r2.displays[0].diagnoses.contains { $0.id == "promotion" })
        XCTAssertEqual(r2.displays[1].transport, .virtual)
        XCTAssertTrue(r2.displays[1].diagnoses.contains { $0.id == "virtual" })
        // Scaled: rendering pixels differ from the panel's.
        var scaled = Self.builtInCG
        scaled.mode = Self.mode(1496, 967, px: 2992, pxh: 1934, 120, current: true)
        XCTAssertTrue(assemble([scaled], fbs: [DisplayFixtures.builtInXDR]).displays[0].diagnoses.contains { $0.id == "scaled" })
    }

    func testSeveralLinksStayUnassigned() {
        let a = Self.externalCG(modes: [Self.mode(1920, 1080, 60, current: true)])
        var b = Self.externalCG(modes: [Self.mode(1920, 1080, 60, current: true)], vendor: 4268, model: 41234); b.id = 6
        let r = assemble([a, b], fbs: [DisplayFixtures.external4K30, DisplayFixtures.external422],
                         links: [DisplayFixtures.usbCTwoLanesHBR, DisplayFixtures.thunderboltHBR3], screens: [])
        XCTAssertEqual(r.unassignedLinks.count, 2)
        XCTAssertTrue(r.displays.allSatisfy { $0.link == nil && $0.framebuffer != nil })
    }

    func testHistoryEvents() {
        let t = Date()
        let s60 = DisplayHistory.State(name: "LG", mode: "3840 × 2160 at 60 Hz", main: false)
        var s30 = s60; s30.mode = "3840 × 2160 at 30 Hz"
        XCTAssertTrue(DisplayHistory.events(flags: 1, display: 5, before: s60, after: s30, at: t).isEmpty, "begin-configuration ignored")
        XCTAssertEqual(DisplayHistory.events(flags: 16, display: 5, before: nil, after: s60, at: t).map(\.kind), [.connected])
        XCTAssertEqual(DisplayHistory.events(flags: 32, display: 5, before: s60, after: nil, at: t).map(\.kind), [.disconnected])
        let change = DisplayHistory.events(flags: 8, display: 5, before: s60, after: s30, at: t)
        XCTAssertEqual(change.map(\.kind), [.modeChanged])
        XCTAssertEqual(change.first?.detail, "3840 × 2160 at 60 Hz → 3840 × 2160 at 30 Hz")
        var main = s60; main.main = true
        XCTAssertEqual(DisplayHistory.events(flags: 4, display: 5, before: s60, after: main, at: t).map(\.kind), [.mainChanged])

        let h = DisplayHistory()
        h.baseline([5: s60], at: t)
        h.learnNames([5: "LG HDR 4K"])
        h.note(flags: 8, display: 5, after: s30, at: t)
        XCTAssertEqual(h.all.map(\.kind), [.baseline, .modeChanged])
        XCTAssertEqual(h.all.last?.name, "LG HDR 4K")
        for _ in 0..<300 { h.note(flags: 8, display: 5, after: s60, at: t); h.note(flags: 8, display: 5, after: s30, at: t) }
        XCTAssertEqual(h.all.count, DisplayHistory.limit)
    }

    func testMCPOutput() throws {
        let modes = [Self.mode(3840, 2160, 30, native: true, current: true)]
        let r = assemble([Self.builtInCG, Self.externalCG(modes: modes)], fbs: [DisplayFixtures.builtInXDR, DisplayFixtures.external4K30])
        let j = MCPTools.displaysJSON(r)
        XCTAssertTrue(j["summary"]?.string?.contains("2 displays; 1 problem") == true, j["summary"]?.string ?? "")
        XCTAssertEqual(j["displays"]?.array?.count, 2)
        XCTAssertEqual(j["displays"]?.array?.first?["brightness"]?.string, "50%")
        XCTAssertTrue(j["session_history"]?.string?.hasPrefix("unavailable") == true)
        XCTAssertFalse(j.text.contains("123456"), "serial numbers are never exported")
    }

    /// This Mac's displays, if any are online (skipped on headless CI runners without one).
    func testLiveSmoke() throws {
        guard !DisplayCollector.onlineIDs().isEmpty else { throw XCTSkip("no online display") }
        let r = DisplayCollector.collect(screens: [], history: [])
        XCTAssertFalse(r.displays.isEmpty)
        XCTAssertTrue(r.displays.allSatisfy { $0.mode != nil })
    }
}
