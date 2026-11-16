import AppKit
import SwiftUI
import FlightdeckCore

/// Draws the Dock tile / app icon in the VFD instrument style. Resolution-independent (unit = width/128).
final class DockTileView: NSView {
    var mode: DockMode = .cpuHistory
    var palette = Palette.of(.dark)
    var data = DockData()

    private func c(_ color: Color) -> NSColor { NSColor(color) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let u = bounds.width / 128
        // macOS icon grid: ~100/128 body with soft shadow
        let tile = bounds.insetBy(dx: 12 * u, dy: 12 * u).offsetBy(dx: 0, dy: 1.5 * u)
        let radius = tile.width * 0.225
        let bodyPath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * u), blur: 5 * u, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        NSColor(white: 0.10, alpha: 1).setFill(); bodyPath.fill()
        ctx.restoreGState()

        // bezel gradient
        let bezel = NSGradient(starting: NSColor(white: 0.24, alpha: 1), ending: NSColor(white: 0.07, alpha: 1))
        bezel?.draw(in: bodyPath, angle: -90)

        // screen
        let screen = tile.insetBy(dx: 9 * u, dy: 9 * u)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: radius * 0.5, yRadius: radius * 0.5)
        (palette.scheme == .light ? NSColor(white: 0.04, alpha: 1) : c(palette.background).blended(withFraction: 0.5, of: .black) ?? .black).setFill()
        screenPath.fill()
        NSColor.white.withAlphaComponent(0.06).setStroke(); screenPath.lineWidth = 1 * u; screenPath.stroke()

        ctx.saveGState()
        screenPath.addClip()
        let content = screen.insetBy(dx: 5 * u, dy: 5 * u)
        switch mode {
        case .cpuHistory: drawHistory(content, u)
        case .cores: drawCores(content, u)
        case .gauges: drawGauges(content, u)
        case .appIcon: drawLogo(content, u)
        }
        // glass highlight
        let gloss = NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: NSColor.white.withAlphaComponent(0))
        gloss?.draw(in: NSRect(x: screen.minX, y: screen.midY, width: screen.width, height: screen.height / 2), angle: -90)
        ctx.restoreGState()

        if data.caution >= 2 && mode != .appIcon {
            // master caution: amber (caution) or red (warning) light in the top bezel, right of centre
            let col = data.caution >= 3 ? NSColor(red: 1, green: 0.25, blue: 0.2, alpha: 1) : NSColor(red: 1, green: 0.72, blue: 0.1, alpha: 1)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 5 * u, color: col.cgColor)
            let light = NSRect(x: tile.maxX - 24 * u, y: tile.maxY - 7 * u, width: 12 * u, height: 4.5 * u)
            col.setFill(); NSBezierPath(roundedRect: light, xRadius: 1.5 * u, yRadius: 1.5 * u).fill()
            ctx.restoreGState()
        }
        if data.recording && mode != .appIcon {
            // recording: glowing red screen border + small tally light in the top bezel
            let red = NSColor(red: 1, green: 0.23, blue: 0.2, alpha: 1)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 4 * u, color: red.cgColor)
            red.setStroke(); screenPath.lineWidth = 1.8 * u; screenPath.stroke()
            let dot = NSRect(x: tile.midX - 3 * u, y: tile.maxY - 6.5 * u, width: 6 * u, height: 6 * u)
            red.setFill(); NSBezierPath(ovalIn: dot).fill()
            ctx.restoreGState()
        }
    }

    // MARK: helpers
    private var lit: NSColor { palette.scheme == .light ? NSColor(red: 0.25, green: 0.78, blue: 1, alpha: 1) : c(palette.accent) }
    private var lit2: NSColor { palette.scheme == .light ? NSColor(red: 1, green: 0.55, blue: 0.25, alpha: 1) : c(palette.accent2) }
    private func pColor() -> NSColor { palette.scheme == .light ? lit : c(palette.pCore) }
    private func eColor() -> NSColor { palette.scheme == .light ? NSColor(red: 0.4, green: 0.9, blue: 0.5, alpha: 1) : c(palette.eCore) }
    private func level(_ f: Double) -> NSColor {
        if palette.mono { return lit }
        return f > 0.9 ? NSColor(red: 1, green: 0.3, blue: 0.3, alpha: 1) : f > 0.75 ? .orange : lit
    }

    private func glowStroke(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat, _ u: CGFloat) {
        color.withAlphaComponent(0.30).setStroke(); path.lineWidth = width + 3.5 * u; path.stroke()
        color.setStroke(); path.lineWidth = width; path.stroke()
    }

    private func grid(_ r: NSRect, _ u: CGFloat) {
        let g = NSBezierPath()
        for i in 1..<4 { let y = r.minY + r.height * CGFloat(i) / 4; g.move(to: .init(x: r.minX, y: y)); g.line(to: .init(x: r.maxX, y: y)) }
        for i in 1..<6 { let x = r.minX + r.width * CGFloat(i) / 6; g.move(to: .init(x: x, y: r.minY)); g.line(to: .init(x: x, y: r.maxY)) }
        lit.withAlphaComponent(0.10).setStroke(); g.lineWidth = 0.6 * u; g.stroke()
    }

    /// Segmented VFD bar; vertical or horizontal.
    private func segBar(_ r: NSRect, _ fraction: Double?, segments: Int, vertical: Bool, color: NSColor?, _ u: CGFloat) {
        let gap = 1.2 * u
        let len = ((vertical ? r.height : r.width) - gap * CGFloat(segments - 1)) / CGFloat(segments)
        let litCount = Int(((fraction ?? 0) * Double(segments)).rounded())
        for i in 0..<segments {
            let seg = vertical ? NSRect(x: r.minX, y: r.minY + CGFloat(i) * (len + gap), width: r.width, height: len)
                               : NSRect(x: r.minX + CGFloat(i) * (len + gap), y: r.minY, width: len, height: r.height)
            let on = fraction != nil && i < litCount
            let col = color ?? level(Double(i + 1) / Double(segments))
            (on ? col : lit.withAlphaComponent(0.09)).setFill()
            NSBezierPath(roundedRect: seg, xRadius: 0.8 * u, yRadius: 0.8 * u).fill()
        }
    }

    private func text(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold, align: NSTextAlignment = .left) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: attrs)
        let x = align == .right ? p.x - sz.width : (align == .center ? p.x - sz.width / 2 : p.x)
        (s as NSString).draw(at: NSPoint(x: x, y: p.y), withAttributes: attrs)
    }

    // MARK: modes
    private func path(_ values: [Double?], in r: NSRect) -> [[NSPoint]] {
        guard values.count > 1 else { return [] }
        let dx = r.width / CGFloat(values.count - 1)
        var runs: [[NSPoint]] = []; var cur: [NSPoint] = []
        for (i, v) in values.enumerated() {
            if let v { cur.append(NSPoint(x: r.minX + CGFloat(i) * dx, y: r.minY + r.height * CGFloat(min(max(v / 100, 0), 1)))) }
            else if !cur.isEmpty { runs.append(cur); cur = [] }
        }
        if !cur.isEmpty { runs.append(cur) }
        return runs
    }

    private func drawHistory(_ r: NSRect, _ u: CGFloat) {
        let graph = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 15 * u)
        grid(graph, u)
        for run in path(data.cpu, in: graph) where run.count > 1 {
            let area = NSBezierPath(); area.move(to: NSPoint(x: run[0].x, y: graph.minY))
            run.forEach { area.line(to: $0) }; area.line(to: NSPoint(x: run.last!.x, y: graph.minY)); area.close()
            NSGradient(starting: lit.withAlphaComponent(0.45), ending: lit.withAlphaComponent(0.04))?.draw(in: area, angle: -90)
            let line = NSBezierPath(); line.move(to: run[0]); run.dropFirst().forEach { line.line(to: $0) }
            line.lineJoinStyle = .round
            glowStroke(line, lit, 1.6 * u, u)
        }
        for run in path(data.sys, in: graph) where run.count > 1 {
            let line = NSBezierPath(); line.move(to: run[0]); run.dropFirst().forEach { line.line(to: $0) }
            lit2.setStroke(); line.lineWidth = 1.1 * u; line.stroke()
        }
        let now = data.cpu.last ?? nil
        text("CPU", at: NSPoint(x: r.minX, y: r.maxY - 11 * u), size: 9 * u, color: lit.withAlphaComponent(0.7))
        text(now.map { String(format: "%.0f%%", $0) } ?? "—", at: NSPoint(x: r.maxX, y: r.maxY - 13 * u), size: 13 * u, color: now == nil ? lit.withAlphaComponent(0.5) : lit, weight: .bold, align: .right)
    }

    private func drawCores(_ r: NSRect, _ u: CGFloat) {
        let cores = data.cores
        guard !cores.isEmpty else { text("—", at: NSPoint(x: r.midX, y: r.midY - 8 * u), size: 16 * u, color: lit, align: .center); return }
        let n = CGFloat(cores.count)
        let gap = max(1.5 * u, r.width * 0.12 / n)
        let w = (r.width - gap * (n - 1)) / n
        let segs = 14
        for (i, core) in cores.enumerated() {
            let col = core.1 == .efficiency ? eColor() : pColor()
            let bar = NSRect(x: r.minX + CGFloat(i) * (w + gap), y: r.minY, width: w, height: r.height)
            segBar(bar, core.0 / 100, segments: segs, vertical: true, color: col, u)
        }
    }

    private func drawGauges(_ r: NSRect, _ u: CGFloat) {
        let rows: [(String, Double?)] = [("CPU", (data.cpu.last ?? nil).map { $0 / 100 }),
                                         ("MEM", data.mem),
                                         ("TMP", data.temp.map { $0 / 110 })]
        let rowH = r.height / CGFloat(rows.count)
        for (i, row) in rows.enumerated() {
            let y = r.maxY - CGFloat(i + 1) * rowH
            text(row.0, at: NSPoint(x: r.minX, y: y + rowH - 11 * u), size: 8.5 * u, color: lit.withAlphaComponent(0.75))
            let val = row.0 == "TMP" ? data.temp.map { String(format: "%.0f°", $0) } : row.1.map { String(format: "%.0f%%", $0 * 100) }
            text(val ?? "—", at: NSPoint(x: r.maxX, y: y + rowH - 11.5 * u), size: 9.5 * u, color: lit, weight: .bold, align: .right)
            segBar(NSRect(x: r.minX, y: y + 3 * u, width: r.width, height: 7 * u), row.1, segments: 12, vertical: false, color: nil, u)
        }
    }

    /// Static mark: three VFD columns and a glowing trace.
    func drawLogo(_ r: NSRect, _ u: CGFloat) {
        grid(r, u)
        let heights: [Double] = [0.45, 0.8, 0.6]
        let w = r.width * 0.18, gap = r.width * 0.09
        let x0 = r.minX + (r.width - (3 * w + 2 * gap)) / 2
        for (i, h) in heights.enumerated() {
            let col = i == 1 ? lit2 : lit
            segBar(NSRect(x: x0 + CGFloat(i) * (w + gap), y: r.minY + 4 * u, width: w, height: r.height * 0.62), h, segments: 8, vertical: true, color: col, u)
        }
        let pts: [Double] = [0.55, 0.62, 0.5, 0.7, 0.66, 0.9, 0.78, 0.84, 0.72]
        let line = NSBezierPath()
        for (i, v) in pts.enumerated() {
            let p = NSPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(pts.count - 1), y: r.minY + r.height * CGFloat(v))
            i == 0 ? line.move(to: p) : line.line(to: p)
        }
        line.lineJoinStyle = .round; line.lineCapStyle = .round
        glowStroke(line, lit, 2.2 * u, u)
    }
}
