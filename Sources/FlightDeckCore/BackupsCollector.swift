import Foundation

// Backups, part 7: the I/O. Reads Time Machine's settings file, `tmutil destinationinfo -X` and `tmutil status -X`
// (milliseconds each, nothing mounted), optionally backupd's recent log messages (a few seconds of `log show`, so only
// every few hours and when the page opens), and the local snapshot list, then builds the report and saves what it
// learned. Blocking; call off the main thread.

public enum BackupsCollector {
    public static let prefsPath = "/Library/Preferences/com.apple.TimeMachine.plist"
    /// The log is read at most this far back (backupd's Info messages rarely last longer anyway).
    static let maxLogLookback: TimeInterval = 3 * 86_400

    public static func readPrefs(path: String = prefsPath) -> (TimeMachinePrefs?, String?) {
        guard FileManager.default.fileExists(atPath: path) else {
            return (TimeMachinePrefs(), nil)   // never set up: no file until Time Machine is first configured
        }
        guard let data = FileManager.default.contents(atPath: path), let d = BackupParse.plist(data) else {
            return (nil, "Time Machine's settings file (\(path)) couldn't be read, so destinations and completed backups are unknown.")
        }
        return (BackupParse.prefs(d), nil)
    }

    public static func readInfo() -> [TMDestinationInfo]? {
        Shell.run("/usr/bin/tmutil", ["destinationinfo", "-X"], timeout: 10).flatMap(BackupParse.destinationInfo)
    }

    public static func readStatus() -> (BackupStatusNow?, String?) {
        guard let out = Shell.run("/usr/bin/tmutil", ["status", "-X"], timeout: 10), let s = BackupParse.status(out) else {
            return (nil, "Whether a backup is running now couldn't be read (tmutil status failed).")
        }
        return (s, nil)
    }

    /// Reads backupd's run messages since the last scan (a few minutes of overlap), at most 3 days back, into the
    /// store. Returns a note when `log` failed.
    public static func scanLog(store: BackupStore, now: Date = Date()) -> String? {
        let from = max((store.logScannedTo ?? .distantPast).addingTimeInterval(-600), now.addingTimeInterval(-maxLogLookback))
        let args = ["show", "--style", "ndjson", "--info", "--no-backtrace", "--start", "@\(Int(from.timeIntervalSince1970))", "--predicate", BackupLog.predicate]
        guard let out = Shell.run("/usr/bin/log", args, timeout: 90) else { return "The unified log couldn't be read (log show failed)." }
        store.add(events: BackupLog.parse(ndjson: out), scannedTo: now)
        return nil
    }

    /// - Parameter scanLog: read new log messages first (the page and the 6-hourly background check); false for
    ///   the cheap 15-minute check and the MCP tool, which use what's saved.
    public static func collect(store: BackupStore, scanLog doScan: Bool, now: Date = Date()) -> BackupsReport {
        let logNote = doScan ? scanLog(store: store, now: now) : nil
        let (prefs, prefsNote) = readPrefs()
        let info = readInfo()
        let (status, statusNote) = readStatus()
        let (snaps, snapNote) = StorageBreakdownReader.snapshots()
        var r = BackupsReport.build(prefs: prefs, info: info, status: status, store: store, snapshots: snaps, now: now)
        r.prefsNote = prefsNote; r.statusNote = statusNote; r.logNote = logNote; r.snapshotNote = snapNote
        store.save(now: now)
        return r
    }
}

/// The "no successful backup for N days" finding. A standing condition (like low disk space), not a one-shot: it's
/// raised while the gap lasts and clears with the next successful backup. Only when automatic backups are on and a
/// destination exists (Checkup covers "not set up" and "turned off").
public enum BackupFindings {
    public static let destination = "Backups"

    public static func evaluate(_ r: BackupsReport, now: Date = Date()) -> [Finding] {
        guard r.autoBackup != false, !r.destinations.isEmpty, r.state != .backingUp, let gap = r.ongoingGap else { return [] }
        let days = Int(gap.length / 86_400)
        let names = r.destinations.map(\.name)
        let since = gap.from.map { " The last one finished \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
        let failed = r.failures.first.map { " The latest attempt failed: \(BackupFailures.explain(failedName($0)).title.lowercased())." } ?? ""
        return [Finding(id: "backup-gap", severity: gap.length > 30 * 86_400 ? .warning : .caution, icon: "externaldrive.badge.exclamationmark",
                        title: "No successful Time Machine backup for \(days) days",
                        detail: "Nothing has been backed up to \(names.joined(separator: " or ")) in \(days) days." + since + failed
                            + " Connect the backup disk (or join its network) and choose Back Up Now.",
                        since: gap.from ?? now, destination: destination)]
    }

    static func failedName(_ run: BackupRun) -> String {
        if case .failed(let n, _) = run.outcome { return n }
        return "BACKUP_FAILED"
    }
}

/// Holds the latest backup findings for the Engine's sampling loop (thread-safe). Refreshed by the app's backup
/// check every 15 minutes; read every sample, which costs only a lock.
public final class BackupWatch: @unchecked Sendable {
    public static let shared = BackupWatch()
    private let lock = NSLock()
    private var current: [Finding] = []
    public func set(_ f: [Finding]) { lock.lock(); current = f; lock.unlock() }
    public func findings() -> [Finding] { lock.lock(); defer { lock.unlock() }; return current }
}
