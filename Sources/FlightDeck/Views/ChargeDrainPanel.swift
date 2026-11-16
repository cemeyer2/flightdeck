// "Where did this charge go?": per-app shares of the energy used since the Mac was last unplugged, from the battery
// session `DailyLog` keeps (FlightDeckCore/ChargeDrain.swift). Shown in Performance › Energy and in Trends.
import SwiftUI
import FlightDeckCore

/// Energy tab panel: polls the (cheap) charge status every 30 s while visible.
struct ChargeDrainPanel: View {
    @EnvironmentObject var e: Engine
    @State private var status: ChargeStatus?
    /// For off-screen rendering, where `.task` doesn't run before capture.
    var preview: ChargeStatus? = nil

    var body: some View {
        DrainPanelContent(status: preview ?? status ?? ChargeStatus(current: nil, last: nil))
            .task { while !Task.isCancelled { status = e.dailyLog.chargeStatus(); try? await Task.sleep(for: .seconds(30)) } }
    }
}

/// The panel for a given status: the open session while on battery, else the last one. Hidden on Macs that have never
/// been seen on battery (desktops).
struct DrainPanelContent: View {
    @Environment(\.palette) var p
    var status: ChargeStatus

    var body: some View {
        if let s = status.current ?? status.last {
            let a = s.attribution()
            Panel(title: status.current != nil ? "This charge" : "Last time on battery", trailing: header(s)) {
                if a.rows.isEmpty {
                    Text("No energy measured per app yet on this charge.").foregroundStyle(p.dim)
                } else {
                    Text("\(lead(s)): \(a.summary)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    let top = max(a.rows.first?.share ?? 1, 0.001)
                    ForEach(a.rows) { r in
                        HStack(spacing: 8) {
                            AppIcon(path: r.icon.hasSuffix(".app") ? r.icon + "/" : r.icon).frame(width: 16, height: 16)
                            Text(r.name).lineLimit(1).frame(width: 200, alignment: .leading)
                            VFDMeter(fraction: r.share / top, segments: 30, height: 6)
                            Text("\(Int((r.share * 100).rounded()))%").frame(width: 44, alignment: .trailing)
                            Text(String(format: "%.2f Wh", r.wattHours)).foregroundStyle(p.dim).frame(width: 80, alignment: .trailing)
                        }.font(.system(size: 12, design: .monospaced))
                    }
                    if let o = a.otherShare, o >= 0.01 {
                        HStack(spacing: 8) {
                            Image(systemName: a.ofSystem ? "display" : "ellipsis.circle").frame(width: 16, height: 16).foregroundStyle(p.dim)
                            Text(a.ofSystem ? "Display, macOS and other apps" : "Other apps").lineLimit(1).frame(width: 200, alignment: .leading).foregroundStyle(p.dim)
                            VFDMeter(fraction: o / top, segments: 30, color: p.dim, height: 6)
                            Text("\(Int((o * 100).rounded()))%").frame(width: 44, alignment: .trailing).foregroundStyle(p.dim)
                            Text("").frame(width: 80)
                        }.font(.system(size: 12, design: .monospaced))
                    }
                    Text(a.ofSystem ? "Shares of the energy the Mac measured on battery (sleep excluded), from each app's billed energy."
                                    : "This Mac doesn't report its total draw, so shares are of the energy billed to apps (the display and macOS aren't included).")
                        .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "since unplugged 2 h 10 min ago" / "since FlightDeck started 40 min ago (already on battery)".
    func lead(_ s: ChargeSession) -> String {
        let ago = shortDuration(Date().timeIntervalSince(s.start))
        if s.end != nil { return "\(shortDuration(s.duration)) on battery" }
        return s.sawUnplug ? "Since unplugged \(ago) ago" : "Since FlightDeck started \(ago) ago (already on battery)"
    }

    func header(_ s: ChargeSession) -> String {
        var parts: [String] = []
        if let u = s.percentUsed { parts.append(String(format: "%.0f%% used", u)) }
        if let wh = s.systemWh { parts.append(String(format: "%.1f Wh", wh)) }
        if let end = s.end { parts.append("ended \(end.formatted(date: .abbreviated, time: .shortened))") }
        return parts.joined(separator: " · ")
    }
}
