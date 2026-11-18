// Shared instrument-style building blocks used throughout the views: segmented bar meters, numeric readouts and the
// titled Panel container, plus the off-screen rendering switch used by UIBench.
import SwiftUI
import FlightDeckCore

/// Segmented VFD-style bar meter. `fraction` is 0…1; values above 1 light every segment. A nil fraction leaves every
/// segment dark and overlays "UNAVAILABLE" (rather than showing an empty meter that would read as 0%).
/// Unless `color` is given, each lit segment takes its colour from its position (`Palette.level`), so a full meter
/// shades into warn/crit at the top end.
struct VFDMeter: View {
    @Environment(\.palette) var p
    var fraction: Double?          // nil = unavailable (all segments dark, "UNAVAILABLE" overlay)
    var segments = 24
    var color: Color? = nil
    var height: CGFloat = 10

    var body: some View {
        // One Canvas instead of a view (plus a shadow pass) per segment: meters appear dozens of times per screen.
        Canvas { ctx, size in
            let gap: CGFloat = 2
            let w = max((size.width - gap * CGFloat(segments - 1)) / CGFloat(segments), 1)
            // Off segments are drawn first, then the lit ones in a layer so a single shadow filter gives the glow.
            let lit = fraction == nil ? 0 : Int(((fraction ?? 0) * Double(segments)).rounded())
            func rect(_ i: Int) -> Path { Path(roundedRect: CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height), cornerRadius: 1.5) }
            for i in lit..<max(segments, lit) { ctx.fill(rect(i), with: .color(p.meterOff)) }
            guard lit > 0 else { return }
            ctx.drawLayer { layer in
                if p.glow > 0 { layer.addFilter(.shadow(color: (color ?? p.accent).opacity(0.8), radius: p.glow)) }
                for i in 0..<min(lit, segments) { layer.fill(rect(i), with: .color(color ?? p.level(Double(i + 1) / Double(segments)))) }
            }
        }
        .frame(height: height)
        .overlay {
            if fraction == nil {
                Text("UNAVAILABLE").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
            }
        }
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "unavailable")
    }
}

/// Glowing numeric readout. Shows "—" for unmeasured values; never a fake zero.
/// `value` is pre-formatted by the caller; `unit` is hidden when the value is missing.
struct Readout: View {
    @Environment(\.palette) var p
    var label: String
    var value: String?
    var unit: String = ""
    var color: Color? = nil
    var size: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.meterLabel).foregroundStyle(p.dim).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "—")
                    .font(.system(size: size, weight: .medium, design: .monospaced))
                    .foregroundStyle(value == nil ? p.dim : (color ?? p.text))
                    .shadow(color: (color ?? p.accent).opacity(p.glow > 0 && value != nil ? 0.6 : 0), radius: p.glow)
                    .contentTransition(.numericText())
                if value != nil && !unit.isEmpty {
                    Text(unit).font(.system(size: max(size * 0.45, 9), design: .monospaced)).foregroundStyle(p.dim)
                }
            }
        }
        .help(value == nil ? "Not measured on this system" : "")
    }
}

/// Rounded instrument panel with a title strip.
struct Panel<Content: View>: View {
    @Environment(\.palette) var p
    var title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim) }
            }
            content
        }
        .padding(12)
        .background(PanelSurface())
    }
}

/// The panel "glass": the panel colour with a faint top-lit sheen, a hairline highlight along the top edge, and a soft
/// drop shadow. Deliberately no live blur (`.material`/glass effects): dozens of panels redraw every sample, and a
/// blur behind each would cost GPU time for little visible gain over the app's solid backdrop. The shadow sits on this
/// background shape only, so it's rasterized once rather than re-rendered with the panel's changing content.
struct PanelSurface: View {
    @Environment(\.palette) var p
    var cornerRadius: CGFloat = 12
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = p.scheme == .dark
        shape.fill(p.panel)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.045 : 0.0), .clear], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.10 : 0.7), p.panelBorder],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(dark ? 0.35 : 0.07), radius: dark ? 10 : 6, y: dark ? 4 : 2)
    }
}

/// The window's backdrop: the theme background with a faint glow of the accent colour from the top, so pages have a
/// little depth instead of a flat fill. Static, drawn once per page.
struct Backdrop: View {
    @Environment(\.palette) var p
    var body: some View {
        ZStack {
            p.background
            RadialGradient(colors: [p.accent.opacity(p.scheme == .dark ? 0.07 : 0.05), .clear],
                           center: UnitPoint(x: 0.5, y: -0.15), startRadius: 0, endRadius: 900)
        }
        .ignoresSafeArea()
    }
}

private struct OffscreenKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while rendering off-screen (benchmarks, PNG review): ScrollViews would render empty there.
    var offscreen: Bool { get { self[OffscreenKey.self] } set { self[OffscreenKey.self] = newValue } }
}

/// A vertical ScrollView, except when rendering off-screen (ImageRenderer can't render scroll view contents).
struct MaybeScroll<Content: View>: View {
    @Environment(\.offscreen) private var offscreen
    @ViewBuilder var content: Content
    var body: some View {
        if offscreen { content } else { ScrollView { content } }
    }
}
