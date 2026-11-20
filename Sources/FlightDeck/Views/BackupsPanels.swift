import SwiftUI
import FlightDeckCore
// Backups panels: the 90-day history strip and run list, gaps, failure reasons in plain English, local snapshots,
// and what the sources can't tell. Layout parts of BackupsView.

/// Completed backups, failures and gaps on a 90-day strip, then the runs FlightDeck saw in the log, newest first.
struct BackupHistoryPanel: View {
    @Environment(\.palette) var p
    var report: BackupsReport
    var now: Date
    static let days = 90.0

    var body: some View {
        let shown = report.runs.prefix(40)
        Panel(title: "History", trailing: "last \(Int(Self.days)) days") {
            strip.frame(height: 34)
            HStack(spacing: 14) {
                Label("completed backup", systemImage: "checkmark.circle").foregroundStyle(p.accent)
                Label("failed run", systemImage: "xmark.octagon").foregroundStyle(p.crit)
                Label("gap", systemImage: "rectangle.fill").foregroundStyle(p.warn.opacity(0.7))
            }.font(.system(size: 10, design: .monospaced))
            ForEach(Array(shown), id: \.start) { run in row(run) }
            if report.runs.isEmpty {
                Text(report.watchingSince == nil ? "No backup runs read from the unified log yet." : "No backup runs in the log since FlightDeck began reading it.")
                    .font(.system(size: 11)).foregroundStyle(p.dim)
            }
            if report.runs.count > shown.count { Text("\(report.runs.count - shown.count) older runs not shown.").font(.caption).foregroundStyle(p.dim) }
        }
    }

    var strip: some View {
        Canvas { ctx, size in
            let start = now.addingTimeInterval(-Self.days * 86_400), span = Self.days * 86_400
            func x(_ d: Date) -> CGFloat { CGFloat(max(d.timeIntervalSince(start), 0) / span) * (size.width - 4) + 2 }
            ctx.fill(Path(CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)), with: .color(p.grid))
            for g in report.gaps {
                let a = x(g.from ?? start), b = x(g.to ?? now)
                ctx.fill(Path(CGRect(x: a, y: 2, width: max(b - a, 2), height: size.height - 4)), with: .color(p.warn.opacity(0.25)))
            }
            for d in report.successes where d > start {
                ctx.fill(Path(roundedRect: CGRect(x: x(d) - 1, y: size.height * 0.3, width: 2, height: size.height * 0.4), cornerRadius: 1), with: .color(p.accent))
            }
            for f in report.failures where f.start > start {
                ctx.fill(Path(roundedRect: CGRect(x: x(f.start) - 1.5, y: 0, width: 3, height: size.height), cornerRadius: 1), with: .color(p.crit))
            }
        }
        .help("Each short tick is a completed backup (any disk). Tall red ticks are failed runs; shaded stretches had no successful backup for longer than \(Int(report.gapThreshold / 86_400)) days.")
    }

    func row(_ run: BackupRun) -> some View {
        let (icon, color, text): (String, Color, String) = {
            switch run.outcome {
            case .succeeded: return ("checkmark.circle", p.accent, "Completed")
            case .failed(let name, _): return ("xmark.octagon", p.crit, BackupFailures.explain(name).title)
            case .unfinished: return run.id == report.runs.first?.id && report.state == .backingUp
                ? ("arrow.triangle.2.circlepath", p.accent, "In progress") : ("questionmark.circle", p.dim, "No outcome logged")
            }
        }()
        let when = run.startSeen ? run.start : (run.end ?? run.start)
        let dur = run.duration.map(shortDuration) ?? run.elapsedText?.lowercased() ?? ""
        return HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 14)
            Text(when.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())).frame(width: 150, alignment: .leading)
            Text(run.destinationName ?? "—").foregroundStyle(p.dim).lineLimit(1).frame(width: 160, alignment: .leading)
            Text(text).foregroundStyle(run.succeeded ? p.text : color).lineLimit(1).frame(width: 360, alignment: .leading)
            Text(dur).foregroundStyle(p.dim).frame(width: 90, alignment: .leading)
            Text(run.bytesCopied.map { Fmt.storage($0) } ?? "").foregroundStyle(p.dim)
            Spacer()
        }.font(.system(size: 12, design: .monospaced))
    }
}

/// Stretches with no successful backup to any disk.
struct BackupGapsPanel: View {
    @Environment(\.palette) var p
    var report: BackupsReport
    var body: some View {
        Panel(title: "Gaps", trailing: "over \(Int(report.gapThreshold / 86_400)) days without a backup") {
            ForEach(report.gaps.reversed(), id: \.length) { g in
                HStack(spacing: 8) {
                    Image(systemName: g.ongoing ? "exclamationmark.triangle.fill" : "calendar.badge.exclamationmark").foregroundStyle(p.warn).frame(width: 14)
                    Text("\(Int(g.length / 86_400)) days").frame(width: 70, alignment: .leading)
                    Text((g.from.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "?") + " → "
                         + (g.to.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "now")).foregroundStyle(p.dim)
                    Spacer()
                }.font(.system(size: 11, design: .monospaced))
            }
            Text(report.gaps.isEmpty ? "No gaps in the last 90 days." : "Backups older than a month are thinned to one a week, so only gaps over 8 days are shown before then.")
                .font(.system(size: 11)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Local Time Machine snapshots on the startup disk; their sizes need administrator rights.
struct LocalSnapshotsPanel: View {
    @Environment(\.palette) var p
    var report: BackupsReport
    var body: some View {
        let tm = (report.snapshots ?? []).filter { $0.kind == .timeMachine }
        let other = (report.snapshots ?? []).count - tm.count
        Panel(title: "Local snapshots", trailing: report.snapshots.map { "\($0.count) on the startup disk" } ?? "unavailable") {
            ForEach(tm.compactMap(\.date).sorted(by: >).prefix(6), id: \.self) { d in
                HStack(spacing: 8) {
                    Image(systemName: "camera.aperture").foregroundStyle(p.dim).frame(width: 14)
                    Text(d.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Text("size unknown").foregroundStyle(p.dim)
                }.font(.system(size: 11, design: .monospaced))
            }
            if other > 0 { Text("\(other) macOS update snapshot\(other == 1 ? "" : "s").").font(.system(size: 11)).foregroundStyle(p.dim) }
            Text(report.snapshots == nil ? (report.snapshotNote ?? "tmutil couldn't list them.")
                 : "Time Machine keeps hourly snapshots on this Mac for 24 hours so recent files can be restored without the backup disk. Their space counts as purgeable: macOS deletes them when it needs room. Sizes are reported only to administrators.")
                .font(.system(size: 11)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Why the failed runs failed, in plain English, then the common reasons.
struct BackupFailuresPanel: View {
    @Environment(\.palette) var p
    var report: BackupsReport
    var body: some View {
        var seen = Set<String>(), mine: [(String, Int, BackupFailureExplanation)] = []
        for f in report.failures {
            guard case .failed(let name, _) = f.outcome else { continue }
            if seen.insert(name).inserted { mine.append((name, report.failures.filter { $0.outcome == f.outcome }.count, BackupFailures.explain(name))) }
        }
        return Panel(title: "Why backups fail", trailing: mine.isEmpty ? "no failures seen" : "\(report.failures.count) failed run\(report.failures.count == 1 ? "" : "s")") {
            ForEach(mine, id: \.0) { name, count, e in explanation(e, header: "\(e.title) ×\(count)", code: name, color: p.crit) }
            Text("COMMON REASONS").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(p.dim).padding(.top, 4)
            ForEach(BackupFailures.common.filter { c in !mine.contains { $0.2 == c } }, id: \.title) { e in explanation(e, header: e.title, code: nil, color: p.text) }
        }
    }

    func explanation(_ e: BackupFailureExplanation, header: String, code: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(header).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                if let code { Text(code).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim) }
            }
            Text(e.detail + (e.fix.map { " " + $0 } ?? "")).font(.system(size: 11)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What the sources can't tell, and since when FlightDeck has been reading them.
struct BackupLimitsPanel: View {
    @Environment(\.palette) var p
    var report: BackupsReport
    var body: some View {
        Panel(title: "About these numbers") {
            ForEach(report.limits, id: \.self) { n in
                Text("• " + n).font(.system(size: 11)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
