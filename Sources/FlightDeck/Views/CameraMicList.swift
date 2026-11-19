// The Camera & Mic page's lists: apps in the range (total time, sessions, first seen; click to filter) and every
// session, newest first, with badges for first use, unusual hours, locked or idle starts, and starts or ends FlightDeck
// didn't see (it wasn't running). The attribution basis is shown in the row's tooltip and the "How" column.
import SwiftUI
import FlightDeckCore

struct CameraMicSessionList: View {
    /// Newest first.
    let sessions: [SensorSession]
    let firstSeen: [String: Date]
    let now: Date
    var filterApp: (String) -> Void = { _ in }
    @Environment(\.palette) var p
    static let cap = 400

    struct AppRow: Identifiable { let id: String; let sample: SensorSession; var kinds: Set<SensorKind>; var count: Int; var secs: TimeInterval }

    func apps() -> [AppRow] {
        var rows: [String: AppRow] = [:]
        for s in sessions {
            let k = CameraMicView.appKey(s)
            rows[k, default: AppRow(id: k, sample: s, kinds: [], count: 0, secs: 0)].count += 1
            rows[k]?.secs += s.duration(now: now)
            rows[k]?.kinds.insert(s.kind)
        }
        return rows.values.sorted { $0.secs > $1.secs }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            appsPanel
            Panel(title: "Sessions", trailing: "\(sessions.count) shown · newest first") {
                if sessions.isEmpty {
                    Text("No sessions match.").foregroundStyle(p.dim)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        GridRow {
                            ForEach(["STARTED", "DEVICE", "APP", "DURATION", "NOTES", "HOW WE KNOW"], id: \.self) {
                                Text($0).font(.meterLabel).foregroundStyle(p.dim)
                            }
                        }
                        // A Grid isn't lazy, so the list is capped; the filters reach older sessions.
                        ForEach(sessions.prefix(Self.cap)) { row($0) }
                    }.font(.system(size: 11, design: .monospaced))
                    if sessions.count > Self.cap {
                        Text("Showing the newest \(Self.cap); filter by app or device to see older sessions.").font(.caption).foregroundStyle(p.dim)
                    }
                }
            }
        }
    }

    @ViewBuilder var appsPanel: some View {
        let rows = apps()
        Panel(title: "Apps", trailing: rows.isEmpty ? nil : "\(rows.count) in this range") {
            if rows.isEmpty { Text("No app used a camera or microphone in this range.").foregroundStyle(p.dim) }
            ForEach(rows.prefix(20)) { a in
                Button { filterApp(a.id) } label: {
                    HStack(spacing: 10) {
                        appIcon(a.sample).frame(width: 16, height: 16)
                        Text(a.sample.app == nil ? "Unknown app" : a.sample.appLabel).lineLimit(1).frame(width: 200, alignment: .leading)
                        HStack(spacing: 4) {
                            ForEach(SensorKind.allCases, id: \.self) { k in
                                Image(systemName: k.icon).foregroundStyle(a.kinds.contains(k) ? p.text : p.dim.opacity(0.3)).help(k.title)
                            }
                        }.frame(width: 44, alignment: .leading)
                        Text("\(a.count) session\(a.count == 1 ? "" : "s")").foregroundStyle(p.dim).frame(width: 100, alignment: .leading)
                        Text(CameraMicFindings.span(a.secs)).frame(width: 90, alignment: .leading)
                        Text(firstSeenText(a.sample)).foregroundStyle(p.dim)
                        Spacer()
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Show only this app's sessions")
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    func firstSeenText(_ s: SensorSession) -> String {
        guard s.confidence == .confirmed, let app = s.app else { return "" }
        let dates = SensorKind.allCases.compactMap { firstSeen[CameraMicTracker.knownKey($0, app)] }
        return dates.min().map { "first seen \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
    }

    @ViewBuilder func appIcon(_ s: SensorSession) -> some View {
        if let path = s.app?.path, s.confidence != .unknown { AppIcon(path: path + "/") }
        else { Image(systemName: "questionmark.app.dashed").resizable().foregroundStyle(p.dim) }
    }

    func row(_ s: SensorSession) -> some View {
        GridRow {
            Text((s.startObserved ? "" : "≤ ") + s.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .foregroundStyle(s.atUnusualHour() ? p.warn : p.dim)
                .help(s.startObserved ? "" : "Already in use when FlightDeck started watching")
            HStack(spacing: 4) {
                Image(systemName: s.kind.icon).frame(width: 14)
                Text(s.devices.isEmpty ? s.kind.title : s.devices.joined(separator: ", ")).lineLimit(1)
            }.frame(maxWidth: 220, alignment: .leading)
            HStack(spacing: 4) {
                appIcon(s).frame(width: 14, height: 14)
                Text(s.appLabel).lineLimit(1).foregroundStyle(s.confidence == .confirmed ? p.text : p.dim)
            }.help([s.app?.bundleID, s.app?.path, s.app?.pid.map { "PID \($0)" }].compactMap { $0 }.joined(separator: "\n"))
            Text(s.isOpen ? "in use · \(CameraMicFindings.span(s.duration(now: now)))"
                          : (s.endObserved ? "" : "≥ ") + CameraMicFindings.span(s.duration(now: now)))
                .foregroundStyle(s.isOpen ? p.warn : p.text)
            HStack(spacing: 4) { ForEach(badges(s), id: \.self) { CameraMicBadge(text: $0) } }
            Text(s.how).foregroundStyle(p.dim).lineLimit(1).truncationMode(.tail).frame(maxWidth: 360, alignment: .leading).help(s.how)
        }
        .contextMenu {
            Button("Show Only \(s.appLabel)") { filterApp(CameraMicView.appKey(s)) }
            if let path = s.app?.path, !Demo.isEnabled {
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            }
        }
    }

    func badges(_ s: SensorSession) -> [String] {
        var b: [String] = []
        if s.firstUse { b.append("FIRST USE") }
        if s.atUnusualHour() { b.append("00–06") }
        if s.whileLocked { b.append("LOCKED") }
        if s.whileIdle && !s.whileLocked { b.append("IDLE") }
        return b
    }
}

/// A small warning-coloured tag ("FIRST USE", "LOCKED"): text plus colour, so it doesn't rely on colour alone.
struct CameraMicBadge: View {
    let text: String
    @Environment(\.palette) var p
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(p.warn)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(p.warn.opacity(0.7), lineWidth: 1))
    }
}
