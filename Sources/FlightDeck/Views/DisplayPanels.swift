import SwiftUI
import FlightDeckCore
// The fact columns of a display card (identity, mode and refresh, HDR and brightness, connection), the collapsible
// mode list and the panel for links that couldn't be tied to one display. A value no source gave is shown as
// "unavailable" with the reason, never as 0.

/// One labelled fact; a nil value shows as unavailable with `missing` as the reason.
struct DisplayFactRow: View {
    @Environment(\.palette) var p
    var label: String
    var value: String?
    var missing = "not reported"

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.meterLabel).foregroundStyle(p.dim)
            Text(value ?? "unavailable (\(missing))").font(.system(size: 12, design: .monospaced))
                .foregroundStyle(value == nil ? p.dim : p.text)
        }
    }
}

/// Column heading.
struct FactHeading: View {
    @Environment(\.palette) var p
    var text: String
    var body: some View { Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(p.accent) }
}

struct IdentityFacts: View {
    var display: DisplayFacts
    var body: some View {
        let d = display
        VStack(alignment: .leading, spacing: 6) {
            FactHeading(text: "Identity")
            DisplayFactRow(label: "Type", value: d.builtIn ? "Built-in" : "External")
            DisplayFactRow(label: "Vendor / model", value: vendorModel)
            DisplayFactRow(label: "Size", value: size, missing: "the display reports no physical size")
            DisplayFactRow(label: "Manufactured", value: d.year.map { y in d.week.map { "week \($0), \(y)" } ?? "\(y)" },
                           missing: d.builtIn ? "built-in panels don't report it" : "not in the EDID")
            DisplayFactRow(label: "Panel", value: d.panelHint, missing: "nothing reports the panel technology")
            DisplayFactRow(label: "GPU", value: d.gpu, missing: "Metal didn't name a device")
        }
    }

    var vendorModel: String? {
        let d = display
        let maker = d.edid?.manufacturer ?? d.framebuffer?.manufacturerID.flatMap { $0.count == 3 ? $0 : nil }
        guard let v = d.vendorID, v != 0 else { return maker }
        return (maker.map { "\($0) · " } ?? "") + String(format: "vendor 0x%04X, model 0x%04X", v, d.modelID ?? 0)
    }
    var size: String? {
        let d = display
        guard let inches = d.diagonalInches, let w = d.widthMM, let h = d.heightMM else { return nil }
        return String(format: "%.1f\" (%.0f × %.0f mm)", inches, w, h)
    }
}

struct ModeFacts: View {
    var display: DisplayFacts
    var body: some View {
        let d = display
        VStack(alignment: .leading, spacing: 6) {
            FactHeading(text: "Mode & refresh")
            DisplayFactRow(label: "Looks like", value: d.mode.map { "\($0.width) × \($0.height) points" })
            DisplayFactRow(label: "Pixels", value: d.mode.map { "\($0.pixelWidth) × \($0.pixelHeight)" + ($0.hiDPI ? String(format: " (HiDPI %.0f×)", $0.scale) : " (1×)") })
            DisplayFactRow(label: "Native", value: d.nativePixels.map { "\($0.width) × \($0.height)" })
            DisplayFactRow(label: "Refresh", value: refresh)
            DisplayFactRow(label: "Variable refresh", value: variable, missing: "AppKit didn't report the screen")
            DisplayFactRow(label: "Signal", value: d.framebuffer?.currentTiming.map { "\(DisplayFormat.hz($0.refreshHz)), pixel clock \(DisplayFormat.mhz($0.pixelClockHz))" },
                           missing: "no display-coprocessor timing (Intel Mac or virtual display)")
        }
    }

    var refresh: String? {
        let d = display
        if let hz = d.mode?.refreshHz, hz > 0 { return DisplayFormat.hz(hz) }
        return d.screen.map { "up to \($0.maximumFPS) Hz" }
    }
    var variable: String? {
        guard let s = display.screen else { return nil }
        guard let r = s.variableRange else { return "no (fixed rate)" }
        let label = display.builtIn ? "ProMotion" : "Adaptive-Sync"
        return "\(label) \(DisplayFormat.hz(r.lowerBound))–\(DisplayFormat.hz(r.upperBound))"
    }
}

struct HDRFacts: View {
    var display: DisplayFacts
    var body: some View {
        let d = display, s = d.screen
        VStack(alignment: .leading, spacing: 6) {
            FactHeading(text: "HDR & colour")
            DisplayFactRow(label: "HDR", value: s == nil ? nil : d.hdrState, missing: "AppKit didn't report the screen")
            DisplayFactRow(label: "EDR headroom now / max", value: s.map { "\(DisplayFormat.headroom($0.edrNow)) / \(DisplayFormat.headroom($0.edrPotential))" })
            DisplayFactRow(label: "Reference preset", value: s.flatMap { $0.edrReference > 0 ? "headroom \(DisplayFormat.headroom($0.edrReference))" : nil },
                           missing: "presets are only readable through private APIs")
            DisplayFactRow(label: "Colour on the wire", value: d.framebuffer?.activeColor?.summary, missing: "not reported for this display")
            DisplayFactRow(label: "ColorSync profile", value: d.colorProfile)
            if d.builtIn {
                DisplayFactRow(label: "Brightness", value: brightness, missing: d.brightnessNote ?? "not reported")
            }
        }
    }

    var brightness: String? {
        let d = display
        guard let b = d.brightness else { return nil }
        let nits = d.framebuffer?.brightnessNits.map { String(format: ", backlight ≈ %.0f nits", $0) } ?? ""
        let peak = d.framebuffer?.peakNits.map { String(format: " (peak %.0f)", $0) } ?? ""
        return "\(Int((b * 100).rounded()))%" + nits + peak
    }
}

struct ConnectionFacts: View {
    var display: DisplayFacts
    var body: some View {
        let d = display, l = d.link
        VStack(alignment: .leading, spacing: 6) {
            FactHeading(text: "Connection")
            DisplayFactRow(label: "Transport", value: d.transport == .unknown ? nil : d.transport.rawValue,
                           missing: d.builtIn ? "" : "no DisplayPort transport is tied to this display")
            if !d.builtIn {
                DisplayFactRow(label: "Port", value: l?.port.map(Self.portName))
                DisplayFactRow(label: "Link", value: l?.summary, missing: "the IORegistry reports no link rate here")
                DisplayFactRow(label: "Lanes", value: l?.lanes.map { "\($0) of \(l?.maxLanes ?? 4)" })
                DisplayFactRow(label: "DSC", value: dsc, missing: "not reported")
                DisplayFactRow(label: "HDMI input (EDID)", value: hdmi, missing: d.edid == nil ? "EDID not available" : "not an HDMI input")
            }
            DisplayFactRow(label: "Mirroring", value: d.mirrorOf.map { "mirrors display \($0)" } ?? "no")
        }
    }

    /// "Port-USB-C@2" → "USB-C port 2".
    static func portName(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "Port-", with: "")
        let parts = t.split(separator: "@")
        return parts.count == 2 ? "\(parts[0]) port \(parts[1])" : t
    }
    var dsc: String? {
        guard let f = display.framebuffer, let c = f.activeColor, let t = f.currentTiming else { return nil }
        return t.dscRequired.contains(c.id) ? "on" : "off"
    }
    var hdmi: String? {
        guard let e = display.edid, e.hdmiSink, let v = e.hdmiVersion else { return nil }
        return v.rawValue + (e.maxTMDSHz.map { ", max TMDS \(DisplayFormat.mhz($0))" } ?? "")
    }
}

/// Every mode CoreGraphics offers, grouped by size, with the native and current ones highlighted. Collapsed by default.
struct ModeList: View {
    @Environment(\.palette) var p
    var display: DisplayFacts
    @Environment(\.offscreen) private var offscreen
    @State private var open: Bool

    init(display: DisplayFacts, expanded: Bool = false) { self.display = display; _open = State(initialValue: expanded) }

    var body: some View {
        let groups = Dictionary(grouping: display.modes) { "\($0.width)x\($0.height)x\($0.pixelWidth)" }
        let keys = groups.keys.sorted { (groups[$0]![0].width, groups[$0]![0].pixelWidth) > (groups[$1]![0].width, groups[$1]![0].pixelWidth) }
        VStack(alignment: .leading, spacing: 4) {
            let title = Label("\(display.modes.count) modes in \(keys.count) sizes", systemImage: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, design: .monospaced))
            // ImageRenderer draws buttons as placeholders, so renders show the label alone.
            if offscreen { title.foregroundStyle(p.accent) } else { Button { open.toggle() } label: { title }.buttonStyle(.borderless) }
            if open {
                ForEach(keys, id: \.self) { k in row(groups[k]!) }
            }
        }
    }

    func row(_ modes: [DisplayModeInfo]) -> some View {
        let m = modes[0]
        let native = modes.contains(where: \.native), current = modes.contains(where: \.current)
        let rates = Set(modes.map(\.refreshHz)).sorted(by: >).map { $0 > 0 ? DisplayFormat.hz($0) : "—" }.joined(separator: ", ")
        return HStack(spacing: 8) {
            Text(verbatim: "\(m.width) × \(m.height)").frame(width: 120, alignment: .leading)
            Text(verbatim: m.hiDPI ? "HiDPI \(m.pixelWidth) × \(m.pixelHeight)" : "\(m.pixelWidth) × \(m.pixelHeight)").frame(width: 170, alignment: .leading).foregroundStyle(p.dim)
            Text(rates).foregroundStyle(p.dim)
            Spacer()
            if native { DisplayBadge(text: "NATIVE", color: p.accent) }
            if current { DisplayBadge(text: "CURRENT", color: p.warn) }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(current ? p.text : p.text.opacity(0.85))
    }
}

/// Active links when FlightDeck can't tell which display each one drives.
struct UnassignedLinksPanel: View {
    @Environment(\.palette) var p
    var links: [DisplayLink]
    var body: some View {
        Panel(title: "Video links", trailing: "not tied to a display") {
            ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                HStack {
                    Text(l.port.map(ConnectionFacts.portName) ?? "port not reported").frame(width: 160, alignment: .leading)
                    Text(l.transport.rawValue).frame(width: 300, alignment: .leading).foregroundStyle(p.dim)
                    Text(l.summary)
                    Spacer()
                }.font(.system(size: 11, design: .monospaced))
            }
        }
    }
}
