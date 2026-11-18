import SwiftUI
import FlightDeckCore

// The Network view's map. This Mac sits on the left, linked through its interface (with the Wi-Fi access point) into
// the subnet, drawn as a dashed ring; the devices seen on that subnet sit on the ring, the gateway at its right edge,
// and the path to the internet (with traceroute hops, when traced) continues to the right. Other interfaces (VPN
// tunnels, a second Ethernet) are smaller lanes below. The ring deliberately joins devices to the subnet rather than
// to the router or each other: which switch port or access point a device uses can't be seen from this Mac.
//
// Same house style as the Stress Map: links, ring and labels are drawn in one Canvas; only the device nodes are
// views, because they need hover and click. Nothing animates, so the off-screen render is the same picture.

/// Where everything goes for a given map size.
struct NetMapLayout {
    var size: CGSize
    var extraLanes: Int
    static let laneH: CGFloat = 58
    var mainH: CGFloat { size.height - CGFloat(extraLanes) * Self.laneH }
    var center: CGPoint { CGPoint(x: size.width * 0.45, y: mainH / 2 + 10) }
    var ringR: CGFloat { max(80, min(size.width * 0.23, mainH * 0.32)) }
    var mac: CGPoint { CGPoint(x: 40, y: center.y) }
    var ringLeft: CGPoint { CGPoint(x: center.x - ringR, y: center.y) }
    var gateway: CGPoint { CGPoint(x: center.x + ringR, y: center.y) }
    var internet: CGPoint { CGPoint(x: size.width - 54, y: center.y) }
    func lane(_ i: Int) -> CGFloat { mainH + Self.laneH * (CGFloat(i) + 0.5) }

    /// Device positions on the ring, leaving clear arcs beside the gateway (right, 28°) and, wider, beside the Mac's
    /// link (left, 44°), whose label block sits above it. When the ring gets crowded, every other device moves to an
    /// outer track so labels don't overlap. At most `capacity` devices.
    func devicePositions(_ n: Int) -> [CGPoint] {
        guard n > 0 else { return [] }
        let gap = 28.0, gapLeft = 44.0, span = 180 - gap - gapLeft   // per arc, in degrees
        let arcLen = Double(ringR) * span * .pi / 180 * 2
        let stagger = arcLen / Double(n) < 64
        return (0..<n).map { i in
            // Alternate top and bottom arcs so a few devices spread evenly around the ring.
            let top = i % 2 == 0, k = i / 2, count = top ? (n + 1) / 2 : n / 2
            let t = count == 1 ? 0.5 : Double(k) / Double(count - 1)
            // Screen angles (y grows downward): 0° is the gateway on the right, 180° the Mac's link on the left, so the
            // top arc runs through negative angles and the bottom arc through positive ones.
            let deg = top ? -(gap + t * span) : gap + t * span
            let a = deg * .pi / 180
            let r = ringR + (stagger && k % 2 == 1 ? 42 : 0)
            return CGPoint(x: center.x + r * CGFloat(Foundation.cos(a)), y: center.y + r * CGFloat(Foundation.sin(a)))
        }
    }
    var capacity: Int { Int(Double(ringR) * 2 * .pi * 0.69 / 32) }
}

struct NetworkMap: View {
    @Environment(\.palette) var p
    var survey: NetworkSurvey
    var hops: [TraceHop]
    @Binding var selected: String?
    @Binding var hovered: String?

    /// The branch drawn as the ring: the first non-VPN branch (the default-route one when it's physical).
    var ring: NetBranch? { survey.topology.branches.first { $0.interface.kind != .vpn } }
    var lanes: [NetBranch] { survey.topology.branches.filter { $0.id != ring?.id } }

    var body: some View {
        GeometryReader { geo in
            let g = NetMapLayout(size: geo.size, extraLanes: lanes.count)
            let ids = Array((ring?.devices ?? []).prefix(g.capacity))
            let pts = g.devicePositions(ids.count)
            ZStack {
                Canvas { ctx, _ in draw(&ctx, g, pts) }
                ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                    if let d = survey.device(id) { node(d, at: pts[i], r: 17) }
                }
                if let gw = ring?.gateway.flatMap(survey.device) { node(gw, at: g.gateway, r: 22) }
                if let me = survey.devices.first(where: \.isThisMac) { node(me, at: g.mac, r: 22) }
            }
        }
    }

    /// One device: an icon disc, its name below; hover highlights, click selects.
    func node(_ d: NetDevice, at pt: CGPoint, r: CGFloat) -> some View {
        let on = selected == d.id || hovered == d.id
        let col = d.isGateway || d.isThisMac ? p.accent : (d.kind == .unknown ? p.dim : p.accent2)
        return ZStack {
            Circle().fill(p.panel)
            Circle().fill(col.opacity(on ? 0.35 : 0.16))
            Circle().strokeBorder(col.opacity(on ? 1 : 0.7), lineWidth: on ? 2 : 1)
            Image(systemName: d.kind.icon).font(.system(size: r * 0.8)).foregroundStyle(on ? p.text : col)
        }
        .frame(width: r * 2, height: r * 2)
        .shadow(color: col.opacity(on ? 0.8 : 0.3), radius: on ? 8 : 3)
        .overlay(alignment: .bottom) {
            let n = d.displayName
            Text(n.count > 16 ? n.prefix(15) + "…" : n)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(on ? p.text : p.dim)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 4).background(Capsule().fill(p.background.opacity(0.7)))
                .alignmentGuide(.bottom) { $0[.top] - 3 }
        }
        .contentShape(Circle())
        .onHover { inside in if inside { hovered = d.id } else if hovered == d.id { hovered = nil } }
        .onTapGesture { selected = d.id }
        .help("\(d.displayName) · \(d.kind.rawValue) · \(d.primaryIP)")
        .position(pt)
    }

    func text(_ s: String, _ size: CGFloat = 10, _ c: Color? = nil, bold: Bool = false) -> Text {
        Text(s).font(.system(size: size, weight: bold ? .bold : .regular, design: .monospaced)).foregroundColor(c ?? p.dim)
    }

    func draw(_ ctx: inout GraphicsContext, _ g: NetMapLayout, _ pts: [CGPoint]) {
        let c = g.center, r = g.ringR
        func line(_ a: CGPoint, _ b: CGPoint, _ col: Color, _ w: CGFloat = 2, dash: [CGFloat] = []) {
            var path = Path(); path.move(to: a); path.addLine(to: b)
            ctx.stroke(path, with: .color(col), style: StrokeStyle(lineWidth: w, lineCap: .round, dash: dash))
        }
        guard let ring else {
            ctx.draw(text("No active network interface with an address.", 12, p.text), at: c)
            return
        }
        // Subnet: a soft disc and a dashed ring.
        let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(disc, with: .radialGradient(Gradient(colors: [p.accent.opacity(0.08), .clear]), center: c, startRadius: 0, endRadius: r))
        ctx.stroke(disc, with: .color(p.accent.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        // Short spokes from each device to the ring for devices on the outer track.
        for pt in pts {
            let dx = pt.x - c.x, dy = pt.y - c.y, d = max(hypot(dx, dy), 1)
            if d > r + 4 { line(CGPoint(x: c.x + dx / d * r, y: c.y + dy / d * r), pt, p.accent.opacity(0.3), 1, dash: [2, 3]) }
        }
        // Centre label: the subnet, its interface, and the honesty note.
        let n = ring.devices.count + (ring.gateway == nil ? 0 : 1)
        ctx.draw(text(ring.subnets.first ?? "IPv6 only", 15, p.text, bold: true), at: CGPoint(x: c.x, y: c.y - 30))
        ctx.draw(text("\(ring.interface.displayName) · \(ring.interface.name) · \(n) device\(n == 1 ? "" : "s") seen", 10.5), at: CGPoint(x: c.x, y: c.y - 10))
        let hidden = ring.devices.count - pts.count
        if hidden > 0 { ctx.draw(text("+\(hidden) more in the list below", 10, p.warn), at: CGPoint(x: c.x, y: c.y + 8)) }
        ctx.draw(text("Devices are shown on their subnet.", 9.5), at: CGPoint(x: c.x, y: c.y + 28))
        ctx.draw(text("Which switch port or access point each", 9.5), at: CGPoint(x: c.x, y: c.y + 41))
        ctx.draw(text("one uses can't be seen from this Mac.", 9.5), at: CGPoint(x: c.x, y: c.y + 54))

        // This Mac → interface → subnet.
        line(g.mac, g.ringLeft, p.accent, 2.5)
        // The interface and access point as a left-aligned block above the Mac, where there's room for a BSSID.
        let ifLabel = ring.interface.kind == .wifi ? "Wi-Fi" : ring.interface.displayName
        var lines = ["\(ifLabel) (\(ring.interface.name))"]
        if let ap = ring.accessPoint {
            lines.append(ap.ssid.map { "“\($0)”" } ?? "network name hidden")
            lines.append(ap.bssid.map { "AP \($0)" } ?? "AP BSSID hidden")
            if let ch = ap.channel { lines.append("ch " + ch) }
        }
        if let a = ring.interface.ipv4.first { lines.append("this Mac: " + a.address) }
        for (i, l) in lines.enumerated() {
            let y = g.mac.y - 36 - CGFloat(lines.count - 1 - i) * 13
            ctx.draw(text(l, i == 0 ? 10 : 9.5, i == 0 ? p.text : nil, bold: i == 0), at: CGPoint(x: 14, y: y), anchor: .leading)
        }

        // Gateway → hops → internet.
        let viaVPN = survey.topology.internetViaVPN
        let online = ring.carriesDefaultRoute || viaVPN
        let gwStart = CGPoint(x: g.gateway.x + 24, y: g.gateway.y)
        if ring.gateway == nil {
            ctx.draw(text(ring.carriesDefaultRoute ? "gateway not found" : "no default route here", 9.5), at: CGPoint(x: g.gateway.x, y: g.gateway.y - 26))
        }
        if online {
            let pathCol = viaVPN ? p.dim.opacity(0.5) : p.accent
            line(gwStart, CGPoint(x: g.internet.x - 30, y: g.internet.y), pathCol, 2.5, dash: viaVPN ? [4, 4] : [])
            if viaVPN {
                ctx.draw(text("carries the VPN tunnel", 9.5), at: CGPoint(x: (gwStart.x + g.internet.x) / 2, y: g.gateway.y - 14))
            } else if !hops.isEmpty {
                let shown = Array(hops.filter { hop in !(ring.gateway.flatMap(survey.device)?.ipv4.contains(hop.ip ?? "") ?? false) }.prefix(8))
                let x0 = gwStart.x + 18, x1 = g.internet.x - 46
                for (i, h) in shown.enumerated() {
                    let x = shown.count == 1 ? (x0 + x1) / 2 : x0 + (x1 - x0) * CGFloat(i) / CGFloat(shown.count - 1)
                    let pt = CGPoint(x: x, y: g.gateway.y)
                    let dot = Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
                    ctx.fill(dot, with: .color(h.ip == nil ? p.background : p.accent))
                    ctx.stroke(dot, with: .color(p.accent), lineWidth: 1)
                    // Alternate labels above and below; addresses only when there's room (the full list is in the
                    // "This network" panel), otherwise just the hop number and time.
                    let up = i % 2 == 0, roomy = (x1 - x0) / CGFloat(max(shown.count - 1, 1)) >= 46
                    ctx.draw(text("\(h.number)", 9, p.text, bold: true), at: CGPoint(x: x, y: pt.y + (up ? -13 : 13)))
                    ctx.draw(text(h.ms.map { String(format: "%.0f ms", $0) } ?? "—", 8.5), at: CGPoint(x: x, y: pt.y + (up ? -25 : 25)))
                    if roomy { ctx.draw(text(h.ip ?? "no reply", 8.5), at: CGPoint(x: x, y: pt.y + (up ? -37 : 37))) }
                }
            } else {
                ctx.draw(text("path not traced", 9.5), at: CGPoint(x: (gwStart.x + g.internet.x) / 2, y: g.gateway.y - 12))
            }
        }
        // Internet: a globe in a ring, lit when some branch reaches it.
        let ir: CGFloat = 26
        let ip = g.internet
        let disc2 = Path(ellipseIn: CGRect(x: ip.x - ir, y: ip.y - ir, width: 2 * ir, height: 2 * ir))
        ctx.fill(disc2, with: .color(p.panel))
        ctx.fill(disc2, with: .color((online ? p.accent : p.dim).opacity(0.15)))
        ctx.stroke(disc2, with: .color(online ? p.accent : p.dim), style: StrokeStyle(lineWidth: 1.5, dash: online ? [] : [3, 3]))
        ctx.draw(Text(Image(systemName: "globe")).font(.system(size: 24)).foregroundColor(online ? p.accent : p.dim), at: ip)
        ctx.draw(text("INTERNET", 9.5, p.text, bold: true), at: CGPoint(x: ip.x, y: ip.y + ir + 11))
        if !online { ctx.draw(text("no route", 9), at: CGPoint(x: ip.x, y: ip.y + ir + 23)) }

        // Other interfaces: one lane each, from This Mac.
        for (i, b) in lanes.enumerated() {
            let y = g.lane(i)
            let badge = CGPoint(x: g.size.width * 0.3, y: y)
            var path = Path(); path.move(to: g.mac); path.addQuadCurve(to: badge, control: CGPoint(x: g.mac.x, y: y))
            ctx.stroke(path, with: .color(p.accent.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: b.interface.kind == .vpn ? [4, 3] : []))
            let icon = b.interface.kind == .vpn ? "lock.shield" : "cable.connector"
            ctx.draw(Text(Image(systemName: icon)).font(.system(size: 14)).foregroundColor(p.accent), at: badge)
            let addr = b.subnets.first ?? b.interface.globalIPv6.first ?? ""
            let what = b.interface.kind == .vpn ? (b.carriesDefaultRoute ? "all internet traffic goes through this tunnel" : "tunnel for some routes")
                : "\(b.devices.count) device\(b.devices.count == 1 ? "" : "s") (in the list below)"
            ctx.draw(text("\(b.interface.displayName) \(b.interface.name)  \(addr)  ·  \(what)", 10, p.text), at: CGPoint(x: badge.x + 16, y: y), anchor: .leading)
            if b.carriesDefaultRoute {
                var up = Path(); up.move(to: CGPoint(x: g.size.width * 0.86, y: y)); up.addLine(to: CGPoint(x: g.internet.x, y: g.internet.y + 26))
                ctx.stroke(up, with: .color(p.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
    }
}
