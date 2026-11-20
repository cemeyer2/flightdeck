import Foundation

// Backups, part 2: parsers for Time Machine's preferences plist and `tmutil destinationinfo -X` / `tmutil status -X`.
// Pure functions over captured output, so they are tested with fixtures (BackupTests); the I/O is in BackupsCollector.

public enum BackupParse {
    static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
    /// Plist numbers arrive as NSNumber; negative values are treated as absent.
    static func uint(_ any: Any?) -> UInt64? {
        guard let n = any as? NSNumber, n.int64Value >= 0 else { return nil }
        return n.uint64Value
    }
    /// AutoBackup and similar flags are Bools in some macOS versions and 0/1 integers in others.
    static func flag(_ any: Any?) -> Bool? { (any as? Bool) ?? (any as? NSNumber).map { $0.intValue != 0 } }

    /// /Library/Preferences/com.apple.TimeMachine.plist, already decoded. Missing keys become nil, never 0.
    public static func prefs(_ d: [String: Any]) -> TimeMachinePrefs {
        let dests = (d["Destinations"] as? [[String: Any]] ?? []).enumerated().map { i, x -> TimeMachinePrefs.Destination in
            let enc = x["LastKnownEncryptionState"] as? String
            return TimeMachinePrefs.Destination(
                id: x["DestinationID"] as? String ?? "destination-\(i + 1)",
                volumeName: x["LastKnownVolumeName"] as? String, networkURL: x["NetworkURL"] as? String,
                bytesAvailable: uint(x["BytesAvailable"]), bytesUsed: uint(x["BytesUsed"]),
                snapshots: (x["SnapshotDates"] as? [Date] ?? []).sorted(), attempts: (x["AttemptDates"] as? [Date] ?? []).sorted(),
                lastResult: (x["RESULT"] as? NSNumber)?.intValue,
                encrypted: enc.map { $0 == "Encrypted" }, lastVerified: x["ConsistencyScanDate"] as? Date,
                volumeUUIDs: x["DestinationUUIDs"] as? [String] ?? [])
        }
        let interval = (d["AutoBackupInterval"] as? NSNumber).map { $0.doubleValue }.flatMap { $0 > 0 ? $0 : nil }
        return TimeMachinePrefs(autoBackup: flag(d["AutoBackup"]), interval: interval, destinations: dests,
                                lastDestinationID: d["LastDestinationID"] as? String)
    }

    /// `tmutil destinationinfo -X`: a plist with a Destinations array. Nil when the output isn't that plist (tmutil
    /// printed an error); [] when no destination is configured.
    public static func destinationInfo(_ out: String) -> [TMDestinationInfo]? {
        guard let d = plist(Data(out.utf8)) else {
            // With no destination tmutil prints a plain sentence instead of a plist.
            return out.localizedCaseInsensitiveContains("No destinations configured") ? [] : nil
        }
        return (d["Destinations"] as? [[String: Any]] ?? []).compactMap { x in
            guard let id = x["ID"] as? String else { return nil }
            return TMDestinationInfo(id: id, name: x["Name"] as? String ?? "Backup disk",
                                     kind: (x["Kind"] as? String).flatMap(TMDestinationInfo.Kind.init(rawValue:)),
                                     url: x["URL"] as? String, mountPoint: x["MountPoint"] as? String)
        }
    }

    /// `tmutil status -X`. Percent is a 0…1 fraction (-1 before backupd has an estimate); Progress holds the byte and
    /// file counts while copying. Nil when the output isn't a plist.
    public static func status(_ out: String) -> BackupStatusNow? {
        guard let d = plist(Data(out.utf8)) else { return nil }
        let running = flag(d["Running"]) ?? false
        let prog = d["Progress"] as? [String: Any] ?? [:]
        func fraction(_ any: Any?) -> Double? {
            guard let n = (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init), n >= 0 else { return nil }
            return min(n, 1)
        }
        let remaining = (prog["TimeRemaining"] as? NSNumber)?.doubleValue
        return BackupStatusNow(
            running: running, phase: running ? d["BackupPhase"] as? String : nil,
            fraction: running ? (fraction(prog["Percent"]) ?? fraction(d["Percent"])) : nil,
            bytesCopied: uint(prog["bytes"]), totalBytes: uint(prog["totalBytes"]),
            filesCopied: (prog["files"] as? NSNumber)?.intValue, totalFiles: (prog["totalFiles"] as? NSNumber)?.intValue,
            timeRemaining: remaining.flatMap { $0 > 0 ? $0 : nil },
            destinationID: d["DestinationID"] as? String, destinationMount: d["DestinationMountPoint"] as? String)
    }

    /// Stretches longer than `threshold` with no successful backup, oldest first, within `window` before `now`. The
    /// one still open at `now` (if long enough) is last. `successes` from every destination, in any order.
    /// Time Machine thins older backups to one a week, so gaps that end before `thinnedBefore` are only reported when
    /// they are longer than 8 days (shorter ones may be thinning, not a missed backup).
    public static func gaps(successes: [Date], threshold: TimeInterval, window: TimeInterval, thinnedBefore: Date?, now: Date) -> [BackupGap] {
        let start = now.addingTimeInterval(-window)
        let s = Array(Set(successes)).sorted()
        var out: [BackupGap] = []
        for (a, b) in zip(s, s.dropFirst()) where b > start {
            let len = b.timeIntervalSince(a)
            let needed = thinnedBefore.map { b < $0 } == true ? max(threshold, 8 * 86_400) : threshold
            if len > needed { out.append(BackupGap(from: a, to: b, length: len)) }
        }
        if let last = s.last, now.timeIntervalSince(last) > threshold {
            out.append(BackupGap(from: last, to: nil, length: now.timeIntervalSince(last)))
        }
        return out
    }

    /// How long without a successful backup counts as a gap: three missed automatic backups, at least 3 days (so an
    /// hourly schedule on a laptop that's away from its disk over a weekend doesn't count).
    public static func gapThreshold(interval: TimeInterval?) -> TimeInterval {
        max(3 * 86_400, 3 * (interval ?? 3600))
    }
}

extension CheckupParse {
    /// Checkup's view of the same plist (kept for its "last backup" check).
    static func timeMachine(prefs p: TimeMachinePrefs) -> TimeMachine {
        TimeMachine(autoBackup: p.autoBackup, destinations: p.destinations.count, latest: p.latestBackup)
    }
}
