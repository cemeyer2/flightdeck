import SwiftUI
import FlightDeckCore
// Backups destination (Storage): Time Machine's state now, each backup disk, the history of runs and gaps, why runs
// failed, and local snapshots. Data from BackupsCollector (Time Machine's settings file, tmutil, backupd's log messages
// saved by FlightDeck); refresh cadence in BackupsModel. History and explanation panels are in BackupsPanels.swift.

struct BackupsView: View {
    @Environment(\.palette) var p
    @Environment(\.offscreen) private var offscreen
    @ObservedObject private var model: BackupsModel

    init(model: BackupsModel? = nil) { self.model = model ?? BackupsModel.shared }

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Is this Mac backed up? Time Machine's status, backup disks, history and what went wrong.").foregroundStyle(p.dim)
                    if model.loading { ProgressView().controlSize(.small) }
                    Spacer()
                    // Off-screen renders draw controls as placeholders, so the button is left out there.
                    if !offscreen { Button("Refresh") { Task { await model.load(scanLog: true) } }.disabled(model.loading || model.fixed) }
                }.font(.system(size: 12))
                if let r = model.report { BackupsContent(report: r) }
                else if !model.loading { Text("Not loaded yet.").foregroundStyle(p.dim) }
                else { Text("Reading Time Machine's settings and recent backup messages…").foregroundStyle(p.dim) }
            }.padding(16)
        }
        .task { await model.pageOpened(); await model.followProgress() }
    }
}

/// The page's panels for a loaded report (also what UIBench renders).
struct BackupsContent: View {
    @Environment(\.palette) var p
    var report: BackupsReport
    var now = Date()

    var body: some View {
        let r = report
        VStack(alignment: .leading, spacing: 12) {
            BackupStatusPanel(report: r, now: now)
            if !r.destinations.isEmpty {
                ForEach(r.destinations) { d in BackupDestinationPanel(dest: d, runs: r.runs.filter { $0.destinationID == d.id }, now: now) }
                BackupHistoryPanel(report: r, now: now)
                HStack(alignment: .top, spacing: 12) {
                    BackupGapsPanel(report: r).frame(maxWidth: .infinity)
                    LocalSnapshotsPanel(report: r).frame(maxWidth: .infinity)
                }
                BackupFailuresPanel(report: r)
            }
            BackupLimitsPanel(report: r)
        }
    }
}

/// "3 h ago", "2 days ago".
func backupAgo(_ d: Date, now: Date = Date()) -> String {
    let s = max(now.timeIntervalSince(d), 0)
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 2 * 86_400 { return "\(Int(s / 3600)) h ago" }
    return "\(Int(s / 86_400)) days ago"
}

/// Status now: state, progress of a running backup, last successful backup, schedule, and an open gap.
struct BackupStatusPanel: View {
    @Environment(\.palette) var p
    var report: BackupsReport
    var now: Date

    var stateColor: Color {
        switch report.state {
        case .backingUp: p.accent
        case .idle: report.ongoingGap == nil ? p.text : p.warn
        case .disabled, .notConfigured: p.warn
        case .unknown: p.dim
        }
    }

    var schedule: String? {
        guard let auto = report.autoBackup else { return nil }
        guard auto else { return "Off" }
        switch report.interval ?? 3600 {
        case ..<7200: return "Hourly"
        case ..<(2 * 86_400): return "Daily"
        default: return "Weekly"
        }
    }

    var body: some View {
        let r = report
        Panel(title: "Time Machine now", trailing: r.destinations.isEmpty ? nil : "\(r.destinations.count) backup disk\(r.destinations.count == 1 ? "" : "s")") {
            HStack(spacing: 28) {
                Readout(label: "Status", value: r.state.rawValue, color: stateColor, size: 16)
                Readout(label: "Last successful", value: r.lastSuccess.map { backupAgo($0, now: now) }, color: r.ongoingGap == nil ? nil : p.warn, size: 16)
                Readout(label: "Automatic", value: schedule, size: 16)
                Readout(label: "Backups (30 d)", value: r.destinations.isEmpty ? nil : "\(r.successes.filter { now.timeIntervalSince($0) < 30 * 86_400 }.count)", size: 16)
                Readout(label: "Failed runs (30 d)", value: r.watchingSince == nil ? nil : "\(r.failures.filter { now.timeIntervalSince($0.start) < 30 * 86_400 }.count)",
                        color: r.failures.isEmpty ? nil : p.warn, size: 16)
                Spacer()
            }
            if let s = r.status, s.running { progress(s) }
            Text(message).font(.system(size: 12)).foregroundStyle(r.ongoingGap != nil || r.state == .notConfigured ? p.warn : p.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var message: String {
        let r = report
        switch r.state {
        case .notConfigured: return "No backup disk is set up. Without a backup a failed drive, a lost Mac or a deleted file can't be recovered. Add one in System Settings › General › Time Machine."
        case .unknown: return "Time Machine's state couldn't be read; see the notes below."
        default: break
        }
        var parts: [String] = []
        if let g = r.ongoingGap {
            parts.append("No successful backup for \(Int(g.length / 86_400)) days. Connect the backup disk (or join its network) and choose Back Up Now from the Time Machine menu.")
        }
        if r.state == .disabled { parts.append("Automatic backups are turned off, so Time Machine only backs up when you ask it to.") }
        if let l = r.lastSuccess { parts.append("Last completed backup: \(l.formatted(date: .abbreviated, time: .shortened)).") }
        return parts.joined(separator: " ")
    }

    func progress(_ s: BackupStatusNow) -> some View {
        let name = s.destinationID.flatMap { id in report.destinations.first { $0.id == id }?.name }
        var detail = [s.phaseTitle + (name.map { " to \($0)" } ?? "")]
        if let c = s.bytesCopied, let t = s.totalBytes { detail.append("\(Fmt.storage(c)) of \(Fmt.storage(t))") }
        if let f = s.filesCopied, let t = s.totalFiles { detail.append("\(f.formatted()) of \(t.formatted()) files") }
        if let left = s.timeRemaining { detail.append("about \(shortDuration(left)) left") }
        return VStack(alignment: .leading, spacing: 4) {
            BackupBar(fraction: s.fraction ?? 0, color: p.accent)
            Text(detail.joined(separator: " · ") + (s.fraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.text)
        }
    }
}

/// One backup disk: kind, address, space and its trend, last backup, how many backups it holds, encryption.
struct BackupDestinationPanel: View {
    @Environment(\.palette) var p
    var dest: BackupDestination
    var runs: [BackupRun]
    var now: Date

    var body: some View {
        let d = dest
        let kind = d.kind == .network ? "Network" : d.kind == .local ? "Local disk" : "Backup disk"
        Panel(title: d.name, trailing: ([kind] + (d.isLast ? ["used last"] : []) + (d.backingUpNow ? ["backing up now"] : [])).joined(separator: " · ")) {
            HStack(alignment: .top, spacing: 28) {
                Image(systemName: d.kind == .network ? "externaldrive.connected.to.line.below" : "externaldrive")
                    .font(.system(size: 26)).foregroundStyle(d.backingUpNow ? p.accent : p.dim).frame(width: 34)
                Readout(label: "Free", value: d.bytesAvailable.map { Fmt.storage($0) }, size: 16)
                Readout(label: "Used", value: d.bytesUsed.map { Fmt.storage($0) }, size: 16)
                Readout(label: "Last backup", value: d.lastSuccess.map { backupAgo($0, now: now) }, size: 16)
                Readout(label: "Backups kept", value: d.backupsKept > 0 ? "\(d.backupsKept)" : nil, size: 16)
                Readout(label: "Encrypted", value: d.encrypted.map { $0 ? "Yes" : "No" }, size: 16)
                Spacer()
            }
            if let a = d.bytesAvailable, let u = d.bytesUsed, a + u > 0 { spaceBar(used: Double(u), total: Double(a + u)) }
            if d.space.count >= 2 { trend(d) }
            Text(details(d)).font(.system(size: 11)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func spaceBar(used: Double, total: Double) -> some View {
        BackupBar(fraction: used / total, color: used / total > 0.9 ? p.warn : p.accent)
    }

    /// Free space over the saved points, with the change per week.
    func trend(_ d: BackupDestination) -> some View {
        let pts = d.space
        let lo = Double(pts.map(\.available).min() ?? 0), hi = Double(pts.map(\.available).max() ?? 1)
        let t0 = pts.first!.time, span = max(pts.last!.time.timeIntervalSince(t0), 1)
        return HStack(spacing: 10) {
            Canvas { ctx, size in
                var path = Path()
                for (i, pt) in pts.enumerated() {
                    let x = CGFloat(pt.time.timeIntervalSince(t0) / span) * size.width
                    let y = size.height - CGFloat(hi > lo ? (Double(pt.available) - lo) / (hi - lo) : 0.5) * (size.height - 2) - 1
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(p.accent), lineWidth: 1.5)
            }.frame(width: 220, height: 26).background(RoundedRectangle(cornerRadius: 3).fill(p.meterOff.opacity(0.5)))
            Text(trendText(d)).font(.system(size: 11, design: .monospaced)).foregroundStyle((d.freeSpacePerDay ?? 0) < 0 ? p.text : p.dim)
        }
    }

    func trendText(_ d: BackupDestination) -> String {
        guard let perDay = d.freeSpacePerDay else { return "free space since \(d.space[0].time.formatted(date: .abbreviated, time: .omitted))" }
        let week = Fmt.storage(abs(perDay * 7))
        var s = perDay < 0 ? "free space falling \(week) a week" : "free space rising \(week) a week"
        // Time Machine deletes its oldest backups when the disk fills, so a falling trend means history will shorten.
        if perDay < 0, let a = d.bytesAvailable { s += ", full in about \(Int(Double(a) / -perDay)) days (then the oldest backups are deleted)" }
        return s
    }

    func details(_ d: BackupDestination) -> String {
        var s: [String] = []
        if let a = d.address { s.append(a) } else if let m = d.mountPoint { s.append(m) }
        if let o = d.oldestBackup { s.append("oldest backup \(o.formatted(date: .abbreviated, time: .omitted))") }
        if let l = d.lastSuccess { s.append("last completed \(l.formatted(date: .abbreviated, time: .shortened))") }
        if let v = d.lastVerified { s.append("last verified \(v.formatted(date: .abbreviated, time: .omitted))") }
        if let c = d.lastResult, c != 0 { s.append("last run ended with result code \(c)") }
        let ok = runs.filter(\.succeeded).compactMap(\.duration)
        if !ok.isEmpty { s.append("typical backup \(shortDuration(ok.sorted()[ok.count / 2]))") }
        return s.joined(separator: " · ")
    }
}

/// A plain filled bar (drawn, rather than ProgressView, so it also renders off-screen).
struct BackupBar: View {
    @Environment(\.palette) var p
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(p.meterOff)
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }.frame(height: 8)
    }
}
