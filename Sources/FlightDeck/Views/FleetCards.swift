// Fleet page pieces: a card per Mac (paired or nearby), the line sparkline they use, and small formatting helpers.
import SwiftUI
import FlightDeckCore

extension FleetIdentity {
    static func icon(_ kind: String?) -> String {
        switch kind {
        case "laptop": "laptopcomputer"
        case "mini": "macmini"
        case "studio": "macstudio"
        case "pro": "macpro.gen3"
        case "imac": "desktopcomputer"
        default: "desktopcomputer"
        }
    }
}

enum FleetFormat {
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 * 2 { return "\(Int(s / 3600)) h \(Int(s.truncatingRemainder(dividingBy: 3600) / 60)) min ago" }
        return "\(Int(s / 86_400)) days ago"
    }
    static func uptime(_ s: Double) -> String {
        let d = Int(s) / 86_400, h = Int(s) % 86_400 / 3600, m = Int(s) % 3600 / 60
        return d > 0 ? "\(d) d \(h) h" : (h > 0 ? "\(h) h \(m) min" : "\(m) min")
    }
    static let thermal = ["Nominal", "Fair", "Serious", "Critical"]
    static func severityColor(_ sev: Int, _ p: Palette) -> Color { sev >= 3 ? p.crit : (sev == 2 ? p.warn : p.dim) }
}

/// A small line sparkline over 0…`ceiling` (or the series' own range). Missing points break the line.
struct FleetSparkline: View {
    var values: [Double?]
    var color: Color
    var ceiling: Double? = 100
    var body: some View {
        Canvas { ctx, size in
            let known = values.compactMap { $0 }
            guard values.count > 1, let lo0 = known.min(), let hi0 = known.max() else { return }
            let lo = ceiling == nil ? lo0 - 1 : 0, hi = max(ceiling ?? hi0 + 1, hi0, lo + 1)
            var path = Path(), started = false
            for (i, v) in values.enumerated() {
                guard let v else { started = false; continue }
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                                 y: size.height * (1 - CGFloat((v - lo) / (hi - lo))))
                if started { path.addLine(to: pt) } else { path.move(to: pt); started = true }
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }
}

/// A labelled sparkline with its latest value.
struct FleetSparkRow: View {
    @Environment(\.palette) var p
    var label: String
    var values: [Double?]
    var latest: String?
    var color: Color
    var ceiling: Double? = 100
    var height: CGFloat = 18
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(p.dim).frame(width: 44, alignment: .leading)
            FleetSparkline(values: values, color: color, ceiling: ceiling).frame(height: height)
            Text(latest ?? "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(latest == nil ? p.dim : p.text)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// A paired Mac: name, model icon, online state, sparklines and its worst finding.
struct FleetHostCard: View {
    @Environment(\.palette) var p
    var host: FleetHostState
    var selected: Bool

    var body: some View {
        let s = host.status
        let v = host.online == true ? s?.vitals : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: FleetIdentity.icon(s?.identity.kind ?? host.peer.kind)).font(.system(size: 26)).foregroundStyle(p.accent).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(p.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                onlineBadge
            }
            if let s, host.online == true {
                let h = s.history
                FleetSparkRow(label: "CPU", values: h.map(\.cpu), latest: v?.cpu.value.map { "\(Int($0.rounded()))%" }, color: p.accent)
                FleetSparkRow(label: "MEM", values: h.map(\.memoryPressure), latest: v?.memoryPressure.value.map { "\(Int($0.rounded()))%" },
                              color: (v?.memoryLevel ?? 1) >= 4 ? p.crit : ((v?.memoryLevel ?? 1) >= 2 ? p.warn : p.accent2))
                FleetSparkRow(label: "TEMP", values: h.map(\.hottest), latest: v?.hottest.value.map { Fmt.temp($0) }, color: p.warn, ceiling: nil)
            } else {
                Text(host.online == nil ? "Checking…" : (host.lastError ?? "Not reachable"))
                    .font(.system(size: 11)).foregroundStyle(p.dim).lineLimit(2).frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            }
            Divider()
            worstLine
        }
        .padding(12)
        .background(PanelSurface())
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? p.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }

    var subtitle: String {
        let model = host.status?.identity.model ?? host.peer.model ?? ""
        let os = host.status.map { "macOS \($0.identity.macOS)" }
        return [model.isEmpty ? nil : model, os].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder var onlineBadge: some View {
        switch host.online {
        case true?: badge("ONLINE", p.accent)
        case false?: VStack(alignment: .trailing, spacing: 1) {
            badge("OFFLINE", p.dim)
            if let seen = host.peer.lastSeen { Text("seen \(FleetFormat.ago(seen))").font(.system(size: 9)).foregroundStyle(p.dim) }
        }
        case nil: ProgressView().controlSize(.small)
        }
    }

    func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().strokeBorder(c.opacity(0.6)))
    }

    @ViewBuilder var worstLine: some View {
        if host.online == true, let w = host.status?.worst {
            Label(w.title, systemImage: w.icon).font(.system(size: 11)).foregroundStyle(FleetFormat.severityColor(w.severity, p)).lineLimit(1)
        } else if host.online == true {
            Label("No problems", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(p.dim)
        } else {
            Label("Status unknown while offline", systemImage: "questionmark.circle").font(.system(size: 11)).foregroundStyle(p.dim)
        }
    }
}

/// A Mac advertising FlightDeck that this one hasn't paired with.
struct FleetNearbyCard: View {
    @Environment(\.palette) var p
    var advert: FleetAdvert
    var pair: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").font(.system(size: 26)).foregroundStyle(p.dim).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(advert.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("FlightDeck on \(advert.name) — pair to view").font(.system(size: 11)).foregroundStyle(p.dim).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            Text("On that Mac, open FlightDeck Settings › Network › Fleet and click Pair a Mac to get a code.")
                .font(.system(size: 11)).foregroundStyle(p.dim).lineLimit(3).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            Divider()
            Button("Pair…", action: pair)
        }
        .padding(12)
        .background(PanelSurface())
    }
}
