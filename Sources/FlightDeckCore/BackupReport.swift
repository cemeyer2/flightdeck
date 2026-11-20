import Foundation

// Backups, part 6: the page's report, built from the parsed sources and FlightDeck's saved history. Pure (no I/O), so
// demo data and tests go through the same code as the live page.

/// One backup destination with everything known about it.
public struct BackupDestination: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: TMDestinationInfo.Kind?
    /// A network share's address, without the user name (shown on the page).
    public var address: String?
    public var mountPoint: String?
    /// The destination Time Machine used last (it rotates between several).
    public var isLast: Bool
    public var backingUpNow: Bool
    public var bytesAvailable: UInt64?
    public var bytesUsed: UInt64?
    /// Completed backups still on the disk (from the plist), and the oldest of them.
    public var backupsKept: Int
    public var oldestBackup: Date?
    public var lastSuccess: Date?
    public var lastAttempt: Date?
    public var lastResult: Int?
    public var encrypted: Bool?
    public var lastVerified: Date?
    /// Free space as FlightDeck saw it over time, oldest first.
    public var space: [BackupSpacePoint]
    public init(id: String, name: String, kind: TMDestinationInfo.Kind?, address: String? = nil, mountPoint: String? = nil, isLast: Bool = false,
                backingUpNow: Bool = false, bytesAvailable: UInt64? = nil, bytesUsed: UInt64? = nil, backupsKept: Int = 0, oldestBackup: Date? = nil,
                lastSuccess: Date? = nil, lastAttempt: Date? = nil, lastResult: Int? = nil, encrypted: Bool? = nil, lastVerified: Date? = nil,
                space: [BackupSpacePoint] = []) {
        self.id = id; self.name = name; self.kind = kind; self.address = address; self.mountPoint = mountPoint; self.isLast = isLast
        self.backingUpNow = backingUpNow; self.bytesAvailable = bytesAvailable; self.bytesUsed = bytesUsed; self.backupsKept = backupsKept
        self.oldestBackup = oldestBackup; self.lastSuccess = lastSuccess; self.lastAttempt = lastAttempt; self.lastResult = lastResult
        self.encrypted = encrypted; self.lastVerified = lastVerified; self.space = space
    }

    /// Change in free space per day over the saved points (negative = filling up). Nil with under a day of points.
    public var freeSpacePerDay: Double? {
        guard let a = space.first, let b = space.last else { return nil }
        let days = b.time.timeIntervalSince(a.time) / 86_400
        guard days >= 1 else { return nil }
        return (Double(b.available) - Double(a.available)) / days
    }
}

public struct BackupsReport: Sendable {
    public enum State: String, Sendable { case notConfigured = "Not set up", disabled = "Automatic backups off", backingUp = "Backing up",
                                           idle = "Idle", unknown = "Unknown" }
    public var state: State = .unknown
    public var autoBackup: Bool?
    public var interval: TimeInterval?
    public var status: BackupStatusNow?
    public var destinations: [BackupDestination] = []
    /// Newest first, last 90 days.
    public var runs: [BackupRun] = []
    /// Every completed backup FlightDeck knows of (any destination), oldest first.
    public var successes: [Date] = []
    public var gaps: [BackupGap] = []
    public var gapThreshold: TimeInterval = 3 * 86_400
    public var lastSuccess: Date? { successes.last }
    public var snapshots: [LocalSnapshot]?
    /// Since when FlightDeck has read backupd's run messages (failures and durations before it are unknown).
    public var watchingSince: Date?
    /// Why a source couldn't be read, for the "what's unknown" notes; nil when it was.
    public var prefsNote: String?
    public var statusNote: String?
    public var logNote: String?
    public var snapshotNote: String?
    public init() {}

    public var ongoingGap: BackupGap? { gaps.last.flatMap { $0.ongoing ? $0 : nil } }
    public var failures: [BackupRun] { runs.filter { if case .failed = $0.outcome { true } else { false } } }

    /// Plain-English notes on what the sources can't tell.
    public var limits: [String] {
        var n: [String] = []
        if let prefsNote { n.append(prefsNote) }
        n.append("Completed backups: from Time Machine's settings file, which keeps every backup still on each disk. Time Machine thins them (hourly for a day, daily for a month, weekly after), so FlightDeck saves each date it sees for 90 days.")
        if let w = watchingSince {
            n.append("Durations, sizes and failures: from backupd's messages in the unified log, which macOS keeps only a day or two. FlightDeck has read them since \(w.formatted(date: .abbreviated, time: .shortened)); runs before that show no duration or failure details.")
        } else {
            n.append("Durations, sizes and failures: from backupd's messages in the unified log; none have been read yet.")
        }
        if let logNote { n.append(logNote) }
        if let statusNote { n.append(statusNote) }
        n.append("Local snapshots: macOS lists them without administrator rights but reports their sizes only to administrators, so their sizes are unknown here. Their space counts as purgeable (Disk Space).")
        if let snapshotNote { n.append("Local snapshots couldn't be listed: \(snapshotNote)") }
        n.append("Not used: tmutil listbackups and latestbackup, which need Full Disk Access and can mount a network backup disk; the settings file has the same dates.")
        return n
    }

    /// Builds the report. `info` nil when `tmutil destinationinfo` couldn't be read (names come from the plist then).
    public static func build(prefs: TimeMachinePrefs?, info: [TMDestinationInfo]?, status: BackupStatusNow?, store: BackupStore,
                             snapshots: [LocalSnapshot]?, now: Date = Date()) -> BackupsReport {
        var r = BackupsReport()
        r.autoBackup = prefs?.autoBackup; r.interval = prefs?.interval; r.status = status; r.snapshots = snapshots
        r.watchingSince = store.watchingSince
        if let prefs { store.note(prefs: prefs, at: now) }
        let p = prefs ?? TimeMachinePrefs()
        var volumeIDs: [String: String] = [:]
        for d in p.destinations { for u in d.volumeUUIDs { volumeIDs[u.uppercased()] = d.id } }
        let cut = now.addingTimeInterval(-BackupStore.retention)
        var runs = BackupLog.runs(store.events, volumeIDs: volumeIDs).filter { $0.start >= cut }
        // The newest run, still open while backupd is running, is the one in progress.
        if status?.running == true, runs.first?.outcome == .unfinished, runs[0].destinationID == nil { runs[0].destinationID = status?.destinationID }

        var ids = p.destinations.map(\.id)
        for i in info ?? [] where !ids.contains(i.id) { ids.append(i.id) }
        r.destinations = ids.map { id in
            let pd = p.destinations.first { $0.id == id }, inf = info?.first { $0.id == id }
            let kind = inf?.kind ?? (pd.map { $0.networkURL != nil ? .network : .local })
            let name = inf?.name ?? pd?.volumeName ?? "Backup disk"
            let saved = store.successes(id)
            // Runs logged for this destination: by the volume UUID in the backup's path, else by the disk name.
            let mine = runs.filter { $0.destinationID == id || ($0.destinationID == nil && $0.destinationName != nil
                                                                 && ($0.destinationName == pd?.volumeName || $0.destinationName == inf?.name)) }
            for k in runs.indices where runs[k].destinationID == nil && mine.contains(where: { $0.start == runs[k].start }) { runs[k].destinationID = id }
            let lastOK = (saved + (pd?.snapshots ?? []) + mine.filter(\.succeeded).compactMap(\.end)).max()
            return BackupDestination(
                id: id, name: name, kind: kind, address: (inf?.url ?? pd?.networkURL).map(redactUser), mountPoint: inf?.mountPoint,
                isLast: p.lastDestinationID == id, backingUpNow: status?.running == true && status?.destinationID == id,
                bytesAvailable: pd?.bytesAvailable, bytesUsed: pd?.bytesUsed, backupsKept: pd?.snapshots.count ?? 0,
                oldestBackup: pd?.snapshots.first, lastSuccess: lastOK, lastAttempt: ([pd?.attempts.last] + [mine.first?.start]).compactMap { $0 }.max(),
                lastResult: pd?.lastResult, encrypted: pd?.encrypted, lastVerified: pd?.lastVerified, space: store.space(id))
        }
        r.runs = runs
        let all = store.allSuccesses + p.destinations.flatMap(\.snapshots) + runs.filter(\.succeeded).compactMap(\.end)
        r.successes = Array(Set(all.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded()) })).sorted()
        r.gapThreshold = BackupParse.gapThreshold(interval: p.interval)
        r.gaps = BackupParse.gaps(successes: r.successes, threshold: r.gapThreshold, window: BackupStore.retention,
                                  thinnedBefore: now.addingTimeInterval(-30 * 86_400), now: now)
        if r.destinations.isEmpty { r.state = prefs == nil && info == nil ? .unknown : .notConfigured }
        else if status?.running == true { r.state = .backingUp }
        else if p.autoBackup == false { r.state = .disabled }
        else if status != nil || prefs != nil { r.state = .idle }
        return r
    }

    /// "smb://user@host/share" → "smb://host/share": the account name isn't needed to recognise the share.
    static func redactUser(_ url: String) -> String {
        guard let at = url.firstIndex(of: "@"), let scheme = url.range(of: "://"), scheme.upperBound <= at else { return url }
        return String(url[..<scheme.upperBound]) + String(url[url.index(after: at)...])
    }
}
