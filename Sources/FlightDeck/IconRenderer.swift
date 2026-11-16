import AppKit

/// `FlightDeck --render-iconset <dir>` writes the static app icon PNGs (used by scripts/bundle.sh).
/// `FlightDeck --render-dock-previews <dir>` writes one PNG per live Dock mode with demo data.
enum IconRenderer {
    static func handleCommandLine() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-iconset"), i + 1 < args.count {
            renderIconset(to: args[i + 1]); exit(0)
        }
        if let i = args.firstIndex(of: "--render-dock-previews"), i + 1 < args.count {
            renderPreviews(to: args[i + 1]); exit(0)
        }
    }

    static func png(_ view: DockTileView, px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        view.frame = NSRect(x: 0, y: 0, width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func renderIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let v = DockTileView(); v.mode = .appIcon
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? png(v, px: base * scale)?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }

    static func renderPreviews(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var d = DockData()
        var cpu: [Double?] = []
        for i in 0..<40 {
            if i == 22 || i == 23 { cpu.append(nil); continue }
            let wave: Double = 20 * sin(Double(i) / 4)
            let jitter: Double = Double(i % 7) * 3
            cpu.append(25 + wave + jitter)
        }
        d.cpu = cpu
        d.sys = d.cpu.map { $0.map { $0 * 0.3 } }
        d.cores = [(88, .efficiency), (74, .efficiency)] + [62, 45, 30, 22, 15, 9, 5, 2].map { ($0, .performance) }
        d.mem = 0.7; d.temp = 58; d.recording = true
        for theme in ThemeID.allCases {
            for mode in DockMode.allCases {
                let v = DockTileView(); v.mode = mode; v.data = d; v.palette = Palette.of(theme)
                try? png(v, px: 256)?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(theme.rawValue)-\(mode.rawValue.replacingOccurrences(of: " ", with: "")).png"))
            }
        }
    }
}
