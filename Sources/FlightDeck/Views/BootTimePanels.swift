import SwiftUI
import FlightDeckCore
// Restarts & Crashes › boot and login time: the current boot's phases, the login items that started during login and
// the busiest processes after it, and the 90-day trend from FlightDeck's saved boot history (BootStore).

/// The current boot as four phases on one bar, each from a launch time (see BootTiming for what each one measures).
struct BootPhasesPanel: View {
    @Environment(\.palette) var p
    var timing: BootTiming

    var phases: [(String, TimeInterval?, Color, String)] {
        [("Kernel → login window", timing.toLoginWindow, p.accent, "macOS starting: kernel, drivers, WindowServer, until loginwindow launched"),
         ("At the login window", timing.atLoginWindow, p.dim, "includes typing your password (or the FileVault unlock and automatic login)"),
         ("Login → desktop", timing.loginToDesktop, p.eCore, "setting up your session until Dock, Finder and the menu bar launched"),
         ("Login items", timing.itemsPhase, p.warn, "from the desktop until the last third-party item started (within 3 min of login)")]
    }

    var body: some View {
        Panel(title: "This boot", trailing: "booted \(timing.boot.formatted(date: .abbreviated, time: .shortened))") {
            HStack(spacing: 28) {
                ForEach(phases, id: \.0) { ph in Readout(label: ph.0, value: ph.1.map(bootSpan) ?? "—", color: ph.1 == nil ? p.dim : nil, size: 16) }
                Readout(label: "Boot → desktop", value: timing.bootToDesktop.map(bootSpan) ?? "—", size: 16)
                Spacer()
            }
            bar.frame(height: 14)
            ForEach(phases, id: \.0) { ph in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(ph.2).frame(width: 10, height: 10)
                    Text("\(ph.0): \(ph.3)").font(.system(size: 10)).foregroundStyle(p.dim)
                }
            }
            if timing.login == nil {
                Text("No console login is recorded for this boot yet, so only the time to the login window is known.").font(.system(size: 11)).foregroundStyle(p.dim)
            }
            Text("Measured from process launch times (to the second): when each step started, not when it finished drawing.")
                .font(.system(size: 10)).foregroundStyle(p.dim)
        }
    }

    /// Phases drawn to scale; unknown phases are left out rather than drawn as zero.
    var bar: some View {
        Canvas { ctx, size in
            let known = phases.compactMap { ph in ph.1.map { (max($0, 0), ph.2) } }
            let total = max(known.reduce(0) { $0 + $1.0 }, 1)
            var x: CGFloat = 0
            for (v, c) in known {
                let w = CGFloat(v / total) * size.width
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: max(w - 1, 1), height: size.height), cornerRadius: 2), with: .color(c))
                x += w
            }
        }
    }
}

/// Third-party items that started during login, and the busiest processes in the first minutes after it.
struct LoginItemsPanel: View {
    @Environment(\.palette) var p
    var timing: BootTiming
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Panel(title: "Started during login", trailing: "\(timing.items.count) items") {
                ForEach(timing.items.prefix(14)) { i in
                    HStack(spacing: 8) {
                        Text(i.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(i.path ?? i.name)
                        Text(i.kind).foregroundStyle(p.dim).lineLimit(1).frame(width: 130, alignment: .leading)
                        Text("+\(bootSpan(i.startedAfterLogin))").foregroundStyle(p.dim).frame(width: 70, alignment: .trailing)
                    }.font(.system(size: 11, design: .monospaced))
                }
                if timing.items.isEmpty {
                    Text(timing.login == nil ? "Not measured: no login recorded." : "No third-party process started in the 3 minutes after login (items that already quit aren't seen).")
                        .font(.system(size: 11)).foregroundStyle(p.dim)
                } else {
                    Text("Third-party processes still running that started within 3 minutes of login. Turn items off in System Settings › General › Login Items & Extensions.")
                        .font(.system(size: 10)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity)
            Panel(title: "Busiest after login", trailing: "CPU time") {
                let top = max(timing.busiest.first?.cpuSeconds ?? 1, 1)
                ForEach(timing.busiest) { i in
                    HStack(spacing: 8) {
                        Text(i.name).lineLimit(1).frame(width: 150, alignment: .leading)
                        VFDMeter(fraction: (i.cpuSeconds ?? 0) / top, segments: 16, height: 5)
                        Text(String(format: "%.0f s", i.cpuSeconds ?? 0)).foregroundStyle(p.dim).frame(width: 60, alignment: .trailing)
                    }.font(.system(size: 11, design: .monospaced))
                }
                Text(timing.busiestSource?.rawValue ?? "Not measured: FlightDeck's black box (24 h) has no samples from the first minutes after this login, and CPU time since start only means \"after login\" within an hour of it.")
                    .font(.system(size: 10)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity)
        }
    }
}

/// One bar per boot over the last 90 days: boot to login for every boot (from wtmp), and boot to desktop for boots
/// FlightDeck measured. Boots without a value are gaps.
struct BootTrendPanel: View {
    @Environment(\.palette) var p
    var events: [BootEvent]
    var history: [BootRecord]
    var body: some View {
        let boots = events.filter { Date().timeIntervalSince($0.boot) <= 90 * 86_400 }.reversed()   // oldest first
        let labels = boots.map { $0.boot.formatted(.dateTime.day().month(.abbreviated).hour().minute()) }
        let toLogin = boots.map { e in e.login.map { $0.timeIntervalSince(e.boot) } }
        let saved = Dictionary(history.map { (Int($0.boot.timeIntervalSince1970 / 60), $0) }, uniquingKeysWith: { a, _ in a })
        let toDone: [Double?] = boots.map { e in
            let t = saved[Int(e.boot.timeIntervalSince1970 / 60)]?.timing
            return t.flatMap { t in (t.itemsDone ?? t.desktop).map { $0.timeIntervalSince(t.boot) } }
        }
        Panel(title: "Boot time trend", trailing: "\(boots.count) boots in 90 days") {
            if boots.count < 2 {
                Text("A trend needs at least two boots in the records.").font(.system(size: 11)).foregroundStyle(p.dim)
            } else {
                Text("Boot → login (all boots, from wtmp)").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                DayChart(values: Array(toLogin), labels: Array(labels), style: .bars, format: bootSpan).frame(height: 90)
                Text("Boot → login items done (boots FlightDeck measured)").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                DayChart(values: toDone, labels: Array(labels), style: .bars, color: p.warn, format: bootSpan).frame(height: 90)
                if toDone.allSatisfy({ $0 == nil }) {
                    Text("FlightDeck measures each boot's login while that boot is running and keeps it for 90 days; this chart fills in as you restart.")
                        .font(.system(size: 10)).foregroundStyle(p.dim)
                }
            }
        }
    }
}
