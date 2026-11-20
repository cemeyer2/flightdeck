import SwiftUI
import FlightDeckCore
// This session's display connects, disconnects and mode changes as a small timeline (one lane per display) and a
// list, newest first; and what the page's sources can't tell.

struct DisplayHistoryPanel: View {
    @Environment(\.palette) var p
    var events: [DisplayEvent]
    var now: Date

    var body: some View {
        let lanes = laneNames
        Panel(title: "This session", trailing: events.isEmpty ? nil : "since \(events[0].time.formatted(date: .omitted, time: .shortened))") {
            if events.isEmpty {
                Text("No display changes recorded yet. FlightDeck records connects, disconnects and mode changes from launch.")
                    .font(.system(size: 11)).foregroundStyle(p.dim)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lanes, id: \.self) { n in Text(n).lineLimit(1).frame(height: 18, alignment: .leading) }
                    }.font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).frame(width: 200, alignment: .leading)
                    strip(lanes).frame(height: CGFloat(lanes.count) * 18)
                }
                HStack(spacing: 14) {
                    ForEach([DisplayEvent.Kind.connected, .disconnected, .modeChanged, .baseline], id: \.self) { k in
                        Label(legend(k), systemImage: "circle.fill").foregroundStyle(color(k))
                    }
                }.font(.system(size: 10, design: .monospaced))
                ForEach(events.reversed().prefix(20)) { e in row(e) }
                if events.count > 20 { Text("\(events.count - 20) older changes not shown.").font(.caption).foregroundStyle(p.dim) }
            }
        }
    }

    /// Display names in order of first appearance.
    var laneNames: [String] {
        var seen: [String] = []
        for e in events where !seen.contains(e.name) { seen.append(e.name) }
        return seen
    }

    func strip(_ lanes: [String]) -> some View {
        Canvas { ctx, size in
            guard let first = events.first?.time else { return }
            let span = max(now.timeIntervalSince(first), 60)
            for (i, _) in lanes.enumerated() {
                let y = CGFloat(i) * 18 + 9
                ctx.fill(Path(CGRect(x: 0, y: y - 0.5, width: size.width, height: 1)), with: .color(p.grid))
            }
            for e in events {
                guard let lane = lanes.firstIndex(of: e.name) else { continue }
                let x = CGFloat(e.time.timeIntervalSince(first) / span) * (size.width - 8) + 4
                let y = CGFloat(lane) * 18 + 9
                ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(color(e.kind)))
            }
        }
    }

    func row(_ e: DisplayEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color(e.kind)).frame(width: 7, height: 7)
            Text(e.time.formatted(date: .omitted, time: .standard)).frame(width: 90, alignment: .leading).foregroundStyle(p.dim)
            Text(e.title).frame(width: 150, alignment: .leading)
            Text(e.name).frame(width: 220, alignment: .leading).lineLimit(1)
            Text(e.detail).foregroundStyle(p.dim).lineLimit(1)
            Spacer(minLength: 0)
        }.font(.system(size: 11, design: .monospaced))
    }

    func color(_ k: DisplayEvent.Kind) -> Color {
        switch k {
        case .connected, .enabled: p.accent
        case .disconnected, .disabled: p.crit
        case .modeChanged, .mainChanged, .mirroring: p.warn
        case .baseline: p.dim
        }
    }
    func legend(_ k: DisplayEvent.Kind) -> String {
        switch k { case .connected: "connected"; case .disconnected: "disconnected"; case .modeChanged: "mode / main / mirroring"; default: "at launch" }
    }
}

struct DisplayLimitsPanel: View {
    @Environment(\.palette) var p
    var limits: [String]
    var body: some View {
        Panel(title: "What this page can't tell") {
            ForEach(limits, id: \.self) { l in
                Text("• " + l).font(.system(size: 11)).foregroundStyle(p.dim)
            }
        }
    }
}
