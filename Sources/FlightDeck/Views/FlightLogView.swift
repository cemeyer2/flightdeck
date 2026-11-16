import SwiftUI
import FlightDeckCore
// Flight Log destination: the black-box timeline, current findings, the persistent incident log (last 7 days)
// and macOS diagnostic reports. Also defines pieces reused elsewhere: `FindingRow` (Summary banner),
// `FindingActions` (context menus), `shortDuration` and the severity colour mapping.

extension Palette {
    /// Severity colour used everywhere a finding or incident is drawn: info = accent, caution = warn, warning = crit.
    func color(_ s: Finding.Severity) -> Color {
        switch s { case .info: accent; case .caution: warn; case .warning: crit }
    }
}

/// Compact human duration for finding/incident ages: "42 s", "17 min", "3 h 5 min" (seconds below a minute only).
func shortDuration(_ s: TimeInterval) -> String {
    let m = Int(s / 60)
    if m < 1 { return "\(Int(s)) s" }
    if m < 60 { return "\(m) min" }
    return "\(m / 60) h \(m % 60) min"
}

/// One finding: severity light, title, how long, explanation; clicking jumps to where to look.
struct FindingRow: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var f: Finding
    var compact = false
    // Clicking navigates via `Engine.navigationRequest` (a Destination raw value, optionally "Performance:<tab>"),
    // which ContentView observes; findings without a destination are inert apart from the context menu.
    var body: some View {
        Button { if let d = f.destination { e.navigationRequest = d } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: f.icon).foregroundStyle(p.color(f.severity)).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(f.title).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(p.text)
                        // Age is measured against the displayed snapshot, so during replay it reads as "how long at that
                        // moment" rather than relative to now. Under 10 s is omitted to avoid flicker on fresh findings.
                        let d = (e.current?.time ?? Date()).timeIntervalSince(f.since)
                        if d >= 10 { Text("· \(shortDuration(d))").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim) }
                    }
                    if !compact, let detail = f.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if f.destination != nil { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(p.dim) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu { FindingActions(f: f) }
    }
}

/// The Flight Log page. Data sources: `e.findings` (live analyzer findings plus diagnostic-report findings, or the
/// findings recomputed for the replayed moment), `e.incidents` (the IncidentLog persisted on disk; anything that
/// lasted ≥ 20 s) and `e.reports` (rescanned by the Engine every 5 minutes). The severity filter persists in defaults.
struct FlightLogView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @State private var confirmClear = false
    @AppStorage("flightLogMinSeverity") private var minSeverity = 1

    var body: some View {
        // Newest first, then bucketed by calendar day; each day becomes its own panel.
        let shown = e.incidents.filter { $0.severity.rawValue >= minSeverity }.reversed()
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.start) }
        // MaybeScroll instead of ScrollView so the page still renders when drawn off-screen (UI benchmark / PNG
        // review), where a ScrollView would come out empty.
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                TimelinePanel()
                Panel(title: "Right now", trailing: e.mode == .replay ? "at the replayed moment" : nil) {
                    if e.findings.isEmpty {
                        Label("All systems normal.", systemImage: "checkmark.seal").foregroundStyle(p.text)
                    }
                    ForEach(e.findings) { FindingRow(f: $0) }
                }
                HStack {
                    Picker("Show", selection: $minSeverity) {
                        Text("Everything").tag(1); Text("Cautions and warnings").tag(2); Text("Warnings only").tag(3)
                    }.frame(width: 300)
                    Spacer()
                    Text("\(e.incidents.count) incident\(e.incidents.count == 1 ? "" : "s") in the last 7 days").font(.caption).foregroundStyle(p.dim)
                    Button("Clear…") { confirmClear = true }.disabled(e.incidents.isEmpty)
                }
                if shown.isEmpty {
                    Text("Nothing logged yet. Anything that lasts 20 seconds or more (a busy app, memory pressure, heat, a filling disk) is logged here, with a replay of what the Mac was doing.")
                        .foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Panel(title: day.formatted(date: .complete, time: .omitted)) {
                        ForEach(days[day]!) { IncidentRow(i: $0) }
                    }
                }
                ReportsPanel()
            }.padding(16)
        }
        .confirmationDialog("Clear the flight log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { e.clearIncidents() }
        }
    }
}

/// One logged incident: start time, severity icon, title, duration (or "ongoing"), detail, and a summary of the
/// call stacks captured as evidence if any. Offers "Stacks" (opens the saved evidence file) and "Replay".
struct IncidentRow: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var i: Incident
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(i.start.formatted(date: .omitted, time: .shortened)).frame(width: 64, alignment: .leading)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(p.dim)
            Image(systemName: i.icon).foregroundStyle(p.color(i.severity)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(i.title).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(p.text)
                Text((i.end == nil ? "ongoing · " : "") + shortDuration(i.duration) + (i.detail.map { " · " + $0 } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(p.dim).lineLimit(2)
                if let ev = i.evidenceSummary {
                    Label(ev, systemImage: "list.bullet.indent").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(p.accent).lineLimit(2).help(ev)
                }
            }
            Spacer()
            // Evidence files are pruned on a schedule, so only offer the button while the file still exists.
            if let path = i.evidencePath, FileManager.default.fileExists(atPath: path) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Label("Stacks", systemImage: "list.bullet.indent") }
                    .help("Call stacks captured automatically while this was happening")
            }
            // The black box keeps at most 24 hours (fine tier for 1 h, coarse 10 s tier beyond), so older incidents
            // can't be replayed; Engine.replayBlackBox adds 2 minutes of context either side.
            if Date().timeIntervalSince(i.end ?? Date()) < 86_400 {
                Button { e.replayBlackBox(from: i.start, to: i.end ?? Date()) } label: { Label("Replay", systemImage: "film") }
                    .help("Replay what the Mac was doing (from the black box)").disabled(!e.blackBoxEnabled)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The black box at a glance: CPU, memory pressure and temperature across the last hours, with incidents.
/// Click anywhere to replay that moment.
struct TimelinePanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @AppStorage("timelineHours") private var hours = 24
    /// One bucket per horizontal slot (`n` = 240); gap buckets (no samples) are drawn hatched, never as zero.
    @State private var buckets: [TimelineBucket] = []
    /// The window the buckets cover; updated together with `buckets` after each load.
    @State private var range: (Date, Date) = (Date(), Date())
    /// Index of the bucket under the pointer, shared by all strips so they highlight the same column.
    @State private var hover: Int?
    let n = 240

    var body: some View {
        Panel(title: "Timeline", trailing: hover.flatMap { i in i < buckets.count ? describe(buckets[i]) : nil } ?? "click to replay that moment") {
            Picker("", selection: $hours) { Text("1 h").tag(1); Text("6 h").tag(6); Text("24 h").tag(24) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            if !e.blackBoxEnabled {
                Text("Turn on the black box (Settings) to build a timeline.").foregroundStyle(p.dim)
            } else {
                VStack(spacing: 3) {
                    strip("CPU", top: 100) { $0.cpuMax }
                    strip("MEM PRESSURE", top: 100) { $0.pressure }
                    strip("HOTTEST °C", top: 110) { $0.hottest }
                    incidentsStrip
                }
                HStack {
                    Text(range.0.formatted(date: .omitted, time: .shortened)); Spacer()
                    Text("hatched = no data (asleep, not running or paused)"); Spacer()
                    Text("now")
                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim)
            }
        }
        // Reloads every 60 s, and restarts immediately when the hour range changes (task id). The task is
        // cancelled when the view disappears, so a hidden Flight Log costs nothing.
        .task(id: hours) {
            while !Task.isCancelled { await load(); try? await Task.sleep(for: .seconds(60)) }
        }
    }

    /// Hover readout shown in the panel's trailing title; "—" for a metric the bucket never measured.
    func describe(_ b: TimelineBucket) -> String {
        b.isGap ? "\(b.start.formatted(date: .omitted, time: .shortened)) · no data"
            : "\(b.start.formatted(date: .omitted, time: .shortened)) · CPU peak \(b.cpuMax.map { String(format: "%.0f%%", $0) } ?? "—") · pressure \(b.pressure.map { String(format: "%.0f%%", $0) } ?? "—") · \(b.hottest.map { String(format: "%.0f °C", $0) } ?? "—")"
    }

    /// Reads the black box and folds it into buckets on a detached utility task, keeping disk reads and decoding
    /// off the main actor. The 1 h view uses the fine (every-sample) tier; 6 h and 24 h use the coarse 10 s tier,
    /// since the fine tier only holds the last hour.
    func load() async {
        let box = e.blackBox, h = hours, n = n
        let to = Date(), from = to.addingTimeInterval(-Double(h) * 3600)
        let b = await Task.detached(priority: .utility) { () -> [TimelineBucket] in
            let t = box.trace(h <= 1 ? .fine : .coarse, from: from, to: to)
            return Timeline.build(t?.frames ?? [], from: from, to: to, buckets: n)
        }.value
        buckets = b; range = (from, to)
    }

    /// Maps a date into the strip's x coordinate for width `w` (used by the incidents strip).
    func x(_ d: Date, _ w: CGFloat) -> CGFloat {
        CGFloat(d.timeIntervalSince(range.0) / max(range.1.timeIntervalSince(range.0), 1)) * w
    }

    /// One metric strip drawn with Canvas (a single draw call for 240 bars, cheaper than 240 SwiftUI views
    /// re-laid-out each second). Bars are coloured by level and clipped at `top`; nil values draw nothing.
    func strip(_ label: String, top: Double, _ v: @escaping (TimelineBucket) -> Double?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(p.dim).frame(width: 74, alignment: .leading)
            GeometryReader { g in
                Canvas { ctx, size in
                    let bw = size.width / CGFloat(max(buckets.count, 1))
                    for b in buckets {
                        let rx = CGFloat(b.index) * bw
                        if b.isGap {
                            var hatch = Path()
                            stride(from: rx, to: rx + bw, by: 3).forEach { hx in hatch.move(to: CGPoint(x: hx, y: size.height)); hatch.addLine(to: CGPoint(x: hx + 2, y: 0)) }
                            ctx.stroke(hatch, with: .color(p.meterOff), lineWidth: 0.6)
                        } else if let val = v(b) {
                            let f = min(val / top, 1)
                            let h = CGFloat(f) * size.height
                            ctx.fill(Path(CGRect(x: rx, y: size.height - h, width: max(bw - 0.5, 0.5), height: h)), with: .color(p.level(f)))
                        }
                    }
                    if let hover {
                        ctx.fill(Path(CGRect(x: CGFloat(hover) * bw, y: 0, width: max(bw, 1), height: size.height)), with: .color(p.text.opacity(0.25)))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let pt) = phase, !buckets.isEmpty { hover = min(Int(pt.x / g.size.width * CGFloat(buckets.count)), buckets.count - 1) } else { hover = nil }
                }
                // A click replays exactly that bucket's time span from the black box; gap buckets have nothing to replay.
                .onTapGesture(coordinateSpace: .local) { pt in
                    guard !buckets.isEmpty else { return }
                    let i = min(Int(pt.x / g.size.width * CGFloat(buckets.count)), buckets.count - 1)
                    guard !buckets[i].isGap else { return }
                    e.replayBlackBox(from: buckets[i].start, to: buckets[i].start.addingTimeInterval(range.1.timeIntervalSince(range.0) / Double(buckets.count)))
                }
            }.frame(height: 22)
        }
    }

    /// Incident bars positioned on the same time axis as the strips (at least 3 pt wide so short ones stay
    /// clickable); ongoing incidents extend to now. Clicking one replays it.
    var incidentsStrip: some View {
        HStack(spacing: 6) {
            Text("INCIDENTS").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(p.dim).frame(width: 74, alignment: .leading)
            GeometryReader { g in
                let shown = e.incidents.filter { ($0.end ?? Date()) >= range.0 }
                ZStack(alignment: .leading) {
                    ForEach(shown) { i in
                        let x0 = max(x(i.start, g.size.width), 0), x1 = min(x(i.end ?? Date(), g.size.width), g.size.width)
                        RoundedRectangle(cornerRadius: 1.5).fill(p.color(i.severity))
                            .frame(width: max(x1 - x0, 3), height: 8).offset(x: x0)
                            .help("\(i.start.formatted(date: .omitted, time: .shortened)) · \(i.title) · \(shortDuration(i.duration))")
                            .onTapGesture { e.replayBlackBox(from: i.start, to: i.end ?? Date()) }
                    }
                }.frame(maxHeight: .infinity)
            }.frame(height: 12)
        }
    }
}

/// Responses to a finding: inspect the responsible process, quit its app, or mute its alerts.
struct FindingActions: View {
    @EnvironmentObject var e: Engine
    var f: Finding
    /// The process behind the finding, looked up in the live snapshot (not the replayed one) so the actions always
    /// target something running now; nil if the finding names no PID or that process has exited.
    var top: ProcessSample? { f.pids?.first.flatMap { pid in e.liveSnapshot?.processes.first { $0.pid == pid } } }
    /// The running app whose bundle contains that process (helpers resolve to their app), matched by bundle path.
    var app: NSRunningApplication? {
        guard let p = top, let b = AppUsage.bundle(of: p.path) else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path }
    }
    var body: some View {
        if let p = top {
            // Passes the full identity (PID + start time) so the inspector never opens a recycled PID.
            Button("Inspect \(p.name) (\(p.pid))") { AppActions.openInspector?(p.identity) }
        }
        if let a = app {
            Button("Quit \(a.localizedName ?? "App")") { a.terminate() }
            Button("Force Quit \(a.localizedName ?? "App")") { a.forceTerminate() }
        }
        if let d = f.destination { Button("Show in \(d.replacingOccurrences(of: ":", with: " › "))") { e.navigationRequest = d } }
        Divider()
        // Muting is keyed by finding id and only suppresses notifications; the finding still shows in the UI.
        if Alerts.shared.muted.contains(f.id) {
            Button("Unmute Alerts for This") { Alerts.shared.muted.remove(f.id) }
        } else {
            Button("Mute Alerts for This") { Alerts.shared.muted.insert(f.id) }
        }
        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.title + (f.detail.map { "\n" + $0 } ?? ""), forType: .string) }
    }
}

/// Crashes, hangs, memory kills and resource-limit reports macOS wrote in the last 7 days.
/// Diagnostic reports come from `e.reports` (DiagnosticReports.scan over the system/user DiagnosticReports folders,
/// headers only). Shows per-kind counts, then the newest 8 unless "Show all"; user faults are hidden by default.
struct ReportsPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @AppStorage("reportsShowAll") private var showAll = false
    @AppStorage("reportsIncludeFaults") private var includeFaults = false

    var body: some View {
        let rs = e.reports.filter { includeFaults || $0.kind != .userFault }
        let shown = showAll ? rs : Array(rs.prefix(8))
        Panel(title: "macOS reports", trailing: "\(rs.count) in the last 7 days") {
            HStack(spacing: 16) {
                ForEach([DiagnosticReport.Kind.crash, .hang, .jetsam, .cpuLimit, .diskWrites], id: \.self) { k in
                    let n = rs.filter { $0.kind == k }.count
                    Label("\(n) \(k.rawValue.lowercased())", systemImage: k.icon).foregroundStyle(n > 0 && k.severity >= .caution ? p.warn : p.dim)
                }
                Spacer()
                Toggle("Non-fatal faults", isOn: $includeFaults).toggleStyle(.switch).controlSize(.small)
            }.font(.system(size: 11, design: .monospaced))
            if rs.isEmpty { Text("No crashes, hangs or resource-limit reports this week.").foregroundStyle(p.dim) }
            ForEach(shown) { r in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(r.time.formatted(.dateTime.weekday(.abbreviated).hour().minute())).frame(width: 90, alignment: .leading)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                    Image(systemName: r.kind.icon).foregroundStyle(r.kind.severity >= .caution ? p.warn : p.dim).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(r.process) · \(r.kind.rawValue)").font(.system(size: 12, weight: .medium, design: .monospaced))
                        if let s = r.summary { Text(s).font(.system(size: 10)).foregroundStyle(p.dim).lineLimit(2) }
                    }
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: r.path)) }.help("Open the full report (Console)")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                }.buttonStyle(.borderless)
            }
            if rs.count > 8 { Toggle("Show all \(rs.count)", isOn: $showAll).toggleStyle(.switch).controlSize(.small) }
            Text("Written by macOS when an app crashes or hangs, when it kills processes to free memory, or when a process exceeds CPU or disk-write limits. FlightDeck only reads their headers.")
                .font(.caption).foregroundStyle(p.dim)
        }
    }
}
