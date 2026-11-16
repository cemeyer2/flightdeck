// Colour themes. Every view reads the active Palette from the environment (`\.palette`), set at each scene root in
// FlightDeckApp from the "theme" user default. Fonts for VFD-style readouts are defined at the bottom.
import SwiftUI

/// User-selectable theme; the raw value is what's stored in the "theme" user default.
enum ThemeID: String, CaseIterable, Identifiable {
    case light, dark, green, amber, blue, mono
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// All colours a view needs. The four phosphor themes (green, amber, blue, mono) are single-hue CRT/VFD looks:
/// every role is a shade of one colour, and warning/critical don't change hue (see `level`).
struct Palette {
    var id: ThemeID
    var background: Color
    var panel: Color
    var panelBorder: Color
    var text: Color
    var dim: Color
    var accent: Color          // primary trace / lit segment
    var accent2: Color         // secondary trace (write/out/system)
    var meterOff: Color        // unlit VFD segment
    var grid: Color
    var pCore: Color
    var eCore: Color
    var warn: Color
    var crit: Color
    var glow: Double           // phosphor bloom radius
    var scheme: ColorScheme
    /// Single-hue themes: hue carries no meaning there (warn and crit equal the accent colour).
    var mono: Bool { id == .green || id == .amber || id == .blue || id == .mono }

    /// Builds the palette for a theme. Pure, cheap, and called freely from view bodies.
    static func of(_ id: ThemeID) -> Palette {
        // Shared recipe for phosphor themes: near-black background, everything else derived from one colour `c`
        // (plus `c2` for secondary traces and E-cores).
        func phosphor(_ c: Color, _ c2: Color) -> Palette {
            Palette(id: id, background: Color(white: 0.03), panel: Color(white: 0.06), panelBorder: c.opacity(0.25),
                    text: c, dim: c.opacity(0.55), accent: c, accent2: c2, meterOff: c.opacity(0.10),
                    grid: c.opacity(0.12), pCore: c, eCore: c2, warn: c, crit: c, glow: 3, scheme: .dark)
        }
        switch id {
        case .light:
            return Palette(id: id, background: Color(red: 0.95, green: 0.95, blue: 0.96), panel: .white,
                           panelBorder: Color.black.opacity(0.08), text: Color(white: 0.1), dim: Color(white: 0.45),
                           accent: Color(red: 0.0, green: 0.48, blue: 0.85), accent2: Color(red: 0.85, green: 0.35, blue: 0.1),
                           meterOff: Color.black.opacity(0.07), grid: Color.black.opacity(0.06),
                           pCore: Color(red: 0.0, green: 0.48, blue: 0.85), eCore: Color(red: 0.15, green: 0.65, blue: 0.35),
                           warn: .orange, crit: .red, glow: 0, scheme: .light)
        case .dark:
            return Palette(id: id, background: Color(red: 0.07, green: 0.08, blue: 0.09), panel: Color(red: 0.11, green: 0.12, blue: 0.13),
                           panelBorder: Color.white.opacity(0.07), text: Color(white: 0.92), dim: Color(white: 0.55),
                           accent: Color(red: 0.25, green: 0.78, blue: 1.0), accent2: Color(red: 1.0, green: 0.55, blue: 0.25),
                           meterOff: Color.white.opacity(0.06), grid: Color.white.opacity(0.06),
                           pCore: Color(red: 0.25, green: 0.78, blue: 1.0), eCore: Color(red: 0.4, green: 0.9, blue: 0.5),
                           warn: .orange, crit: Color(red: 1, green: 0.3, blue: 0.3), glow: 1.5, scheme: .dark)
        case .green: return phosphor(Color(red: 0.25, green: 1.0, blue: 0.45), Color(red: 0.6, green: 1.0, blue: 0.3))
        case .amber: return phosphor(Color(red: 1.0, green: 0.72, blue: 0.1), Color(red: 1.0, green: 0.5, blue: 0.05))
        case .blue:  return phosphor(Color(red: 0.35, green: 0.75, blue: 1.0), Color(red: 0.6, green: 0.9, blue: 1.0))
        case .mono:  return phosphor(Color(white: 0.9), Color(white: 0.6))
        }
    }

    /// Value-to-color for meters (mono themes stay single-hue): above 75% uses `warn`, above 90% `crit`.
    func level(_ fraction: Double) -> Color {
        if mono { return accent }
        if fraction > 0.9 { return crit }
        if fraction > 0.75 { return warn }
        return accent
    }
}

// The environment default (dark) is only seen by views rendered without a palette set, e.g. in previews.
private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.of(.dark) }
extension EnvironmentValues {
    var palette: Palette { get { self[PaletteKey.self] } set { self[PaletteKey.self] = newValue } }
}

extension Font {
    static let meterDigits = Font.system(size: 22, weight: .medium, design: .monospaced)
    static let meterLabel = Font.system(size: 10, weight: .semibold, design: .monospaced)
}
