import Foundation

// Backups, part 4: backupd's result names in plain English. Apple doesn't document them; the names are descriptive
// (BACKUP_FAILED_DISCONNECTED_NETWORK), so known ones get a written explanation and anything else is matched by the
// words in its name, falling back to the name itself spelled out. The numeric codes differ between macOS versions, so
// only the names are used.

public struct BackupFailureExplanation: Sendable, Equatable {
    public var title: String
    public var detail: String
    public var fix: String?
}

public enum BackupFailures {
    /// Explanations by result name, then by a word in the name (checked in order).
    static let exact: [String: BackupFailureExplanation] = [
        "BACKUP_FAILED_DISCONNECTED_NETWORK": .init(
            title: "Lost the connection to the network backup disk",
            detail: "The network share holding the backup went away while Time Machine was using it: the Mac slept, changed Wi-Fi networks, or the server or NAS was unreachable.",
            fix: "Keep the Mac awake and on the same network as the backup server until a backup completes; if it keeps happening, check the server is on and not sleeping."),
        "BACKUP_FAILED_COPY_STAGE": .init(
            title: "Copying files failed",
            detail: "Time Machine hit an error while copying changed files. Often a file that changed or vanished mid-copy, or a disk error on either side.",
            fix: "Usually the next backup succeeds. If it repeats, run First Aid on the backup disk in Disk Utility."),
        "BACKUP_CANCELED": .init(
            title: "Cancelled",
            detail: "The backup was stopped before it finished, by you (Skip This Backup), by the Mac going to sleep or shutting down, or by the disk being ejected.",
            fix: nil),
    ]

    static let keywords: [(String, BackupFailureExplanation)] = [
        ("NETWORK", .init(title: "Network backup disk unreachable",
                          detail: "Time Machine couldn't reach the network share holding the backup: the server was off or asleep, or the Mac was on another network.",
                          fix: "Check the server or NAS is on and that this Mac is on its network; you can test it by opening the share in Finder.")),
        ("SPACE", .init(title: "Not enough space on the backup disk",
                        detail: "The backup disk is too full for this backup even after Time Machine deleted the oldest backups it could.",
                        fix: "Use a larger backup disk, exclude large folders you don't need backed up (Time Machine settings › Options), or delete old backups.")),
        ("FULL", .init(title: "The backup disk is full",
                       detail: "There is no room left for this backup even after deleting old ones.",
                       fix: "Use a larger backup disk or exclude large folders in Time Machine settings › Options.")),
        ("NOT_FOUND", .init(title: "Backup disk not found",
                            detail: "The backup disk wasn't connected or couldn't be found when the backup was due.",
                            fix: "Connect the disk (or join the network with the backup server) and choose Back Up Now.")),
        ("UNAVAILABLE", .init(title: "Backup disk unavailable",
                              detail: "The backup disk wasn't available when the backup was due.",
                              fix: "Connect the disk (or join the network with the backup server) and choose Back Up Now.")),
        ("MOUNT", .init(title: "Couldn't open the backup disk",
                        detail: "macOS couldn't mount the backup disk or its disk image. A network share may have rejected the login, or the disk needs repair.",
                        fix: "Open the disk or share in Finder to check it works; run First Aid on it in Disk Utility.")),
        ("AUTH", .init(title: "The backup server rejected the login",
                       detail: "The user name or password saved for the network backup disk didn't work.",
                       fix: "Remove the disk in Time Machine settings and add it again, entering the server's password.")),
        ("PASSWORD", .init(title: "Password needed",
                           detail: "The backup disk is encrypted or protected and its password wasn't available.",
                           fix: "Remove and re-add the disk in Time Machine settings, entering its password.")),
        ("VERIF", .init(title: "Backup verification failed",
                        detail: "Time Machine found the backup unreliable when checking it.",
                        fix: "Time Machine usually offers to start a new backup. Run First Aid on the backup disk, and keep the old disk if you may need its history.")),
        ("CORRUPT", .init(title: "The backup is damaged",
                          detail: "Time Machine found damage in the existing backup.",
                          fix: "Run First Aid on the backup disk; if Time Machine offers to start a new backup, accept it.")),
        ("SNAPSHOT", .init(title: "Couldn't make a snapshot of this Mac",
                           detail: "Time Machine backs up from a local snapshot of the startup disk and couldn't create or read one, often because the startup disk is nearly full.",
                           fix: "Free some space on the startup disk, then back up again.")),
        ("SLEEP", .init(title: "Interrupted by sleep",
                        detail: "The Mac went to sleep during the backup.",
                        fix: "Time Machine continues on the next backup; leave the Mac awake and plugged in to let a long backup finish.")),
        ("CANCEL", .init(title: "Cancelled",
                         detail: "The backup was stopped before it finished.",
                         fix: nil)),
        ("PERMISSION", .init(title: "Permission problem on the backup disk",
                             detail: "Time Machine wasn't allowed to write to the backup disk.",
                             fix: "Run First Aid on the backup disk. A network share must give the backup user write access.")),
        ("ENCRYPT", .init(title: "Encryption problem",
                          detail: "Time Machine couldn't encrypt or unlock the backup disk.",
                          fix: "Check the disk's password in Time Machine settings.")),
    ]

    /// The explanation for a result name such as "BACKUP_FAILED_DISCONNECTED_NETWORK".
    public static func explain(_ name: String) -> BackupFailureExplanation {
        let n = name.uppercased()
        if let e = exact[n] { return e }
        if let (_, e) = keywords.first(where: { n.contains($0.0) }) { return e }
        // "BACKUP_FAILED_SOME_THING" → "Backup failed: some thing".
        let words = n.replacingOccurrences(of: "BACKUP_FAILED_", with: "").replacingOccurrences(of: "BACKUP_", with: "")
            .replacingOccurrences(of: "_", with: " ").lowercased()
        return .init(title: "Backup failed" + (words.isEmpty || words == "failed" ? "" : ": \(words)"),
                     detail: "Time Machine reported \(name), which FlightDeck has no explanation for. Time Machine retries at the next scheduled backup.",
                     fix: "If it keeps failing, check the backup disk in Disk Utility (First Aid) and the Time Machine settings.")
    }

    /// Common reasons, for the page's "why backups fail" panel.
    public static var common: [BackupFailureExplanation] {
        ["BACKUP_FAILED_DISCONNECTED_NETWORK", "NOT_FOUND", "SPACE", "AUTH", "SNAPSHOT", "VERIF", "SLEEP"].map(explain)
    }
}
