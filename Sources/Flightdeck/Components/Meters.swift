import SwiftUI
import FlightdeckCore

/// Segmented VFD-style bar meter.
struct VFDMeter: View {
    @Environment(\.palette) var p
    var fraction: Double?          // nil = unavailable (all segments dark, hatched)
    var segments = 24
    var color: Color? = nil
    var height: CGFloat = 10

    var body: some View {
        // One Canvas instead of a view (plus a shadow pass) per segment: meters appear dozens of times per screen.
        Canvas { ctx, size in
            let gap: CGFloat = 2
            let w = max((size.width - gap * CGFloat(segments - 1)) / CGFloat(segments), 1)
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
        .background(RoundedRectangle(cornerRadius: 10).fill(p.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.panelBorder))
    }
}
