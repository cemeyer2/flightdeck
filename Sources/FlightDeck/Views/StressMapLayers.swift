import SwiftUI
import AppKit
import FlightDeckCore

// The Stress Map's moving parts, drawn with Core Animation.
//
// Why not SwiftUI: animating the map in SwiftUI meant re-evaluating and re-rendering the view every frame, about 12 ms
// of CPU per frame, which took the page from ~5% to ~21% CPU. Core Animation layers are handed their new values once
// per sample and the system's render server (not FlightDeck) interpolates them on screen, so transitions are smooth
// at close to the static cost. The ambient motion (traffic dashes, breathing hubs) is likewise a repeating
// render-server animation.
//
// The SwiftUI side (StressMap) still computes the layout, draws the static parts and handles hover/click; this view
// only draws, and passes every mouse event through.

/// Bridges the map's state into `MapLayerView`.
struct StressMapLayers: NSViewRepresentable {
    var report: StressReport
    var bubbles: [PlacedBubble]
    var geometry: MapGeometry
    var palette: Palette
    var hovered: String?
    /// Off (setting, or Reduce Motion): every change applies instantly and there is no ambient motion.
    var animate: Bool
    var labelled: Int

    func makeNSView(context: Context) -> MapLayerView { MapLayerView() }
    func updateNSView(_ v: MapLayerView, context: Context) { v.update(self) }
}

/// A layer-hosting view (it owns its layer tree; AppKit doesn't manage the sublayers) with a top-left origin, matching
/// SwiftUI's coordinates, so `PlacedBubble` positions can be used as they are.
final class MapLayerView: NSView {
    /// How long a transition between samples takes; samples are 1 s or more apart.
    static let duration: CFTimeInterval = 0.9

    private let root = CALayer()
    private let routeLayer = CALayer(), hubLayer = CALayer(), bubbleLayer = CALayer()
    private var hubs: [Subsystem: HubLayers] = [:]
    private var routes: [String: RouteLayers] = [:]
    private var bubbles: [String: BubbleLayers] = [:]
    private var lastSize: CGSize = .zero
    private var hasContent = false

    init() {
        super.init(frame: .zero)
        root.isGeometryFlipped = true
        layer = root          // set before wantsLayer: that makes this a layer-hosting view
        wantsLayer = true
        for l in [routeLayer, hubLayer, bubbleLayer] { root.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    /// Drawing only: hover and clicks go to the SwiftUI targets above.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Shape and text layers rasterize at contentsScale; keep them sharp when moving between displays.
        func rescale(_ l: CALayer) { l.contentsScale = scale; l.sublayers?.forEach(rescale) }
        rescale(root)
    }

    func update(_ c: StressMapLayers) {
        let size = c.geometry.size
        // Animate only real changes between samples: not the first frame, not a resize (which should just follow the
        // window), and not when animations are off.
        let animated = c.animate && hasContent && size == lastSize
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Self.duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for l in [root, routeLayer, hubLayer, bubbleLayer] { l.frame = CGRect(origin: .zero, size: size) }
        updateHubs(c)
        updateRoutes(c, animated: animated)
        updateBubbles(c, animated: animated)
        CATransaction.commit()
        hasContent = true; lastSize = size
    }

    // MARK: Helpers

    private func cg(_ c: Color, _ alpha: Double = 1) -> CGColor { NSColor(c.opacity(alpha)).cgColor }
    private func circle(_ center: CGPoint, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: nil)
    }
    private func make<L: CALayer>(_ l: L) -> L { l.contentsScale = scale; return l }

    /// Fades a layer out over a transition (or at once) and removes it afterwards.
    private func retire(_ l: CALayer, animated: Bool) {
        guard animated else { l.removeFromSuperlayer(); return }
        let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = l.presentation()?.opacity ?? l.opacity; a.toValue = 0
        a.duration = Self.duration; a.fillMode = .forwards; a.isRemovedOnCompletion = false
        l.add(a, forKey: "retire")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { l.removeFromSuperlayer() }
    }

    // MARK: Hubs

    /// One hub: glow, panel-coloured disc, stress tint and rim, the stress arc (a meter: full circle = fully stressed)
    /// over its track, and a dashed outline used instead when the subsystem isn't measured.
    final class HubLayers {
        let glow = CAGradientLayer(), base = CAShapeLayer(), tint = CAShapeLayer(), track = CAShapeLayer(), arc = CAShapeLayer(), dashed = CAShapeLayer()
        var breath: Double = -1
    }

    private func updateHubs(_ c: StressMapLayers) {
        let g = c.geometry, p = c.palette, r = g.hubR
        for (i, sub) in MapGeometry.order.enumerated() {
            let h: HubLayers
            if let existing = hubs[sub] { h = existing } else {
                h = HubLayers(); hubs[sub] = h
                h.glow.type = .radial; h.glow.startPoint = CGPoint(x: 0.5, y: 0.5); h.glow.endPoint = CGPoint(x: 1, y: 1)
                for l in [h.glow, h.base, h.tint, h.track, h.arc, h.dashed] as [CALayer] { hubLayer.addSublayer(make(l)) }
                for s in [h.base, h.tint, h.track, h.arc, h.dashed] { s.fillColor = nil }
                h.track.lineWidth = 3; h.arc.lineWidth = 3; h.arc.lineCap = .round; h.tint.lineWidth = 1.2
                h.dashed.lineWidth = 1; h.dashed.lineDashPattern = [3, 3]
            }
            let pt = g.hub(sub), st = c.report.hub(sub)?.stress
            let col = st.map(p.strain) ?? p.dim
            h.base.path = circle(pt, r); h.base.fillColor = cg(p.panel)
            h.tint.path = circle(pt, r); h.track.path = circle(pt, r + 4)
            // The arc runs clockwise from 12 o'clock (angles grow clockwise in this flipped space); strokeEnd is the meter.
            let arcPath = CGMutablePath()
            arcPath.addArc(center: pt, radius: r + 4, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
            h.arc.path = arcPath
            h.dashed.path = circle(pt, r); h.dashed.strokeColor = cg(p.dim, 0.6)
            let measured = st != nil
            for l in [h.glow, h.tint, h.track, h.arc] as [CALayer] { l.opacity = measured ? 1 : 0 }
            h.dashed.opacity = measured ? 0 : 1
            guard let st else { h.glow.removeAnimation(forKey: "breath"); h.breath = -1; continue }
            let halo = r * MapStyle.haloScale(st)
            h.glow.bounds = CGRect(x: 0, y: 0, width: 2 * halo, height: 2 * halo); h.glow.position = pt
            h.glow.colors = [cg(col, MapStyle.haloAlpha(st)), cg(col, MapStyle.haloAlpha(st)), cg(col, 0)]
            h.glow.locations = [0, NSNumber(value: Double(0.7 / MapStyle.haloScale(st))), 1]
            h.tint.fillColor = cg(col, MapStyle.hubTint(st)); h.tint.strokeColor = cg(col, 0.85)
            h.track.strokeColor = cg(p.meterOff)
            h.arc.strokeColor = cg(col)
            h.arc.strokeEnd = CGFloat(st)
            h.arc.opacity = st > 0.005 ? 1 : 0
            // Ambient: the glow breathes, more for a more strained hub, each hub on its own phase. Re-added only when
            // the amplitude changes noticeably, so a steady hub keeps its rhythm.
            let amp = c.animate && st > 0.05 ? 0.12 * st / Double(MapStyle.haloScale(st)) : 0
            if abs(amp - h.breath) > 0.01 {
                h.glow.removeAnimation(forKey: "breath")
                if amp > 0 {
                    let a = CABasicAnimation(keyPath: "transform.scale"); a.fromValue = 1 - amp; a.toValue = 1 + amp
                    a.duration = 1.4; a.autoreverses = true; a.repeatCount = .infinity
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    a.beginTime = CACurrentMediaTime() - Double(i) * 0.37
                    h.glow.add(a, forKey: "breath")
                }
                h.breath = amp
            }
        }
    }

    // MARK: Routes

    /// One route: a gradient (app colour → hub colour) seen through a stroked-path mask, plus "traffic": short dashes
    /// flowing toward the hub, faster for a bigger contribution.
    final class RouteLayers {
        let gradient = CAGradientLayer(), mask = CAShapeLayer(), traffic = CAShapeLayer()
        var speed: Double = -1
    }

    private func updateRoutes(_ c: StressMapLayers, animated: Bool) {
        let g = c.geometry, p = c.palette, size = g.size
        var seen = Set<String>()
        for b in c.bubbles {
            let from = p.strain(b.m.hung ? 1 : b.m.worst)
            let fade = c.hovered != nil && c.hovered != b.id
            for (sub, k) in b.m.contributions where k >= 0.01 {
                let key = "\(b.id)|\(sub.rawValue)"
                seen.insert(key)
                let rt = g.route(from: b.center, to: sub)
                let path = CGMutablePath(); path.move(to: b.center); path.addQuadCurve(to: rt.end, control: rt.control)
                let alpha = fade ? 0.07 : MapStyle.routeAlpha(k)
                let to = p.strain(c.report.hub(sub)?.stress ?? 0)
                let isNew = routes[key] == nil
                let r: RouteLayers
                if let existing = routes[key] { r = existing } else {
                    r = RouteLayers(); routes[key] = r
                    r.mask.fillColor = nil; r.mask.strokeColor = NSColor.black.cgColor; r.mask.lineCap = .round
                    r.gradient.mask = make(r.mask)
                    r.traffic.fillColor = nil; r.traffic.lineCap = .round; r.traffic.lineDashPattern = [2, 14]
                    routeLayer.addSublayer(make(r.gradient)); routeLayer.addSublayer(make(r.traffic))
                }
                // A new route appears at its final shape and fades in, rather than flying in from the origin.
                if isNew {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    r.gradient.frame = CGRect(origin: .zero, size: size); r.mask.frame = r.gradient.bounds
                    r.mask.path = path; r.traffic.path = path; r.gradient.opacity = 0; r.traffic.opacity = 0
                    CATransaction.commit()
                }
                r.gradient.frame = CGRect(origin: .zero, size: size); r.mask.frame = r.gradient.bounds
                r.mask.path = path; r.mask.lineWidth = MapStyle.routeWidth(k)
                // Gradient points are in the layer's unit square; the flipped root makes (0,0) the top-left, as in SwiftUI.
                r.gradient.startPoint = CGPoint(x: b.center.x / max(size.width, 1), y: b.center.y / max(size.height, 1))
                r.gradient.endPoint = CGPoint(x: rt.end.x / max(size.width, 1), y: rt.end.y / max(size.height, 1))
                r.gradient.colors = [cg(from, alpha), cg(to, alpha)]
                r.gradient.opacity = 1
                r.traffic.path = path
                r.traffic.lineWidth = max(1, MapStyle.routeWidth(k) * 0.45)
                r.traffic.strokeColor = NSColor.white.withAlphaComponent(0.22 * alpha).cgColor
                r.traffic.opacity = c.animate && !fade ? 1 : 0
                let speed = c.animate ? 14 + 50 * min(1, k * 2.5) : 0   // points per second
                if abs(speed - r.speed) > 4 {
                    r.traffic.removeAnimation(forKey: "flow")
                    if speed > 0 {
                        // Moving the dash phase backwards by one dash period (16 pt) moves the dashes toward the hub.
                        let a = CABasicAnimation(keyPath: "lineDashPhase"); a.fromValue = 0; a.toValue = -16
                        a.duration = 16 / speed; a.repeatCount = .infinity
                        r.traffic.add(a, forKey: "flow")
                    }
                    r.speed = speed
                }
            }
        }
        for (key, r) in routes where !seen.contains(key) {
            retire(r.gradient, animated: animated); retire(r.traffic, animated: animated)
            routes[key] = nil
        }
    }

    // MARK: Bubbles

    /// One app bubble: a radial-gradient disc with a rim, the app icon, an optional name tag below, and for a hung app
    /// a dashed red ring and a stop badge. The container carries position, size, glow (shadow) and dimming.
    final class BubbleLayers {
        let container = CALayer(), disc = CAGradientLayer(), icon = CALayer(), ring = CAShapeLayer(), badge = CALayer()
        let tag = CALayer(), text = CATextLayer()
        var iconPath = ""
        var name = ""
    }

    private func updateBubbles(_ c: StressMapLayers, animated: Bool) {
        let p = c.palette
        var seen = Set<String>()
        for (rank, b) in c.bubbles.enumerated() {
            seen.insert(b.id)
            let isNew = bubbles[b.id] == nil
            let L: BubbleLayers
            if let existing = bubbles[b.id] { L = existing } else {
                L = BubbleLayers(); bubbles[b.id] = L
                L.disc.type = .radial; L.disc.startPoint = CGPoint(x: 0.5, y: 0.5); L.disc.endPoint = CGPoint(x: 1, y: 1)
                L.disc.masksToBounds = true
                L.icon.contentsGravity = .resizeAspect
                L.ring.fillColor = nil; L.ring.lineWidth = 2; L.ring.lineDashPattern = [5, 3]
                L.text.alignmentMode = .center; L.text.truncationMode = .end
                L.container.shadowOffset = .zero
                for l in [L.disc, L.ring, L.icon, L.badge, L.tag] { L.container.addSublayer(make(l)) }
                L.tag.addSublayer(make(L.text))
                bubbleLayer.addSublayer(make(L.container))
            }
            let r = b.radius, m = b.m
            let col = m.hung ? p.crit : p.strain(m.worst)
            let highlighted = c.hovered == b.id, dimmed = c.hovered != nil && !highlighted
            if isNew {
                // Appear at the target spot (no flying in from the corner), then grow in below.
                CATransaction.begin(); CATransaction.setDisableActions(true)
                L.container.position = b.center; L.container.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
                CATransaction.commit()
            }
            L.container.position = b.center
            L.container.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
            L.container.opacity = dimmed ? 0.35 : 1
            L.container.shadowColor = cg(col)
            L.container.shadowOpacity = highlighted ? 0.9 : 0.5
            L.container.shadowRadius = highlighted ? 12 : 5
            L.container.shadowPath = circle(CGPoint(x: r, y: r), r)
            L.disc.frame = L.container.bounds; L.disc.cornerRadius = r
            L.disc.colors = [cg(col, m.hung ? 0.8 : 0.6), cg(col, m.hung ? 0.4 : 0.22)]
            L.disc.borderColor = cg(col, 0.95); L.disc.borderWidth = highlighted ? 2.5 : 1.2
            // Icon: the app's own, or a gear for processes outside an app bundle (as AppIcon does). Hidden when tiny.
            let path = appIconPath(m.app)
            if path != L.iconPath {
                if let range = path.range(of: ".app/") {
                    L.icon.contents = IconCache.icon(String(path[..<range.lowerBound]) + ".app")
                } else {
                    L.icon.contents = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(paletteColors: [NSColor(p.dim)]))
                }
                L.iconPath = path
            }
            let s = min(r * 1.05, 40)
            L.icon.frame = CGRect(x: r - s / 2, y: r - s / 2, width: s, height: s)
            L.icon.opacity = r >= 13 ? 1 : 0
            L.ring.path = circle(CGPoint(x: r, y: r), r + 6); L.ring.strokeColor = cg(p.crit); L.ring.opacity = m.hung ? 1 : 0
            if m.hung && L.badge.contents == nil {
                L.badge.contents = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [.white, NSColor(p.crit)])))
            }
            L.badge.frame = CGRect(x: 2 * r - 12, y: -6, width: 18, height: 18); L.badge.opacity = m.hung ? 1 : 0
            updateTag(L, m: m, r: r, show: rank < c.labelled || highlighted, p: p)
            if isNew && animated {
                for (key, from) in [("transform.scale", 0.05), ("opacity", 0.0)] {
                    let a = CABasicAnimation(keyPath: key); a.fromValue = from; a.toValue = 1
                    a.duration = Self.duration; a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    L.container.add(a, forKey: "appear-" + key)
                }
            }
        }
        for (id, L) in bubbles where !seen.contains(id) {
            if animated {
                let a = CABasicAnimation(keyPath: "transform.scale"); a.toValue = 0.05
                a.duration = Self.duration; a.fillMode = .forwards; a.isRemovedOnCompletion = false
                L.container.add(a, forKey: "shrink")
            }
            retire(L.container, animated: animated)
            bubbles[id] = nil
        }
    }

    /// The name tag under a bubble: a translucent capsule with the (shortened) name, red "· not responding" for a hung
    /// app. Long daemon names would cover neighbouring bubbles; the full name is in the side panel.
    private func updateTag(_ L: BubbleLayers, m: AppMisery, r: CGFloat, show: Bool, p: Palette) {
        L.tag.opacity = show ? 1 : 0
        guard show else { return }
        let short = m.app.name.count > 16 ? String(m.app.name.prefix(15)) + "…" : m.app.name
        let name = m.hung ? "\(short) · not responding" : short
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        if name != L.name {
            L.text.string = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor(m.hung ? p.crit : p.text)])
            L.name = name
        }
        let w = ceil((name as NSString).size(withAttributes: [.font: font]).width) + 10, h: CGFloat = 15
        L.tag.frame = CGRect(x: r - w / 2, y: 2 * r + 4, width: w, height: h)
        L.tag.backgroundColor = cg(p.background, 0.75); L.tag.cornerRadius = h / 2
        L.text.frame = CGRect(x: 0, y: 1, width: w, height: h - 1)
    }
}
