import SwiftUI
import FlightDeckCore

// Peripherals › Link speeds and Accessory batteries panels. Both take finished data (PeripheralsReport.links and
// .accessories); nothing here reads the machine.

struct LinkSpeedsPanel: View {
    @Environment(\.palette) var p
    var links: LinkReport

    var body: some View {
        let slow = links.problems
        Panel(title: "Link speeds", trailing: links.usb.isEmpty && links.thunderbolt.isEmpty ? "no USB or Thunderbolt devices"
              : slow == 0 ? "all at full speed" : "\(slow) slower than they could be") {
            if links.usb.isEmpty && links.thunderbolt.isEmpty {
                Text("Nothing is plugged into a USB or Thunderbolt port.").foregroundStyle(p.dim).font(.system(size: 11))
            }
            ForEach(links.thunderbolt) { t in
                LinkRow(icon: "bolt.horizontal", name: t.name, indent: max(0, t.depth - 1), diagnosis: t.diagnosis, facts: [
                    t.currentGbps.map { "linked " + LinkRate.text($0 * 1000) + (t.currentMode.map { " (\($0))" } ?? "") } ?? "link speed not reported",
                    t.maxGbps.map { "both ends support " + LinkRate.text($0 * 1000) } ?? "capability not reported",
                    t.vendor,
                ])
            }
            ForEach(ordered, id: \.link.id) { item in
                let l = item.link
                LinkRow(icon: l.isHub ? "rectangle.connected.to.line.below" : l.isStorage ? "externaldrive" : "cable.connector",
                        name: l.name, indent: item.depth, diagnosis: l.diagnosis, facts: [
                    l.negotiatedMbps.map { "linked " + LinkRate.usbName($0) } ?? "speed not reported",
                    "device: " + l.device.text,
                    "path: " + l.port.text,
                ])
            }
        }
    }

    var ordered: [(link: USBLink, depth: Int)] { USBLinks.tree(links.usb) }
}

private struct LinkRow: View {
    @Environment(\.palette) var p
    var icon: String
    var name: String
    var indent: Int
    var diagnosis: LinkDiagnosis
    var facts: [String?]

    var color: Color { switch diagnosis.level { case .ok: p.dim; case .note: p.accent; case .slow: p.warn } }
    var badge: String { switch diagnosis.level { case .ok: "checkmark.circle"; case .note: "info.circle"; case .slow: "exclamationmark.triangle.fill" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(p.dim)
                Text(name).foregroundStyle(p.text).lineLimit(1)
                Text(facts.compactMap { $0 }.joined(separator: " · ")).foregroundStyle(p.dim).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: badge).foregroundStyle(diagnosis.level == .ok ? Color.green : color)
                Text(diagnosis.summary).foregroundStyle(diagnosis.level == .ok ? p.dim : p.text).lineLimit(3)
            }.padding(.leading, 26)
            if let a = diagnosis.advice {
                Text(a).foregroundStyle(color).lineLimit(3).padding(.leading, 46)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.leading, CGFloat(indent) * 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AccessoryBatteryPanel: View {
    @Environment(\.palette) var p
    var accessories: [AccessoryBattery]
    var now = Date()

    var body: some View {
        Panel(title: "Accessory batteries", trailing: "last \(AccessoryStore.retentionDays) days") {
            if accessories.isEmpty {
                Text("No accessory reports a battery level. Apple's Magic accessories and AirPods do while connected.")
                    .foregroundStyle(p.dim).font(.system(size: 11))
            }
            ForEach(accessories) { a in AccessoryRow(a: a, now: now) }
            Text("Magic Mouse, Keyboard and Trackpad levels are recorded every 20 minutes while FlightDeck runs; AirPods and other headsets only when this page loads.")
                .foregroundStyle(p.dim).font(.system(size: 10))
        }
    }
}

private struct AccessoryRow: View {
    @Environment(\.palette) var p
    var a: AccessoryBattery
    var now: Date

    var body: some View {
        let low = (a.levels["Main"] ?? 100) < AccessoryForecast.lowThreshold
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: a.connected ? "battery.75percent" : "battery.0percent").frame(width: 18).foregroundStyle(low ? p.warn : p.dim)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).foregroundStyle(a.connected ? p.text : p.dim).lineLimit(1)
                Text(levelsText).foregroundStyle(low ? p.warn : p.dim).lineLimit(1)
            }.frame(width: 240, alignment: .leading)
            BatterySpark(points: AccessoryForecast.sparkValues(a.history), now: now, color: low ? p.warn : p.accent, grid: p.grid)
                .frame(width: 200, height: 30)
            Text(estimateText).foregroundStyle(p.dim).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    var levelsText: String {
        let parts = a.orderedLevels.map { ($0.part == "Main" ? "" : $0.part.lowercased() + " ") + "\($0.pct)%" }
        let when = a.connected ? nil : a.lastSeen.map { "last seen " + $0.formatted(date: .abbreviated, time: .shortened) }
        return ([parts.joined(separator: " · ")] + [when].compactMap { $0 }).joined(separator: " · ")
    }

    var estimateText: String {
        switch a.estimate {
        case .value(let e): return e.text.prefix(1).uppercased() + e.text.dropFirst() + String(format: " (−%.1f%% a day)", e.ratePerDay)
        case .unavailable(let why): return "Time left: unavailable (\(why))"
        }
    }
}

/// Level over the last 30 days on a 0–100% scale, with the 15% low line.
private struct BatterySpark: View {
    var points: [(Date, Double)]
    var now: Date
    var color: Color
    var grid: Color

    var body: some View {
        Canvas { ctx, size in
            let span: TimeInterval = 30 * 86_400, start = now.addingTimeInterval(-span)
            func pt(_ t: Date, _ v: Double) -> CGPoint {
                CGPoint(x: CGFloat(max(0, t.timeIntervalSince(start)) / span) * size.width, y: size.height * (1 - CGFloat(v / 100)))
            }
            var low = Path(); low.move(to: CGPoint(x: 0, y: size.height * 0.85)); low.addLine(to: CGPoint(x: size.width, y: size.height * 0.85))
            ctx.stroke(low, with: .color(grid), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let visible = points.filter { $0.0 >= start }
            guard visible.count >= 2 else {
                if let v = visible.last { ctx.fill(Path(ellipseIn: CGRect(origin: pt(v.0, v.1), size: .zero).insetBy(dx: -2, dy: -2)), with: .color(color)) }
                return
            }
            var line = Path()
            for (i, v) in visible.enumerated() { i == 0 ? line.move(to: pt(v.0, v.1)) : line.addLine(to: pt(v.0, v.1)) }
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
