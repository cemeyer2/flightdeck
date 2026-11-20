import Foundation

// Backups (Time Machine), part 1: the values the page, the MCP tool and the gap finding share. Parsing is in
// BackupParse.swift and BackupLog.swift, persistence in BackupStore.swift, the I/O in BackupsCollector.swift.
//
// What works without root or Full Disk Access (checked on macOS 26 with Time Machine backing up to a network share and
// a local disk):
// - /Library/Preferences/com.apple.TimeMachine.plist is world-readable: per destination the completed backup dates
//   (SnapshotDates, the same list `tmutil listbackups` prints, after Time Machine's thinning: hourly for a day, daily
//   for a month, weekly after that), attempt dates, bytes used and free, last result code, encryption state and the
//   last verification date. Readable while the backup disk is disconnected, and reading it mounts nothing.
// - `tmutil destinationinfo -X` (kind, share/volume name, mount point) and `tmutil status -X` (running, phase,
//   progress) need no special access and return in milliseconds.
// - `tmutil listbackups` / `latestbackup` need Full Disk Access and may mount a network backup disk, so FlightDeck
//   doesn't use them here (the plist has the same dates).
// - The unified log has each run's start, destination, size copied, outcome and elapsed time, but backupd logs them at
//   the Info level, which macOS keeps only a day or two. FlightDeck saves what it finds (BackupStore), so the history
//   of durations, sizes and failures grows while it runs.
// - Local snapshots: `tmutil listlocalsnapshots /` lists them; their sizes need root, so they are shown as unknown.

/// Time Machine's settings and per-destination bookkeeping from its preferences plist.
public struct TimeMachinePrefs: Sendable, Equatable {
    public var autoBackup: Bool?
    /// Seconds between automatic backups (3600 hourly by default; 86400 daily, 604800 weekly). Nil when not set.
    public var interval: TimeInterval?
    public var destinations: [Destination]
    public var lastDestinationID: String?

    public struct Destination: Sendable, Equatable, Identifiable {
        public var id: String
        public var volumeName: String?
        public var networkURL: String?
        public var bytesAvailable: UInt64?
        public var bytesUsed: UInt64?
        /// Completed backups still on the disk, oldest first.
        public var snapshots: [Date]
        public var attempts: [Date]
        /// The last run's result code (0 = success). backupd's codes are undocumented.
        public var lastResult: Int?
        public var encrypted: Bool?
        public var lastVerified: Date?
        /// The UUIDs of the backup volumes, which appear in backup paths in the log.
        public var volumeUUIDs: [String]
        public init(id: String, volumeName: String? = nil, networkURL: String? = nil, bytesAvailable: UInt64? = nil, bytesUsed: UInt64? = nil,
                    snapshots: [Date] = [], attempts: [Date] = [], lastResult: Int? = nil, encrypted: Bool? = nil, lastVerified: Date? = nil,
                    volumeUUIDs: [String] = []) {
            self.id = id; self.volumeName = volumeName; self.networkURL = networkURL; self.bytesAvailable = bytesAvailable
            self.bytesUsed = bytesUsed; self.snapshots = snapshots; self.attempts = attempts; self.lastResult = lastResult
            self.encrypted = encrypted; self.lastVerified = lastVerified; self.volumeUUIDs = volumeUUIDs
        }
    }

    public init(autoBackup: Bool? = nil, interval: TimeInterval? = nil, destinations: [Destination] = [], lastDestinationID: String? = nil) {
        self.autoBackup = autoBackup; self.interval = interval; self.destinations = destinations; self.lastDestinationID = lastDestinationID
    }

    /// The newest completed backup on any destination.
    public var latestBackup: Date? { destinations.flatMap(\.snapshots).max() }
}

/// One destination from `tmutil destinationinfo -X`.
public struct TMDestinationInfo: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case network = "Network", local = "Local" }
    public var id: String
    public var name: String
    public var kind: Kind?
    public var url: String?
    public var mountPoint: String?
    public init(id: String, name: String, kind: Kind?, url: String? = nil, mountPoint: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.url = url; self.mountPoint = mountPoint
    }
}

/// `tmutil status -X`: what backupd is doing right now.
public struct BackupStatusNow: Sendable, Equatable, Codable {
    public var running: Bool
    /// backupd's phase name ("Copying", "ThinningPostBackup", …).
    public var phase: String?
    /// 0…1, nil when not reported (backupd reports -1 before it has an estimate).
    public var fraction: Double?
    public var bytesCopied: UInt64?
    public var totalBytes: UInt64?
    public var filesCopied: Int?
    public var totalFiles: Int?
    public var timeRemaining: TimeInterval?
    public var destinationID: String?
    public var destinationMount: String?
    public init(running: Bool, phase: String? = nil, fraction: Double? = nil, bytesCopied: UInt64? = nil, totalBytes: UInt64? = nil,
                filesCopied: Int? = nil, totalFiles: Int? = nil, timeRemaining: TimeInterval? = nil, destinationID: String? = nil, destinationMount: String? = nil) {
        self.running = running; self.phase = phase; self.fraction = fraction; self.bytesCopied = bytesCopied; self.totalBytes = totalBytes
        self.filesCopied = filesCopied; self.totalFiles = totalFiles; self.timeRemaining = timeRemaining
        self.destinationID = destinationID; self.destinationMount = destinationMount
    }

    /// "Copying", "Preparing", "Finding changes", … in plain English.
    public var phaseTitle: String {
        guard let phase else { return running ? "Backing up" : "Idle" }
        let known: [String: String] = [
            "Starting": "Starting", "MountingBackupVol": "Connecting to the backup disk", "MountingBackupVolForHealthCheck": "Checking the backup disk",
            "MountingDiskImage": "Opening the backup disk image", "PreparingSourceVolumes": "Preparing", "FindingChanges": "Finding changes",
            "FindingBackupVol": "Looking for the backup disk", "Copying": "Copying", "ThinningPreBackup": "Making room (deleting old backups)",
            "ThinningPostBackup": "Cleaning up old backups", "Finishing": "Finishing", "HealthCheckFsck": "Verifying the backup disk",
            "HealthCheckCopyHFSMeta": "Verifying the backup disk", "SizingChanges": "Sizing changes", "Stopping": "Stopping",
        ]
        if let k = known[phase] { return k }
        // Unknown phases: split the CamelCase name ("LazyThinning" → "Lazy thinning").
        var out = ""
        for (i, c) in phase.enumerated() { if c.isUppercase && i > 0 { out += " " + c.lowercased() } else { out.append(c) } }
        return out
    }
}

/// One Time Machine run, rebuilt from saved log events.
public struct BackupRun: Sendable, Hashable, Codable, Identifiable {
    public enum Outcome: Sendable, Hashable, Codable {
        case succeeded
        /// backupd's result name (e.g. "BACKUP_FAILED_DISCONNECTED_NETWORK") and code.
        case failed(name: String, code: Int?)
        /// Started but no outcome logged (still running, or the log rotated before it ended).
        case unfinished
    }
    public var id: Date { start }
    /// "Attempting backup" (the attempt can wait for the disk before copying starts).
    public var start: Date
    /// "Backing up N volumes to …": copying began.
    public var copyStart: Date?
    public var end: Date?
    /// The backup disk's name as backupd logged it.
    public var destinationName: String?
    /// Matched through the backup volume UUID in the completed backup's path, when the plist knows it.
    public var destinationID: String?
    /// "Successfully completed backing up 7.22 GB": what this run copied.
    public var bytesCopied: UInt64?
    /// backupd's own rounded elapsed time ("About 33 minutes").
    public var elapsedText: String?
    public var mode: String?
    public var outcome: Outcome
    /// False when the log had rotated past the run's start (its first saved message was later), so its duration is unknown.
    public var startSeen = true
    public init(start: Date, copyStart: Date? = nil, end: Date? = nil, destinationName: String? = nil, destinationID: String? = nil,
                bytesCopied: UInt64? = nil, elapsedText: String? = nil, mode: String? = nil, outcome: Outcome) {
        self.start = start; self.copyStart = copyStart; self.end = end; self.destinationName = destinationName
        self.destinationID = destinationID; self.bytesCopied = bytesCopied; self.elapsedText = elapsedText; self.mode = mode; self.outcome = outcome
    }
    public var duration: TimeInterval? { startSeen ? end.map { $0.timeIntervalSince(start) } : nil }
    public var succeeded: Bool { outcome == .succeeded }
}

/// A stretch with no successful backup to any destination.
public struct BackupGap: Sendable, Hashable, Codable {
    /// The last successful backup before the gap (nil: none known).
    public var from: Date?
    /// The next successful backup, or nil while the gap is still open.
    public var to: Date?
    public var length: TimeInterval
    public var ongoing: Bool { to == nil }
    public init(from: Date?, to: Date?, length: TimeInterval) { self.from = from; self.to = to; self.length = length }
}

/// Free space on a destination as FlightDeck saw it over time (one point per change, at most every few hours).
public struct BackupSpacePoint: Sendable, Hashable, Codable {
    public var time: Date
    public var available: UInt64
    public var used: UInt64?
    public init(time: Date, available: UInt64, used: UInt64?) { self.time = time; self.available = available; self.used = used }
}
