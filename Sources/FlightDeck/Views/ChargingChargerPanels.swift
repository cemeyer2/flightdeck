// Charging insights: the charger panel (rated power, the USB-PD offers and the contract in use, port, weak-charger
// warnings) and the live flow diagram (adapter → Mac and adapter → battery, or battery → Mac). See ChargingSection.swift.
import SwiftUI
import FlightDeckCore

/// What the charger negotiated: "This charger offers 5/9/15/20 V; it's using 20 V × 4.7 A = 94 W".
struct ChargerPanel: View {
    @Environment(\.palette) var p
    var inputs: ChargingInputs

    var body: some View {
        let a = inputs.details?.adapter
        let connected = inputs.battery?.externalConnected ?? false
        Panel(title: "Charger", trailing: a.map { [$0.name, $0.manufacturer].compactMap { $0 }.joined(separator: " · ") } ?? (connected ? nil : "not connected")) {
            if !connected {
                Text("Running on battery. Connect a charger to see what it offers and what this Mac negotiated.").foregroundStyle(p.dim)
            } else if let a {
                HStack(spacing: 28) {
                    Readout(label: "Rated", value: a.watts.map(String.init), unit: "W")
                    // The contract's voltage: as negotiated when reported, else what the adapter says it supplies.
                    let cv = a.volts ?? a.adapterVolts
                    Readout(label: "Contract", value: cv.flatMap { v in a.amps.map { String(format: "%g V × %.2f A", v, $0) } }, size: 16)
                    Readout(label: "Negotiated", value: cv.flatMap { v in a.amps.map { String(format: "%.0f", v * $0) } }, unit: "W", color: p.accent)
                    Readout(label: "Type", value: a.familyName ?? a.adapterDescription, size: 16)
                    Readout(label: "Port", value: a.port.map { "controller \($0 + 1) of \(a.portCount ?? $0 + 1)" }, size: 16)
                    Readout(label: "Wireless", value: a.isWireless.map { $0 ? "Yes" : "No" }, size: 16)
                    Spacer()
                }
                offers(a)
            } else {
                Text("External power is connected, but this Mac doesn't report the adapter's details.").foregroundStyle(p.dim)
            }
            let warn = ChargerCheck.warnings(adapter: a, flow: inputs.flow, charger: inputs.details?.charger, peakSystemW: inputs.peakSystemW)
            ForEach(warn, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(p.warn).font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder func offers(_ a: AdapterReport) -> some View {
        if a.offers.isEmpty {
            Text("USB-PD offers: \(notReported).").font(.caption).foregroundStyle(p.dim)
        } else {
            Text(sentence(a)).font(.system(size: 12, weight: .semibold, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(a.offers, id: \.self) { o in
                    let active = o.index == a.activeOfferIndex
                    VStack(spacing: 2) {
                        Text(label(o)).font(.system(size: 12, weight: active ? .bold : .regular, design: .monospaced))
                        Text(o.amps.map { String(format: "%.2f A", $0) } ?? o.maxWatts.map { String(format: "%.0f W", $0) } ?? "")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(active ? p.accent : p.text)
                    .background(RoundedRectangle(cornerRadius: 5).fill(active ? p.accent.opacity(0.15) : p.meterOff.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(active ? p.accent : p.panelBorder))
                }
                Spacer()
            }
            Text(a.offersSource == .portController
                 ? "Offers decoded from the USB-C port controller's Power Delivery capabilities; the highlighted one matches the voltage the charger is supplying."
                 : "Offers from the charger's USB-PD menu as macOS reports it; the highlighted one is in use.")
                .font(.caption).foregroundStyle(p.dim)
        }
    }

    func label(_ o: PDOffer) -> String {
        o.kind == .fixed ? String(format: "%g V", o.volts) : String(format: "%g–%g V", o.minVolts ?? 0, o.volts) + (o.kind == .avs ? " AVS" : " PPS")
    }

    /// The headline sentence; the "using" half only when the contract's numbers are reported.
    func sentence(_ a: AdapterReport) -> String {
        let volts = a.offers.filter { $0.kind == .fixed }.map { String(format: "%g", $0.volts) }.joined(separator: "/")
        var s = "This charger offers \(volts) V"
        if a.offers.contains(where: { $0.kind != .fixed }) { s += " plus adjustable ranges" }
        if let v = a.volts ?? a.adapterVolts ?? a.activeOffer?.volts, let i = a.amps ?? a.activeOffer?.amps {
            s += String(format: "; it's using %g V × %.3g A = %.0f W", v, i, v * i)
        }
        return s + "."
    }
}

/// Live flow: watts on each edge, updated every sample. Line thickness scales with power.
struct ChargeFlowPanel: View {
    @Environment(\.palette) var p
    var inputs: ChargingInputs

    var body: some View {
        let f = inputs.flow
        Panel(title: "Power flow", trailing: f.map { $0.source == .adapter ? "on adapter" : "on battery" }) {
            if let f {
                FlowDiagram(flow: f).frame(height: 170)
                HStack(spacing: 28) {
                    Readout(label: "From adapter", value: f.adapterIn.map { String(format: "%.1f", $0) }, unit: "W", size: 16)
                    Readout(label: "Mac uses", value: f.mac.map { String(format: "%.1f", $0) }, unit: "W", color: p.accent, size: 16)
                    // Signed like Amperage: + charging, − draining.
                    Readout(label: "Battery", value: f.battery.map { String(format: "%+.1f", $0) }, unit: "W", color: p.accent2, size: 16)
                    Readout(label: "Conversion loss", value: f.loss.map { String(format: "%.1f", $0) }, unit: "W", size: 16)
                    Spacer()
                }
                Text("Battery power is voltage × current (positive while charging). Adapter input, the Mac's own draw and conversion loss come from the power controller's telemetry where this Mac publishes it. The two come from different meters (instant current vs averaged telemetry), so they can differ by a watt or two. \"—\" means \(notReported).")
                    .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Battery power readings are \(notReported).").foregroundStyle(p.dim)
            }
        }
    }
}

/// Adapter at left feeding the Mac (top right) and the battery (bottom right); on battery, battery → Mac.
struct FlowDiagram: View {
    @Environment(\.palette) var p
    var flow: ChargeFlow

    var body: some View {
        Canvas { ctx, size in
            let left = CGPoint(x: 90, y: size.height / 2)
            let mac = CGPoint(x: size.width - 90, y: flow.source == .adapter ? 34 : size.height / 2)
            let bat = CGPoint(x: size.width - 90, y: size.height - 34)
            // Thickness: 1.5 pt plus 0.1 pt per watt, capped, so 90 W reads clearly thicker than 10 W.
            func edge(_ a: CGPoint, _ b: CGPoint, _ w: Double?, _ c: Color) {
                let lw = CGFloat(min(1.5 + (w ?? 0) * 0.1, 10))
                let from = CGPoint(x: a.x + 64, y: a.y), to = CGPoint(x: b.x - 64, y: b.y)
                var path = Path(); path.move(to: from)
                path.addCurve(to: to, control1: CGPoint(x: (from.x + to.x) / 2, y: from.y), control2: CGPoint(x: (from.x + to.x) / 2, y: to.y))
                ctx.stroke(path, with: .color(w == nil ? p.dim.opacity(0.4) : c.opacity(0.85)), style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: w == nil ? [4, 4] : []))
                var head = Path(); head.move(to: to); head.addLine(to: CGPoint(x: to.x - 9, y: to.y - 5)); head.addLine(to: CGPoint(x: to.x - 9, y: to.y + 5)); head.closeSubpath()
                ctx.fill(head, with: .color(c))
                let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - 12)
                ctx.draw(Text(w.map { String(format: "%.1f W", $0) } ?? "—").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(w == nil ? p.dim : c), at: mid)
            }
            func node(_ c: CGPoint, _ title: String, _ icon: String, _ sub: String?) {
                let r = CGRect(x: c.x - 64, y: c.y - 24, width: 128, height: 48)
                ctx.fill(Path(roundedRect: r, cornerRadius: 8), with: .color(p.meterOff.opacity(0.6)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 8), with: .color(p.panelBorder), lineWidth: 1)
                ctx.draw(Text("\(Image(systemName: icon)) \(title)").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(p.text), at: CGPoint(x: c.x, y: c.y - 8))
                if let sub { ctx.draw(Text(sub).font(.system(size: 10, design: .monospaced)).foregroundColor(p.dim), at: CGPoint(x: c.x, y: c.y + 10)) }
            }
            if flow.source == .adapter {
                edge(left, mac, flow.adapterToMac, p.accent)
                edge(left, bat, flow.adapterToBattery, p.accent2)
                // A battery top-up while plugged in (charger too weak) is drawn battery → Mac.
                if let b = flow.batteryToMac, b > 0.5 {
                    var path = Path(); path.move(to: CGPoint(x: bat.x, y: bat.y - 24)); path.addLine(to: CGPoint(x: mac.x, y: mac.y + 24))
                    ctx.stroke(path, with: .color(p.warn), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                    ctx.draw(Text(String(format: "%.1f W", b)).font(.system(size: 11, design: .monospaced)).foregroundColor(p.warn), at: CGPoint(x: mac.x + 40, y: size.height / 2))
                }
                node(left, "Adapter", "powerplug.fill", flow.adapterIn.map { String(format: "%.1f W in", $0) })
                node(mac, "Mac", "laptopcomputer", flow.mac.map { String(format: "%.1f W", $0) })
                node(bat, "Battery", "battery.100.bolt", flow.battery.map { $0 > 0.05 ? "charging" : $0 < -0.05 ? "discharging" : "idle" })
            } else {
                edge(left, mac, flow.batteryToMac, p.accent2)
                node(left, "Battery", "battery.50", "discharging")
                node(mac, "Mac", "laptopcomputer", flow.mac.map { String(format: "%.1f W", $0) })
            }
        }
    }
}
