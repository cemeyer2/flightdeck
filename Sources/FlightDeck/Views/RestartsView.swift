import SwiftUI
import FlightDeckCore
// Restarts & Crashes destination: every boot with how the session before it ended (clean, unexpected, kernel panic),
// grouped by cause, the panic reports, app freezes, and how long boot and login took. Data from RestartsCollector
// (wtmp, logd's shutdown log, the unified log's shutdown causes, the power log, panic and hang reports); panels are in
// RestartsPanels.swift and BootTimePanels.swift.

struct RestartsView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @StateObject private var model: RestartsModel

    init(model: RestartsModel? = nil) {
        // Demo mode gets invented data; nothing is read from this Mac.
        _model = StateObject(wrappedValue: model ?? (Demo.isEnabled ? RestartsModel(preview: DemoRestarts.report()) : RestartsModel()))
    }

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Why your Mac restarted, froze or shut down, and how long it takes to start.").foregroundStyle(p.dim)
                    if model.loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh") { Task { await model.load(blackBox: e.blackBox) } }.disabled(model.loading || model.fixed)
                }.font(.system(size: 12))
                if let r = model.report { RestartsContent(report: r) }
                else if !model.loading { Text("Not loaded yet.").foregroundStyle(p.dim) }
                else { Text("Reading macOS's boot, shutdown and panic records…").foregroundStyle(p.dim) }
            }.padding(16)
        }
        .task { if model.report == nil { await model.load(blackBox: e.blackBox) } }
    }
}

/// The page's panels for a loaded report (also what UIBench renders).
struct RestartsContent: View {
    @Environment(\.palette) var p
    var report: RestartsReport

    var body: some View {
        let r = report
        VStack(alignment: .leading, spacing: 12) {
            summary(r)
            BootTimelinePanel(events: r.events)
            HStack(alignment: .top, spacing: 12) {
                CauseGroupsPanel(events: r.events).frame(maxWidth: .infinity)
                FreezesPanel(hangs: r.hangs, wakes: r.hibernateWakes).frame(maxWidth: .infinity)
            }
            PanicsPanel(panics: r.panics)
            if let t = r.current { BootPhasesPanel(timing: t) ; LoginItemsPanel(timing: t) }
            BootTrendPanel(events: r.events, history: r.history)
            LimitsPanel(report: r)
        }
    }

    func summary(_ r: RestartsReport) -> some View {
        let last90 = r.events.filter { Date().timeIntervalSince($0.boot) <= 90 * 86_400 }
        let lastBad = r.events.first(where: \.previous.isUnexpected)
        return Panel(title: "Overview", trailing: r.oldestBoot.map { "records since \($0.formatted(date: .abbreviated, time: .omitted))" }) {
            HStack(spacing: 28) {
                Readout(label: "Up since", value: r.events.first.map { $0.boot.formatted(date: .abbreviated, time: .shortened) } ?? "—", size: 16)
                Readout(label: "Boots", value: "\(last90.count)", size: 16)
                Readout(label: "Unexpected", value: "\(last90.filter(\.previous.isUnexpected).count)", color: lastBad == nil ? nil : p.warn, size: 16)
                Readout(label: "Kernel panics", value: "\(r.panics.count)", color: r.panics.isEmpty ? nil : p.crit, size: 16)
                Readout(label: "App freezes (30 d)", value: "\(r.hangs.count)", size: 16)
                Readout(label: "Boot to desktop", value: r.current?.bootToDesktop.map(bootSpan) ?? "—", size: 16)
                Spacer()
            }
            Text(lastBad.map { "Last unexpected: \($0.previous.title) before the boot of \($0.boot.formatted(date: .abbreviated, time: .shortened))." }
                 ?? "No unexpected shutdowns or panics in these records.")
                .font(.system(size: 12)).foregroundStyle(lastBad == nil ? p.dim : p.text)
        }
    }
}

/// "42 s", "2 min 5 s".
func bootSpan(_ s: TimeInterval) -> String {
    s < 90 ? "\(Int(s.rounded())) s" : "\(Int(s) / 60) min \(Int(s) % 60) s"
}

/// Colour for a verdict: neutral when clean, warn when unexpected, crit for panics, dim when unknown.
extension ShutdownVerdict.Kind {
    func color(_ p: Palette) -> Color {
        switch self { case .clean: p.accent; case .unexpected: p.warn; case .panic: p.crit; case .unknown: p.dim }
    }
    var icon: String {
        switch self { case .clean: "checkmark.circle"; case .unexpected: "bolt.trianglebadge.exclamationmark"; case .panic: "exclamationmark.octagon.fill"; case .unknown: "questionmark.circle" }
    }
}

/// Boots on a time axis (markers coloured by how the session before ended), then one row per boot, newest first.
struct BootTimelinePanel: View {
    @Environment(\.palette) var p
    var events: [BootEvent]
    @State private var expanded: Date?

    var body: some View {
        Panel(title: "Boots", trailing: "how the session before each boot ended") {
            strip.frame(height: 30)
            HStack(spacing: 14) {
                ForEach([ShutdownVerdict.Kind.clean, .unexpected, .panic, .unknown], id: \.self) { k in
                    Label(k.rawValue, systemImage: k.icon).foregroundStyle(k.color(p))
                }
            }.font(.system(size: 10, design: .monospaced))
            ForEach(events.prefix(30)) { ev in row(ev) }
            if events.isEmpty { Text("macOS's login records (wtmp) have no boots.").foregroundStyle(p.dim) }
            if events.count > 30 { Text("\(events.count - 30) older boots not shown.").font(.caption).foregroundStyle(p.dim) }
        }
    }

    /// Ticks from the oldest boot to now; unexpected and panic ticks are taller so they stand out.
    var strip: some View {
        Canvas { ctx, size in
            guard let first = events.last?.boot else { return }
            let span = max(Date().timeIntervalSince(first), 1)
            ctx.fill(Path(CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)), with: .color(p.grid))
            for ev in events {
                let x = CGFloat(ev.boot.timeIntervalSince(first) / span) * (size.width - 4) + 2
                let tall = ev.previous.isUnexpected
                let h = tall ? size.height : size.height * 0.5
                ctx.fill(Path(roundedRect: CGRect(x: x - 1.5, y: (size.height - h) / 2, width: 3, height: h), cornerRadius: 1), with: .color(ev.previous.kind.color(p)))
            }
        }
        .help("Each tick is a boot. Tall ticks: the session before it ended unexpectedly or in a kernel panic.")
    }

    func row(_ ev: BootEvent) -> some View {
        let v = ev.previous, open = expanded == ev.boot
        return VStack(alignment: .leading, spacing: 3) {
            Button { expanded = open ? nil : ev.boot } label: {
                HStack(spacing: 10) {
                    Image(systemName: v.kind.icon).foregroundStyle(v.kind.color(p)).frame(width: 14)
                    Text(ev.boot.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())).frame(width: 150, alignment: .leading)
                    Text(v.title).foregroundStyle(v.isUnexpected ? v.kind.color(p) : p.text).lineLimit(1).frame(width: 290, alignment: .leading)
                    Text(ev.previousBoot.map { "after \(uptime(ev.boot.timeIntervalSince($0))) up" } ?? "").foregroundStyle(p.dim).lineLimit(1).frame(width: 170, alignment: .leading)
                    Text(ev.login.map { "login +\(bootSpan($0.timeIntervalSince(ev.boot)))" } ?? "").foregroundStyle(p.dim)
                    Spacer()
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(p.dim)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open || v.isUnexpected {
                Text(v.detail).font(.system(size: 11)).foregroundStyle(p.text).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 24)
            }
            if open {
                Text("Evidence: " + (v.evidence.isEmpty ? "none" : v.evidence.joined(separator: " · ")) + (v.inferred ? " (inferred)" : "")
                     + (v.cause.map { " · cause \($0.code): \($0.certainty.rawValue)" } ?? ""))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).padding(.leading, 24)
            }
        }.font(.system(size: 12, design: .monospaced))
    }

    func uptime(_ s: TimeInterval) -> String {
        s >= 86_400 ? "\(Int(s / 86_400)) d \(Int(s.truncatingRemainder(dividingBy: 86_400) / 3600)) h" : shortDuration(s)
    }
}
