// Invented Displays data for demo mode and renders: a built-in 14" mini-LED XDR panel and a made-up "Northwind
// 27U4K" monitor stuck at 30 Hz on the HDMI port (its HDMI 1.4 input can't carry 4K at 60 Hz). Nothing here is read
// from this Mac; the report is put together by the real DisplayCollector.assemble, so the diagnoses are the app's own.
import Foundation
import FlightDeckCore

enum DemoDisplays {
    static func report(now: Date = Date()) -> DisplaysReport {
        DisplayCollector.assemble(cg: [builtIn, external], screens: screens, framebuffers: [builtInFB, externalFB], links: [link],
                                  edids: [edid], gpus: [1: "Apple M4 Pro", 2: "Apple M4 Pro"], brightness: (0.62, "DisplayServices (read-only)"),
                                  history: history(now: now), now: now)
    }

    /// HiDPI sizes at each refresh rate the panel offers.
    static func builtInModes() -> [DisplayModeInfo] {
        let sizes = [(1024, 665), (1147, 745), (1312, 852), (1512, 982), (1800, 1169)]
        return sizes.flatMap { s in
            [120.0, 60, 50, 48].map { hz in
                let native = s.0 == 1512
                return DisplayModeInfo(width: s.0, height: s.1, pixelWidth: s.0 * 2, pixelHeight: s.1 * 2, refreshHz: hz,
                                       native: native, current: native && hz == 120)
            }
        }
    }

    static func externalModes() -> [DisplayModeInfo] {
        var m: [DisplayModeInfo] = [
            .init(width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 30, native: true),
            .init(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 30, current: true),
            .init(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, refreshHz: 30),
            .init(width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshHz: 60),
        ]
        for hz in [60.0, 50] {
            m.append(.init(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshHz: hz))
            m.append(.init(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshHz: hz))
        }
        return m
    }

    static let builtIn: CGDisplayData = {
        let modes = builtInModes()
        return CGDisplayData(id: 1, builtIn: true, main: true, vendor: 0x0610, model: 0xA0C1, widthMM: 302, heightMM: 196,
                             mode: modes.first(where: \.current), modes: modes)
    }()

    static let external: CGDisplayData = {
        let modes = externalModes()
        return CGDisplayData(id: 2, builtIn: false, main: false, vendor: DemoDisplays.pnp, model: 0x27A4, widthMM: 597, heightMM: 336,
                             mode: modes.first(where: \.current), modes: modes)
    }()

    /// "NWD", the invented manufacturer's PNP code.
    static let pnp: UInt32 = (14 << 10) | (23 << 5) | 4

    static let screens = [
        DisplayScreenFacts(displayID: 1, name: "Built-in Liquid Retina XDR Display", maximumFPS: 120, minimumRefreshInterval: 1.0 / 120,
                           maximumRefreshInterval: 1.0 / 24, updateGranularity: 0, edrNow: 2.4, edrPotential: 16, edrReference: 0,
                           colorSpace: "Color LCD", backingScale: 2),
        DisplayScreenFacts(displayID: 2, name: "Northwind 27U4K", maximumFPS: 30, minimumRefreshInterval: 1.0 / 30,
                           maximumRefreshInterval: 1.0 / 30, updateGranularity: 0, edrNow: 1, edrPotential: 1, edrReference: 0,
                           colorSpace: "Northwind 27U4K", backingScale: 2),
    ]

    static let builtInFB: FramebufferFacts = {
        var f = FramebufferFacts(external: false, timings: [
            DisplayTiming(id: 2, width: 3024, height: 1964, hTotal: 3104, vTotal: 2172, refreshHz: 120, preferred: true,
                          colorModes: [DisplayColorMode(id: 1, depth: 10, chroma: .rgb, eotf: 0)]),
            DisplayTiming(id: 3, width: 3024, height: 1964, hTotal: 3104, vTotal: 2172, refreshHz: 60,
                          colorModes: [DisplayColorMode(id: 1, depth: 10, chroma: .rgb, eotf: 0)]),
        ])
        f.currentTimingID = 2
        f.activeColor = DisplayColorMode(id: 1, depth: 10, chroma: .rgb, eotf: 0)
        f.nativeWidth = 3024; f.nativeHeight = 1964
        f.minRefreshInterval = 1.0 / 120; f.maxRefreshInterval = 1.0 / 24
        f.brightnessNits = 260; f.peakNits = 1600
        return f
    }()

    static let externalFB: FramebufferFacts = {
        let rgb8 = DisplayColorMode(id: 1, depth: 8, chroma: .rgb, eotf: 0)
        var f = FramebufferFacts(external: true, timings: [
            DisplayTiming(id: 10, width: 3840, height: 2160, hTotal: 4400, vTotal: 2250, refreshHz: 30, preferred: true, colorModes: [rgb8]),
            DisplayTiming(id: 11, width: 2560, height: 1440, hTotal: 2720, vTotal: 1481, refreshHz: 60, colorModes: [rgb8]),
            DisplayTiming(id: 12, width: 1920, height: 1080, hTotal: 2200, vTotal: 1125, refreshHz: 60, colorModes: [rgb8]),
        ])
        f.vendorID = Int(DemoDisplays.pnp); f.productID = 0x27A4
        f.productName = "Northwind 27U4K"; f.manufacturerID = "NWD"
        f.year = 2021; f.week = 14
        f.imageWidthCm = 60; f.imageHeightCm = 34
        f.nativeWidth = 3840; f.nativeHeight = 2160
        f.currentTimingID = 10
        f.activeColor = rgb8
        return f
    }()

    static let link = DisplayLink(port: "Port-HDMI@1", portType: "HDMI", active: true, lanes: 4, maxLanes: 4, laneGbps: 5.4, rateName: "HBR2")

    static let edid = EDIDInfo(manufacturer: "NWD", productCode: 0x27A4, week: 14, year: 2021, widthCm: 60, heightCm: 34, name: "NW 27U4K",
                               hasSerial: true, inputBitDepth: 8, inputInterface: "HDMI", hdmiSink: true, maxTMDSHz: 300e6, maxFRLGbps: nil, hdr: false)

    static func history(now: Date) -> [DisplayEvent] {
        let ext = "1920 × 1080 (3840 × 2160 px, HiDPI)"
        return [
            DisplayEvent(time: now.addingTimeInterval(-3 * 3600), display: 1, name: "Built-in Liquid Retina XDR Display", kind: .baseline, detail: "1512 × 982 (3024 × 1964 px, HiDPI) at 120 Hz"),
            DisplayEvent(time: now.addingTimeInterval(-3 * 3600), display: 2, name: "Northwind 27U4K", kind: .baseline, detail: "\(ext) at 60 Hz"),
            DisplayEvent(time: now.addingTimeInterval(-74 * 60), display: 2, name: "Northwind 27U4K", kind: .disconnected, detail: "\(ext) at 60 Hz"),
            DisplayEvent(time: now.addingTimeInterval(-71 * 60), display: 2, name: "Northwind 27U4K", kind: .connected, detail: "\(ext) at 30 Hz"),
            DisplayEvent(time: now.addingTimeInterval(-70 * 60), display: 2, name: "Northwind 27U4K", kind: .modeChanged, detail: "3840 × 2160 at 30 Hz → \(ext) at 30 Hz"),
            DisplayEvent(time: now.addingTimeInterval(-25 * 60), display: 1, name: "Built-in Liquid Retina XDR Display", kind: .modeChanged, detail: "1512 × 982 (3024 × 1964 px, HiDPI) at 60 Hz → 1512 × 982 (3024 × 1964 px, HiDPI) at 120 Hz"),
        ]
    }
}
