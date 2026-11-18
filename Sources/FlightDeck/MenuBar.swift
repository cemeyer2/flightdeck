// The menu bar extra: the label drawn in the menu bar (MenuBarLabel) and its drop-down panel (MenuBarPanel), plus the
// AppActions hooks that let AppKit-level code (AppDelegate, notifications, menus) open SwiftUI windows, and the login
// item toggle. Both views read `liveSnapshot`/`liveFindings`, so they keep showing live data during replay.
import SwiftUI
import AppKit
import ServiceManagement
import FlightDeckCore

/// What the menu bar label shows; the raw value is stored in the "menuBarStyle" user default and shown in Settings.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case gauges = "Gauges", cpuText = "CPU %", light = "Caution light only"
    var id: String { rawValue }
}

/// Global hooks for things AppKit callbacks need but only SwiftUI views can do.
/// `openMain`/`openInspector` capture a view's `openWindow` action; they are set when MenuBarLabel or ContentView appears.
@MainActor enum AppActions {
    static var openMain: (() -> Void)?
    static var openInspector: ((ProcessIdentity) -> Void)?
    /// Brings the main window forward (opening it if it was closed), then optionally navigates. Navigation is delayed
    /// 0.3 s so a newly opened window's ContentView exists to observe `navigationRequest`.
    static func showMain(navigate: String? = nil, engine: Engine? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI gives a `Window(id: "main")` an NSWindow identifier starting with "main".
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else { openMain?() }
        if let navigate { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { engine?.navigationRequest = navigate } }
    }
}

/// Menu bar label: a tiny instrument strip (CPU and memory bars, master caution light), drawn as an image.
/// Because the menu bar label is always on screen, this view is re-evaluated on each `liveSnapshot` publish; Engine
/// throttles those to every 5 s while no window is visible.
struct MenuBarLabel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarStyle") private var style: MenuBarStyle = .gauges

    var body: some View {
        let s = e.liveSnapshot
        let worst = e.unmutedLiveFindings.map(\.severity).max() ?? .info
        let caution = worst >= .caution
        Group {
            switch style {
            case .cpuText:
                Text(s?.cpu.total.value.map { String(format: "%@%.0f%%", caution ? "⚠︎ " : "", $0) } ?? "—").monospacedDigit()
            case .gauges, .light:
                Image(nsImage: Self.render(cpu: s?.cpu.total.value.map { $0 / 100 },
                                           mem: s.map { Double($0.memory.used) / Double(max($0.memory.total, 1)) },
                                           severity: caution ? worst : nil, lightOnly: style == .light))
            }
        }
            // The label exists for the app's whole lifetime (when the menu bar item is enabled), which makes it a
            // reliable place to install the global hooks.
        .onAppear {
            AppActions.openMain = { openWindow(id: "main") }
            Alerts.shared.onOpen = { [e] d in AppActions.showMain(navigate: d, engine: e) }
        }
    }

    /// Draws the 16 pt-high strip with AppKit: a caution light (orange = caution, red = warning, hollow outline when
    /// nothing is at caution or above) and, unless `lightOnly`, CPU and memory bars as 0…1 fractions. A nil value draws
    /// only the empty track (unavailable, not zero). Not a template image, so the light keeps its colour.
    static func render(cpu: Double?, mem: Double?, severity: Finding.Severity?, lightOnly: Bool) -> NSImage {
        let h: CGFloat = 16, barW: CGFloat = 5, gap: CGFloat = 2
        let w: CGFloat = lightOnly ? 12 : 12 + gap + barW * 2 + gap
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let fg = NSColor.labelColor
            // caution light: hollow when all is well
            let light = NSRect(x: 1, y: 3, width: 10, height: 10)
            let path = NSBezierPath(roundedRect: light, xRadius: 2.5, yRadius: 2.5)
            if let sev = severity {
                (sev == .warning ? NSColor.systemRed : NSColor.systemOrange).setFill(); path.fill()
            } else {
                fg.withAlphaComponent(0.85).setStroke(); path.lineWidth = 1.2; path.stroke()
            }
            guard !lightOnly else { return true }
            for (i, v) in [cpu, mem].enumerated() {
                let x = 12 + gap + CGFloat(i) * (barW + gap)
                let frame = NSRect(x: x, y: 1, width: barW, height: h - 2)
                fg.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: frame, xRadius: 1, yRadius: 1).fill()
                if let v {
                    let fill = NSRect(x: x, y: 1, width: barW, height: max((h - 2) * min(max(v, 0), 1), 1))
                    (v > 0.9 ? NSColor.systemRed : fg).setFill(); NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// The drop-down: master caution, a gauge row, findings, top processes and quick actions.
/// Uses live data only (not the replayed moment), like the label.
struct MenuBarPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = e.liveSnapshot
        let f = e.unmutedLiveFindings
        let worst = f.map(\.severity).max()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(worst.map { $0 >= .caution ? p.color($0) : p.accent } ?? p.accent)
                    .frame(width: 26, height: 12)
                    .shadow(color: (worst.map(p.color) ?? p.accent).opacity(0.8), radius: 4)
                Text(worst.map { $0 >= .warning ? "WARNING" : $0 >= .caution ? "MASTER CAUTION" : "ADVISORY" } ?? "ALL SYSTEMS NORMAL")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Spacer()
                if e.recording { Label("REC", systemImage: "record.circle.fill").foregroundStyle(.red).font(.caption.bold()) }
            }
            HStack(spacing: 14) {
                MiniGauge(label: "CPU", value: s?.cpu.total.value.map { $0 / 100 }, text: s?.cpu.total.value.map { String(format: "%.0f%%", $0) })
                MiniGauge(label: "MEM", value: s.flatMap { $0.memory.isMeasured ? Double($0.memory.used) / Double(max($0.memory.total, 1)) : nil },
                          text: s.flatMap { $0.memory.isMeasured ? Fmt.bytes($0.memory.used) : nil })
                // Gauge scales: temperature against 110 °C, power against 60 W (both are just display ranges).
                MiniGauge(label: "TEMP", value: s?.power.hottest.value.map { $0 / 110 }, text: s?.power.hottest.value.map { Fmt.tempNumber($0) + "°" })
                MiniGauge(label: "POWER", value: s?.power.systemWatts.value.map { min($0 / 60, 1) }, text: s?.power.systemWatts.value.map { String(format: "%.1fW", $0) })
            }
            HStack(spacing: 14) {
                Text("DISK " + (s.flatMap { d in d.disk.readBps.value.flatMap { r in d.disk.writeBps.value.map { Fmt.rate(r + $0) } } } ?? "—"))
                Text("NET " + (s.flatMap { d in d.network.inBps.value.flatMap { i in d.network.outBps.value.map { Fmt.rate(i + $0) } } } ?? "—"))
                if let b = s?.power.battery { Text(String(format: "BAT %.0f%%", b.percent)) }
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
            Divider()
            if f.isEmpty {
                Text("Nothing is holding this Mac back.").font(.system(size: 12)).foregroundStyle(p.dim)
            }
            ForEach(f.prefix(4)) { finding in
                Button { dismiss(); AppActions.showMain(navigate: finding.destination, engine: e) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: finding.icon).foregroundStyle(p.color(finding.severity)).frame(width: 16)
                        Text(finding.title).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Divider()
            Text("TOP PROCESSES").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
                // Top apps (processes grouped by app bundle), by CPU in % of one core.
            ForEach(AppUsage.aggregate(s?.processes ?? []).sorted { $0.cpu > $1.cpu }.prefix(5)) { a in
                HStack {
                    // AppIcon looks for ".app/" in the path, so a bare bundle path needs the trailing slash to get its icon.
                    AppIcon(path: a.iconPath.hasSuffix(".app") ? a.iconPath + "/" : a.iconPath).frame(width: 14, height: 14)
                    Text(a.name).lineLimit(1)
                    Spacer()
                    Text(Fmt.bytes(a.memory)).foregroundStyle(p.dim)
                    Text(String(format: "%.0f%%", a.cpu)).frame(width: 44, alignment: .trailing)
                }.font(.system(size: 11, design: .monospaced))
            }
            Divider()
            HStack {
                Button("Open FlightDeck") { dismiss(); AppActions.showMain() }
                Button("Replay 10 min") { dismiss(); AppActions.showMain(); e.replayBlackBox(minutes: 10) }.disabled(!e.blackBoxEnabled)
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit FlightDeck")
            }.controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }
}

/// A labelled value with a short 10-segment meter; "—" and a dark meter when unavailable.
struct MiniGauge: View {
    @Environment(\.palette) var p
    var label: String
    var value: Double?
    var text: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
            Text(text ?? "—").font(.system(size: 13, weight: .semibold, design: .monospaced)).monospacedDigit()
            VFDMeter(fraction: value, segments: 10, height: 5)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Open at login" via SMAppService (macOS 13+). Registration can fail (e.g. when not running from an app bundle);
/// callers show the error.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
}
