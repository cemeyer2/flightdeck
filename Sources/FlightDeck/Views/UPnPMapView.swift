import SwiftUI
import FlightDeckCore

// The UPnP map: the router (Internet Gateway Device) at the centre and every other UPnP host around it, grouped into
// sectors by category (media renderers, media servers, printers, other). It's a grouping, not measured topology: UPnP
// doesn't say which device connects through what. Drawn entirely in SwiftUI (a Canvas for the links, plain views for
// the nodes) so it renders off-screen for `--render-views`.

struct UPnPMapView: View {
    @Environment(\.palette) var p
    var hosts: [UPnPHostGroup]
    /// The gateway that answered the IGD calls, if any (its host goes in the centre).
    var gatewayIP: String?
    @Binding var selection: String?

    /// The centre host: the gateway with port-mapping service, else any gateway-category host.
    var centre: UPnPHostGroup? { hosts.first { $0.ip == gatewayIP } ?? hosts.first { $0.category == .gateway } }

    var body: some View {
        GeometryReader { geo in
            let layout = Self.layout(hosts.filter { $0.id != centre?.id }, in: geo.size)
            let mid = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Canvas { ctx, _ in
                    // Faint category sector labels' guide ring, then a link from the centre to each node.
                    let r = min(geo.size.width, geo.size.height) * 0.30
                    ctx.stroke(Path(ellipseIn: CGRect(x: mid.x - r, y: mid.y - r, width: 2 * r, height: 2 * r)), with: .color(p.grid), lineWidth: 1)
                    for n in layout.nodes {
                        var path = Path(); path.move(to: mid); path.addLine(to: n.point)
                        let sel = n.host.id == selection
                        ctx.stroke(path, with: .color(sel ? p.accent : color(n.host.category).opacity(0.35)), lineWidth: sel ? 2 : 1)
                    }
                }
                ForEach(layout.labels, id: \.text) { l in
                    Text(l.text.uppercased()).font(.meterLabel).foregroundStyle(color(l.category).opacity(0.9))
                        .position(l.point)
                }
                hub.position(mid)
                ForEach(layout.nodes, id: \.host.id) { n in
                    node(n.host).position(n.point)
                }
            }
        }
    }

    /// The centre: the router if there is one, else a plain "this network" hub (no gateway answered).
    @ViewBuilder var hub: some View {
        if let c = centre {
            node(c, size: 54)
        } else {
            VStack(spacing: 3) {
                Image(systemName: "network").font(.system(size: 22)).foregroundStyle(p.dim)
                    .frame(width: 54, height: 54).background(Circle().strokeBorder(p.panelBorder, lineWidth: 1.5))
                Text("no UPnP router").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
            }
        }
    }

    func node(_ h: UPnPHostGroup, size: CGFloat = 36) -> some View {
        let sel = h.id == selection
        let c = color(h.category)
        return VStack(spacing: 3) {
            Image(systemName: Self.symbol(h.category)).font(.system(size: size * 0.42)).foregroundStyle(c)
                .frame(width: size, height: size)
                .background(Circle().fill(p.panel))
                .overlay(Circle().strokeBorder(sel ? p.accent : c.opacity(0.7), lineWidth: sel ? 2.5 : 1.5))
                .shadow(color: c.opacity(p.glow > 0 ? 0.6 : 0), radius: p.glow)
            Text(h.displayName).font(.system(size: 10, weight: sel ? .bold : .regular, design: .monospaced))
                .foregroundStyle(sel ? p.text : p.dim).lineLimit(1).frame(maxWidth: 96)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = h.id }
        .help("\(h.displayName) · \(h.ip)")
    }

    func color(_ c: UPnPCategory) -> Color {
        if p.mono { return p.accent }
        switch c {
        case .gateway: return p.accent
        case .mediaRenderer: return Color(red: 0.55, green: 0.65, blue: 1.0)
        case .mediaServer: return Color(red: 0.35, green: 0.80, blue: 0.55)
        case .printer: return Color(red: 0.95, green: 0.70, blue: 0.30)
        case .other: return p.dim
        }
    }

    static func symbol(_ c: UPnPCategory) -> String {
        switch c {
        case .gateway: "wifi.router"; case .mediaRenderer: "tv.and.hifispeaker.fill"; case .mediaServer: "externaldrive.connected.to.line.below"
        case .printer: "printer"; case .other: "questionmark.circle"
        }
    }

    struct Node { var host: UPnPHostGroup; var point: CGPoint }
    struct SectorLabel { var text: String; var category: UPnPCategory; var point: CGPoint }

    /// Places hosts around the centre. Each category with hosts gets an angular sector sized by its host count (with a
    /// minimum so a lone printer still has room for its label); within a sector, nodes alternate between two rings
    /// when crowded, so a house full of speakers stays legible. Ellipse radii follow the view's aspect ratio.
    static func layout(_ hosts: [UPnPHostGroup], in size: CGSize) -> (nodes: [Node], labels: [SectorLabel]) {
        let groups = UPnPCategory.allCases.compactMap { c -> (UPnPCategory, [UPnPHostGroup])? in
            let h = hosts.filter { $0.category == c }; return h.isEmpty ? nil : (c, h)
        }
        guard !groups.isEmpty else { return ([], []) }
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        let rx = size.width / 2 - 70, ry = size.height / 2 - 40   // room for labels at the edges
        let weights = groups.map { max(Double($0.1.count), 1.5) }
        let total = weights.reduce(0, +)
        var start = -Double.pi / 2   // first sector starts at the top
        var nodes: [Node] = [], labels: [SectorLabel] = []
        for (gi, (cat, hs)) in groups.enumerated() {
            let span = 2 * Double.pi * weights[gi] / total
            // Up to three rings once a sector holds more nodes than fit side by side (~90 pt apart) on the outer one;
            // consecutive nodes go to different rings so neighbouring labels don't collide.
            let perimeter = span * Double(min(rx, ry))
            let rings = min(3, max(1, Int((Double(hs.count) * 90 / perimeter).rounded(.up))))
            let radii = [0.94, 0.70, 0.48]
            for (i, h) in hs.enumerated() {
                let a = start + span * (Double(i) + 0.5) / Double(hs.count)
                let k = radii[i % rings]
                nodes.append(Node(host: h, point: CGPoint(x: mid.x + rx * k * cos(a), y: mid.y + ry * k * sin(a))))
            }
            let la = start + span / 2
            labels.append(SectorLabel(text: "\(cat.rawValue) · \(hs.count)", category: cat,
                                      point: CGPoint(x: mid.x + rx * 0.30 * cos(la), y: mid.y + ry * 0.30 * sin(la))))
            start += span
        }
        return (nodes, labels)
    }
}
