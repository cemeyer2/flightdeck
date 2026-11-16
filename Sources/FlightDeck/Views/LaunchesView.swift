// "Launches" destination: processes that started and exited, as seen by diffing consecutive samples (Engine's
// LaunchLog). The top section groups the last 10 minutes by executable so respawn loops stand out; below is the event
// list, newest first, filterable. It shows only what sampling saw: anything that lived less than one sample interval
// never appears, and the log covers this run of FlightDeck only (it isn't part of recordings).
import SwiftUI
import FlightDeckCore

struct LaunchesView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @State private var filter = ""
    @AppStorage("launchesKind") private var kind = "all"   // all | launch | exit
    @AppStorage("launchesMine") private var mineOnly = false

    /// Text filter over name, path, user, PID and parent.
    func matches(_ ev: LaunchEvent) -> Bool {
        if mineOnly && ev.uid != getuid() { return false }
        if kind == "launch" && ev.kind != .launch || kind == "exit" && ev.kind != .exit { return false }
        guard !filter.isEmpty else { return true }
        return [ev.name, ev.path, ev.user, "\(ev.identity.pid)", ev.parentName ?? ""].contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        // Read on every sample (Engine publishes each second anyway); filtering ≤ 2,000 events is cheap.
        let all = e.launchLog.events
        let shown = all.filter(matches)
        let now = Date()
        let tenMin = shown.filter { now.timeIntervalSince($0.time) <= 600 }
        let groups = LaunchLog.groups(tenMin).filter { $0.launches > 0 }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Filter: name, path, user, PID or parent", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                Picker("", selection: $kind) { Text("All").tag("all"); Text("Launches").tag("launch"); Text("Exits").tag("exit") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Toggle("My processes", isOn: $mineOnly).toggleStyle(.switch)
                Spacer()
                Text("\(all.count) events kept (last \(e.launchLog.capacity))").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
            }.padding(10)
            MaybeScroll {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Launches and exits that sampling saw, every \(String(format: "%g", e.interval)) s (\(String(format: "%g", max(e.backgroundInterval, e.interval))) s with no window open). A process that lives less than one sample interval is missed, so counts are lower bounds. Covers this run of FlightDeck only.\(e.mode == .replay ? " Shows live data, not the replayed recording." : "")")
                        .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                    groupsPanel(groups)
                    eventsPanel(shown)
                }.padding(14)
            }
        }
    }

    /// "Launched N times in the last 10 min", most launches first. The bar is scaled to the respawn limit for 5 minutes,
    /// so a full bar means "would raise a respawn finding".
    @ViewBuilder func groupsPanel(_ groups: [LaunchGroup]) -> some View {
        Panel(title: "Launched in the last 10 minutes", trailing: groups.isEmpty ? nil : "\(groups.count) programs") {
            if groups.isEmpty {
                Text("Nothing launched in the last 10 minutes (that sampling saw).").foregroundStyle(p.dim)
            }
            ForEach(groups.prefix(15)) { g in
                let limit = Double(e.launchLog.respawnLimit)
                HStack(spacing: 10) {
                    AppIcon(path: g.path).frame(width: 16, height: 16)
                    Text(g.name).lineLimit(1).frame(width: 200, alignment: .leading)
                    BarCell(text: "launched \(g.launches)×", fraction: Double(g.launches) / limit).frame(width: 160, height: 16)
                    Text("\(g.exits) exited").foregroundStyle(p.dim).frame(width: 80, alignment: .leading)
                    Text(g.lastLaunch.map { "last \($0.formatted(date: .omitted, time: .standard))" } ?? "").foregroundStyle(p.dim)
                    Text(g.users.joined(separator: ", ")).foregroundStyle(p.dim).lineLimit(1)
                    Spacer()
                    Text(g.path.isEmpty ? "path unavailable" : g.path).foregroundStyle(p.dim).lineLimit(1).truncationMode(.middle).frame(maxWidth: 280, alignment: .trailing)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Double(g.launches) > limit ? p.warn : p.text)
            }
        }
    }

    @ViewBuilder func eventsPanel(_ shown: [LaunchEvent]) -> some View {
        Panel(title: "Events", trailing: "\(shown.count) shown · newest first") {
            if shown.isEmpty {
                Text(e.launchLog.events.isEmpty ? "No launches or exits seen yet. They appear here from the second sample on." : "No events match the filter.")
                    .foregroundStyle(p.dim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["TIME", "EVENT", "NAME", "PID", "PARENT", "USER", "LIFETIME"], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) }
                    }
                    // A Grid isn't lazy, so the list is capped; the filter reaches older events.
                    ForEach(shown.prefix(400)) { ev in eventRow(ev) }
                }.font(.system(size: 11, design: .monospaced))
                if shown.count > 400 { Text("Showing the newest 400; filter to see older events.").font(.caption).foregroundStyle(p.dim) }
            }
        }
    }

    func eventRow(_ ev: LaunchEvent) -> some View {
        GridRow {
            Text(ev.time.formatted(date: .omitted, time: .standard)).foregroundStyle(p.dim)
            Text(ev.kind.rawValue).foregroundStyle(ev.kind == .launch ? p.accent : p.accent2)
            Text(ev.name).lineLimit(1).help(ev.path.isEmpty ? "path unavailable" : ev.path)
            Text(verbatim: "\(ev.identity.pid)")
            Text(verbatim: ev.parentName.map { "\($0) (\(ev.ppid))" } ?? "\(ev.ppid)").foregroundStyle(p.dim).lineLimit(1)
            Text(ev.user).foregroundStyle(p.dim)
            // Exits: start → first sample without it, so at most one interval longer than the real lifetime.
            Text(ev.lifetime.map { "≤ " + Self.short($0) } ?? "").foregroundStyle(p.dim)
                .help(ev.lastSeen.map { "Exited between \($0.formatted(date: .omitted, time: .standard)) and \(ev.time.formatted(date: .omitted, time: .standard))" } ?? "")
        }
        .contextMenu {
            Button("Inspect…") { AppActions.openInspector?(ev.identity) }
                .disabled(ev.kind == .exit || AppActions.openInspector == nil)   // the inspector itself shows "EXITED" if it has gone since
            Button("Filter to \(ev.name)") { filter = ev.name }
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(ev.path, inFileViewerRootedAtPath: "") }.disabled(ev.path.isEmpty || Demo.isEnabled)
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ev.path, forType: .string) }.disabled(ev.path.isEmpty)
        }
    }

    /// Compact lifetimes: "0.8 s", "42 s", "3m 12s", "2h 5m".
    static func short(_ t: TimeInterval) -> String {
        if t < 10 { return String(format: "%.1f s", t) }
        if t < 60 { return "\(Int(t)) s" }
        if t < 3600 { return "\(Int(t) / 60)m \(Int(t) % 60)s" }
        if t < 86_400 { return "\(Int(t) / 3600)h \(Int(t) % 3600 / 60)m" }
        return Fmt.duration(t)
    }
}
