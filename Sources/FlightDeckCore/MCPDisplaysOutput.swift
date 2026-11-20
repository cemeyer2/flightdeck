import Foundation
// Output of the read-only `displays` MCP tool: the same facts and diagnoses as the Displays page. NSScreen is read
// on the main thread (serviced by both the app and `--mcp`); the rest off it. Serial numbers are never included.
// Connect/mode-change history exists only inside the app (it comes from a callback registered at launch).

extension MCPTools {
    func displays() async throws -> JSON {
        let screens = await MainActor.run { DisplayScreens.read() }
        let history = DisplayHistory.shared.all
        let r = await Task.detached(priority: .utility) { DisplayCollector.collect(screens: screens, history: history) }.value
        return Self.displaysJSON(r)
    }

    static func displaysJSON(_ r: DisplaysReport) -> JSON {
        let issues = r.displays.flatMap(\.diagnoses).filter { $0.severity != .info }
        let summary = "\(r.displays.count) display\(r.displays.count == 1 ? "" : "s")"
            + (issues.isEmpty ? "; no problems found." : "; \(issues.count) problem\(issues.count == 1 ? "" : "s"): " + issues.map(\.title).joined(separator: "; ") + ".")
        return .object(dropping: [
            ("summary", .str(summary)),
            ("displays", .array(r.displays.map(displayJSON))),
            ("unassigned_links", r.unassignedLinks.isEmpty ? nil : .array(r.unassignedLinks.map(linkJSON))),
            ("session_history", r.history.isEmpty ? .str("unavailable (recorded only while the FlightDeck app runs)")
                : .array(r.history.suffix(30).map { e in .object([("time", F.time(e.time)), ("display", .str(e.name)), ("event", .str(e.title)), ("detail", .str(e.detail))]) })),
            ("limits", .strings(r.limits)),
        ])
    }

    static func displayJSON(_ d: DisplayFacts) -> JSON {
        let made: JSON? = d.year.map { y in .str(d.week.map { "week \($0) of \(y)" } ?? "\(y)") }
        let mode: JSON = d.mode.map { .str($0.summary) } ?? F.unavailable("CoreGraphics reported no mode")
        let link: JSON? = d.link.map(linkJSON) ?? (d.builtIn ? nil : F.unavailable("no DisplayPort transport tied to this display"))
        var brightness: JSON?
        if d.builtIn {
            if let b = d.brightness { brightness = .str("\(Int((b * 100).rounded()))%") } else { brightness = F.unavailable(d.brightnessNote ?? "not reported") }
        }
        let hidpi: [String] = Array(Set(d.modes.filter(\.hiDPI).map { "\($0.width)x\($0.height)" })).sorted()
        let diagnoses: [JSON] = d.diagnoses.map(diagnosisJSON)
        let identity: [(String, JSON?)] = [
            ("name", .str(d.name)), ("built_in", .bool(d.builtIn)), ("main", .bool(d.main)),
            ("connection", .str(d.transport.rawValue)), ("gpu", d.gpu.map(JSON.str)),
            ("size_inches", d.diagonalInches.map(F.r1)), ("manufactured", made), ("panel", d.panelHint.map(JSON.str)),
        ]
        let rest: [(String, JSON?)] = [
            ("mode", mode), ("refresh", refreshJSON(d)), ("signal", signalJSON(d)), ("link", link), ("hdr", hdrJSON(d)),
            ("brightness", brightness), ("color_profile", d.colorProfile.map(JSON.str)), ("modes_offered", .int(d.modes.count)),
            ("hidpi_sizes", .strings(Array(hidpi.prefix(12)))), ("diagnoses", .array(diagnoses)),
        ]
        return .object(dropping: identity + rest)
    }

    static func diagnosisJSON(_ x: DisplayDiagnosis) -> JSON {
        .object(dropping: [("severity", .str(x.severity.rawValue)), ("title", .str(x.title)), ("detail", .str(x.detail)), ("advice", x.advice.map(JSON.str))])
    }

    static func refreshJSON(_ d: DisplayFacts) -> JSON? {
        guard let s = d.screen else { return nil }
        return .object(dropping: [
            ("max_fps", .int(s.maximumFPS)),
            ("variable", s.variableRange.map { .str("\(DisplayFormat.hz($0.lowerBound))–\(DisplayFormat.hz($0.upperBound))") } ?? .str("fixed")),
        ])
    }

    static func signalJSON(_ d: DisplayFacts) -> JSON? {
        guard let f = d.framebuffer else { return nil }
        let t = f.currentTiming
        return .object(dropping: [
            ("timing", t.map { .str("\($0.width)x\($0.height) at \(DisplayFormat.hz($0.refreshHz)), pixel clock \(DisplayFormat.mhz($0.pixelClockHz))") }),
            ("color", f.activeColor.map { .str($0.summary) }),
            ("dsc", t.flatMap { tt in f.activeColor.map { .bool(tt.dscRequired.contains($0.id)) } }),
            ("timings_offered", .int(f.timings.count)),
        ])
    }

    static func linkJSON(_ l: DisplayLink) -> JSON {
        .object(dropping: [
            ("port", l.port.map(JSON.str)), ("transport", .str(l.transport.rawValue)), ("summary", .str(l.summary)),
            ("lanes", l.lanes.map(JSON.int)), ("max_lanes", l.maxLanes.map(JSON.int)),
            ("lane_rate_gbps", l.laneGbps.map(F.r2)), ("capacity_gbps", l.capacityGbps.map(F.r1)),
        ])
    }

    static func hdrJSON(_ d: DisplayFacts) -> JSON {
        guard let s = d.screen else { return F.unavailable("screen not reported by AppKit") }
        return .object(dropping: [
            ("state", .str(d.hdrState)), ("edr_headroom_now", F.r1(s.edrNow)), ("edr_headroom_potential", F.r1(s.edrPotential)),
            ("reference_headroom", s.edrReference > 0 ? F.r1(s.edrReference) : nil),
        ])
    }
}
