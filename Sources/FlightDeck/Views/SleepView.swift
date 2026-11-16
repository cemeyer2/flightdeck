import SwiftUI
import FlightDeckCore
// Sleep & Wake destination: sleep sessions, dark wakes, wake requesters and sleep-prevention assertions parsed from
// `pmset -g log` by FlightDeckCore/SleepLog.swift. Independent of the black box: the log is macOS's own history,
// so it covers times FlightDeck wasn't running.

/// "Why did my Mac wake at 3 am? Where did my battery go overnight?" From the power management log.
/// Reads the log on a detached utility task when the view appears, when the period changes, and on Refresh;
/// there is no periodic refresh. A nil report (pmset failed or produced nothing parseable) shows a message.
struct SleepView: View {
    @Environment(\.palette) var p
    @State private var report: SleepReport?
    @State private var loading = false
    /// Start time of the session expanded in the list (sessions are identified by their start).
    @State private var selected: Date?
    @AppStorage("sleepDays") private var days = 3

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("", selection: $days) { Text("Last day").tag(1); Text("3 days").tag(3); Text("7 days").tag(7) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh") { Task { await load() } }
                }
                if let r = report {
                    // Sessions are newest first; "Last sleep" prefers the latest one longer than an hour, so a short nap
                    // after a long night doesn't hide the night.
                    if let last = r.sessions.first(where: { $0.duration > 3600 }) ?? r.sessions.first { lastNight(last) }
                    sessions(r)
                    HStack(alignment: .top, spacing: 12) {
                        Panel(title: "What woke it in the dark", trailing: "\(r.events.filter { $0.kind == .darkWake }.count) dark wakes") {
                            ranked(r.darkWakeReasons.map { ($0.reason, Double($0.count), "×\($0.count)") })
                            Text("Dark wakes are brief wakes with the screen off, for network upkeep, Power Nap and Bluetooth devices.")
                                .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                        }
                        Panel(title: "Who scheduled wakes") {
                            ranked(r.wakeRequesters.prefix(8).map { ($0.process, Double($0.count), "×\($0.count)") })
                        }
                    }
                    Panel(title: "Who kept the Mac awake", trailing: "time each app held a sleep-prevention assertion") {
                        ranked(r.keptAwake.prefix(10).map { ($0.process + ($0.reason.isEmpty ? "" : " · “\($0.reason)”"), Double($0.seconds), shortDuration(TimeInterval($0.seconds))) })
                        if r.keptAwake.isEmpty { Text("Nothing held the Mac awake.").foregroundStyle(p.dim) }
                    }
                } else if !loading {
                    Text("The power management log isn't available.").foregroundStyle(p.dim)
                }
            }.padding(16)
        }
        .task(id: days) { await load() }
    }

    /// `SleepLog.read` shells out to pmset (can take seconds on a long log), so it runs off the main actor.
    func load() async {
        loading = true; defer { loading = false }
        let d = Double(days)
        report = await Task.detached(priority: .utility) { SleepLog.read(days: d) }.value
    }

    /// Summary of one session: time asleep, dark wakes (over 30 is flagged), battery used ("on AC" when it charged
    /// or was plugged in; "—" when on battery but the drop couldn't be measured), why it slept and what woke it.
    func lastNight(_ s: SleepSession) -> some View {
        Panel(title: "Last sleep", trailing: "\(s.start.formatted(date: .abbreviated, time: .shortened)) – \(s.end.formatted(date: .omitted, time: .shortened))") {
            HStack(spacing: 28) {
                Readout(label: "Asleep", value: shortDuration(TimeInterval(s.asleepSeconds)))
                Readout(label: "Dark wakes", value: "\(s.darkWakes.count)", color: s.darkWakes.count > 30 ? p.warn : nil)
                Readout(label: "Battery used", value: s.batteryUsed.map { "\($0)" } ?? (s.onBatteryThroughout ? "—" : "on AC"), unit: s.batteryUsed == nil ? "" : "%",
                        color: (s.batteryUsed ?? 0) >= 10 ? p.warn : nil)
                Readout(label: "Went to sleep", value: s.why)
                Readout(label: "Woken by", value: s.wokeBy)
                Spacer()
            }
            strip(s).frame(height: 26)
        }
    }

    /// Asleep (dim bar) with dark wakes as ticks coloured by reason.
    func strip(_ s: SleepSession) -> some View {
        Canvas { ctx, size in
            // Ticks are placed by time within the session; a wake of unknown length is drawn as if 10 s, and every tick is
            // at least 2 pt wide so short wakes stay visible. Colour is chosen from the reason's plain-English explanation.
            let span = max(s.duration, 1)
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: size.height * 0.3, width: size.width, height: size.height * 0.4), cornerRadius: 3), with: .color(p.accent.opacity(0.25)))
            for d in s.darkWakes {
                let x = CGFloat(d.time.timeIntervalSince(s.start) / span) * size.width
                let w = max(CGFloat(Double(d.seconds ?? 10) / span) * size.width, 2)
                ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(d.explanation.contains("maintenance") || d.explanation.contains("services") ? p.accent2 : p.warn))
            }
        }
        .help("Asleep (bar) and dark wakes (ticks): orange-red for network/Bluetooth/notifications, amber for scheduled maintenance")
    }

    /// Up to 20 sessions; clicking one expands its wake strip and its first 40 dark wakes.
    func sessions(_ r: SleepReport) -> some View {
        Panel(title: "Sleep sessions", trailing: "\(r.sessions.count) in this period") {
            ForEach(r.sessions.prefix(20)) { s in
                VStack(alignment: .leading, spacing: 4) {
                    Button { selected = selected == s.start ? nil : s.start } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected == s.start ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(p.dim).frame(width: 10)
                            Text(s.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())).frame(width: 96, alignment: .leading)
                            Text(shortDuration(s.duration)).frame(width: 90, alignment: .leading)
                            Text("\(s.why) → \(s.wokeBy)").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(s.darkWakes.count) dark wakes").foregroundStyle(p.dim).frame(width: 110, alignment: .trailing)
                            Text(s.batteryUsed.map { "−\($0)%" } ?? "AC").foregroundStyle((s.batteryUsed ?? 0) >= 10 ? p.warn : p.dim).frame(width: 44, alignment: .trailing)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if selected == s.start {
                        strip(s).frame(height: 18).padding(.leading, 20)
                        ForEach(s.darkWakes.prefix(40)) { d in
                            HStack(spacing: 10) {
                                Text(d.time.formatted(date: .omitted, time: .standard)).frame(width: 96, alignment: .leading).foregroundStyle(p.dim)
                                Text(d.explanation).frame(width: 300, alignment: .leading)
                                Text(d.seconds.map { "\($0) s awake" } ?? "").foregroundStyle(p.dim)
                                Text(d.reason).foregroundStyle(p.dim).lineLimit(1).help(d.reason)
                            }.font(.system(size: 10, design: .monospaced)).padding(.leading, 20)
                        }
                    }
                }.font(.system(size: 12, design: .monospaced))
            }
            if r.sessions.isEmpty { Text("No sleep in this period.").foregroundStyle(p.dim) }
        }
    }

    /// A ranked list of (label, value, display text) rows with meters relative to the first (largest) row.
    func ranked(_ rows: [(String, Double, String)]) -> some View {
        let top = max(rows.first?.1 ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 8) {
                    Text(r.0).lineLimit(1).frame(width: 300, alignment: .leading).help(r.0)
                    VFDMeter(fraction: r.1 / top, segments: 20, height: 5)
                    Text(r.2).foregroundStyle(p.dim).lineLimit(1).fixedSize().frame(minWidth: 100, alignment: .trailing)
                }.font(.system(size: 11, design: .monospaced))
            }
        }
    }
}

// (SleepPreview is used by UIBench's PNG rendering, where `.task` never runs before the image is captured.)
/// Off-screen review: SleepView loads asynchronously, so render its parts from a synchronous read.
struct SleepPreview: View {
    var body: some View {
        if let r = SleepLog.read(days: 3) { SleepContentPreview(report: r) } else { Text("no log") }
    }
}
/// Renders the SleepView sections for a report that is already loaded, by calling the view's builder methods.
struct SleepContentPreview: View {
    var report: SleepReport
    var body: some View {
        let v = SleepView()
        VStack(alignment: .leading, spacing: 12) {
            if let s = report.sessions.first(where: { $0.duration > 3600 }) { v.lastNight(s) }
            v.sessions(report)
            Panel(title: "What woke it in the dark") { v.ranked(report.darkWakeReasons.map { ($0.reason, Double($0.count), "×\($0.count)") }) }
            Panel(title: "Who kept the Mac awake") { v.ranked(report.keptAwake.prefix(10).map { ($0.process, Double($0.seconds), shortDuration(TimeInterval($0.seconds))) }) }
        }
    }
}
