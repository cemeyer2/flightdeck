import Foundation

// Backups, part 3: backupd's unified-log messages about each run, and rebuilding runs from them.
// backupd logs these at the Info level (macOS keeps them a day or two), in four categories:
//   BackupJob          Attempting backup with mode "automatic backup"
//   BackupEngine       Backing up 1 volumes to <disk name> (/dev/disk5s2,…): /Volumes/<disk name>
//   BackupEngine       Successfully completed backing up 7.22 GB to '/Volumes/.timemachine/<volume UUID>/<date>.backup/…'
//   BackupDispatching  Backup succeeded\nElapsed time: About 33 minutes
//   ErrorEvaluator     Error evaluator wrapped original error as: BACKUP_FAILED_DISCONNECTED_NETWORK (26)\nunderlying error: …
//   BackupDispatching  Backup failed: BACKUP_DELAYED_NOT_ENOUGH_ELAPSED_TIME (107)
// The last kind with a BACKUP_DELAYED_ name is the scheduler declining to start (too soon since the last backup, on
// battery, …), not a failed run, so it's ignored.

/// One saved log message about a run.
public struct BackupLogEvent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case attempt, copying, completed, succeeded, failed }
    public var time: Date
    public var kind: Kind
    /// attempt: the mode ("automatic backup"); copying: the disk name; failed: the result name.
    public var text: String?
    /// completed: bytes copied. failed: the result code.
    public var number: Int64?
    /// completed: the backup volume UUID from the path.
    public var volumeUUID: String?
    /// succeeded/failed: backupd's "About 33 minutes".
    public var elapsed: String?
    public init(time: Date, kind: Kind, text: String? = nil, number: Int64? = nil, volumeUUID: String? = nil, elapsed: String? = nil) {
        self.time = time; self.kind = kind; self.text = text; self.number = number; self.volumeUUID = volumeUUID; self.elapsed = elapsed
    }
}

public enum BackupLog {
    /// The `log show` predicate: backupd's run messages only (a few dozen per backup).
    public static let predicate = #"process == "backupd" AND category IN {"BackupJob","BackupEngine","BackupDispatching","ErrorEvaluator"}"#

    /// "7.22 GB" / "512 KB" / "1.5 TB" (decimal units, as backupd prints them) → bytes.
    static func bytes(_ number: Substring, _ unit: Substring) -> Int64? {
        guard let v = Double(number) else { return nil }
        let scale: Double
        switch unit.uppercased() {
        case "B", "BYTES": scale = 1
        case "KB": scale = 1e3
        case "MB": scale = 1e6
        case "GB": scale = 1e9
        case "TB": scale = 1e12
        default: return nil
        }
        return Int64(v * scale)
    }

    static func elapsed(_ msg: String) -> String? {
        guard let m = msg.firstMatch(of: #/Elapsed time: ([^\n}]+)/#) else { return nil }
        return String(m.1).trimmingCharacters(in: .whitespaces)
    }

    /// One message → an event, or nil for the many other messages in these categories.
    public static func event(time: Date, message msg: String) -> BackupLogEvent? {
        if let m = msg.firstMatch(of: #/^Attempting backup with mode "([^"]+)"/#) {
            return BackupLogEvent(time: time, kind: .attempt, text: String(m.1))
        }
        if let m = msg.firstMatch(of: #/^Backing up \d+ volumes? to (.+?) \(/#) {
            return BackupLogEvent(time: time, kind: .copying, text: String(m.1))
        }
        if let m = msg.firstMatch(of: #/^Successfully completed backing up ([\d.]+) ?([KMGT]?B)/#) {
            let uuid = msg.firstMatch(of: #/\.timemachine/([0-9A-Fa-f-]{36})/#).map { String($0.1) }
            return BackupLogEvent(time: time, kind: .completed, number: bytes(m.1, m.2), volumeUUID: uuid)
        }
        if msg.hasPrefix("Backup succeeded") { return BackupLogEvent(time: time, kind: .succeeded, elapsed: elapsed(msg)) }
        if let m = msg.firstMatch(of: #/(?:wrapped original error as|^Backup failed): ([A-Z0-9_]+) \((-?\d+)\)/#) {
            let name = String(m.1)
            if name.hasPrefix("BACKUP_DELAYED") { return nil }
            return BackupLogEvent(time: time, kind: .failed, text: name, number: Int64(m.2), elapsed: elapsed(msg))
        }
        return nil
    }

    /// `log show --style ndjson` output → events, oldest first.
    public static func parse(ndjson: String) -> [BackupLogEvent] {
        ndjson.split(separator: "\n").compactMap { line -> BackupLogEvent? in
            guard line.first == "{", let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let msg = o["eventMessage"] as? String,
                  let t = (o["timestamp"] as? String).flatMap(LogParser.parseTimestamp) else { return nil }
            return event(time: t, message: msg)
        }.sorted { $0.time < $1.time }
    }

    /// Runs from saved events (oldest first in, newest first out). A run opens at an attempt and closes at its
    /// outcome; the copying and completed messages in between fill it in. An outcome without an attempt (the log
    /// rotated mid-run) still makes a run, starting at its first event. `volumeIDs` maps backup volume UUIDs to the
    /// plist's destination IDs.
    public static func runs(_ events: [BackupLogEvent], volumeIDs: [String: String] = [:]) -> [BackupRun] {
        var out: [BackupRun] = []
        var open: BackupRun?
        func close(_ outcome: BackupRun.Outcome, at t: Date, elapsed: String?) {
            var r = open ?? BackupRun(start: t, outcome: .unfinished)
            if open == nil { r.startSeen = false }
            r.outcome = outcome; r.end = t; r.elapsedText = elapsed ?? r.elapsedText
            out.append(r); open = nil
        }
        for e in events.sorted(by: { $0.time < $1.time }) {
            switch e.kind {
            case .attempt:
                if let o = open { out.append(o) }   // an attempt that never logged an outcome
                open = BackupRun(start: e.time, mode: e.text, outcome: .unfinished)
            case .copying:
                if open == nil { open = BackupRun(start: e.time, outcome: .unfinished); open?.startSeen = false }
                if open?.copyStart == nil { open?.copyStart = e.time }
                open?.destinationName = e.text
            case .completed:
                if open == nil { open = BackupRun(start: e.time, outcome: .unfinished); open?.startSeen = false }
                open?.bytesCopied = e.number.map { UInt64(max($0, 0)) }
                if let u = e.volumeUUID { open?.destinationID = volumeIDs[u.uppercased()] }
            case .succeeded:
                close(.succeeded, at: e.time, elapsed: e.elapsed)
            case .failed:
                // backupd logs a failure twice (the error evaluator, then the dispatcher): the second joins the first.
                if open == nil, let last = out.last, case .failed = last.outcome, let end = last.end, e.time.timeIntervalSince(end) < 120 { continue }
                close(.failed(name: e.text ?? "BACKUP_FAILED", code: e.number.map(Int.init)), at: e.time, elapsed: e.elapsed)
            }
        }
        if let o = open { out.append(o) }
        return out.reversed()
    }
}
