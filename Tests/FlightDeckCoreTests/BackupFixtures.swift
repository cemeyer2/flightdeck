import Foundation
// Backups test fixtures, captured on a Mac backing up to a network share and a local disk (macOS 26), then scrubbed:
// host, share, disk names, addresses and UUIDs are replaced. `statusRunning` is not a capture (no backup was running
// when these were taken); it follows the keys `tmutil status -X` prints while copying.

enum BackupFixtures {
    static let netID = "1E000000-0000-4000-8000-0000000000A1", localID = "1E000000-0000-4000-8000-0000000000B2"

    /// backupd's run messages from `log show --style ndjson --info` (trimmed to the fields that are read; most of the
    /// BACKUP_DELAYED lines dropped). Two successes, three failures of the network destination, one success to a
    /// local disk, and a success whose start had already rotated out of the log.
    static let ndjson = #"""
{"timestamp": "2026-11-18 09:55:18.268494-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupEngine", "eventMessage": "Successfully completed backing up 6.78 GB to '/Volumes/.timemachine/5A0C1D2E-0000-4000-8000-00000000A001/2026-11-18-095449.backup/2026-11-18-095449.backup'"}
{"timestamp": "2026-11-18 09:55:23.067366-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupDispatching", "eventMessage": "Backup succeeded\nElapsed time: About 33 minutes"}
{"timestamp": "2026-11-18 14:18:17.569930-0600", "messageType": "Error", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupDispatching", "eventMessage": "Backup failed: BACKUP_DELAYED_NOT_ENOUGH_ELAPSED_TIME (107)"}
{"timestamp": "2026-11-19 06:30:25.111401-0600", "messageType": "Error", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupDispatching", "eventMessage": "Backup failed: BACKUP_DELAYED_NOT_ENOUGH_ELAPSED_TIME (107)"}
{"timestamp": "2026-11-19 06:30:29.524297-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupJob", "eventMessage": "Attempting backup with mode \"automatic backup\""}
{"timestamp": "2026-11-19 06:40:32.798885-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupEngine", "eventMessage": "Backing up 1 volumes to Archive (/dev/disk5s2,TMBackupOptions(rawValue: 1)): /Volumes/Archive"}
{"timestamp": "2026-11-19 11:28:04.427567-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupEngine", "eventMessage": "Successfully completed backing up 7.22 GB to '/Volumes/.timemachine/5A0C1D2E-0000-4000-8000-00000000B002/2026-11-19-112749.backup/2026-11-19-112749.backup'"}
{"timestamp": "2026-11-19 11:28:05.883173-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupDispatching", "eventMessage": "Backup succeeded\nElapsed time: About 5 hours"}
{"timestamp": "2026-11-19 11:45:26.856481-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupJob", "eventMessage": "Attempting backup with mode \"automatic backup\""}
{"timestamp": "2026-11-19 12:11:17.531190-0600", "messageType": "Error", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "ErrorEvaluator", "eventMessage": "Error evaluator wrapped original error as: BACKUP_FAILED_DISCONNECTED_NETWORK (26)\nunderlying error: Error Domain=com.apple.backupd.ErrorDomain Code=21 \"(null)\" UserInfo={DIErrorVerboseInfo=stat failed, NSUnderlyingError=0x600000000000 {Error Domain=NSPOSIXErrorDomain Code=2 \"No such file or directory\" UserInfo={DIErrorVerboseInfo=stat failed}}, MessageParameters=(\n    \"studio.sparsebundle\",\n    2\n)}"}
{"timestamp": "2026-11-19 12:11:17.882364-0600", "messageType": "Error", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupDispatching", "eventMessage": "Backup failed: BACKUP_DELAYED_NOT_ENOUGH_ELAPSED_TIME (107)"}
{"timestamp": "2026-11-19 17:44:05.109003-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupJob", "eventMessage": "Attempting backup with mode \"automatic backup\""}
{"timestamp": "2026-11-19 17:44:36.858905-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupEngine", "eventMessage": "Backing up 1 volumes to Backups of studio (/dev/disk7s1,TMBackupOptions(rawValue: 1)): /Volumes/Backups of studio 1"}
{"timestamp": "2026-11-19 17:50:12.510063-0600", "messageType": "Error", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "ErrorEvaluator", "eventMessage": "Error evaluator wrapped original error as: BACKUP_FAILED_DISCONNECTED_NETWORK (26)\nunderlying error: Error Domain=com.apple.backupd.ErrorDomain Code=22 \"(null)\" UserInfo={BackupdResultParts=Elapsed time: About 6 minutes}"}
{"timestamp": "2026-11-19 17:50:12.543746-0600", "messageType": "Error", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupDispatching", "eventMessage": "Backup failed: BACKUP_DELAYED_NOT_ENOUGH_ELAPSED_TIME (107)"}
{"timestamp": "2026-11-19 19:14:01.729634-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupJob", "eventMessage": "Attempting backup with mode \"automatic backup\""}
{"timestamp": "2026-11-19 19:22:20.748261-0600", "messageType": "Error", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "ErrorEvaluator", "eventMessage": "Error evaluator wrapped original error as: BACKUP_FAILED_DISCONNECTED_NETWORK (26)\nunderlying error: Error Domain=com.apple.backupd.ErrorDomain Code=21 \"(null)\" UserInfo={DIErrorVerboseInfo=stat failed, NSUnderlyingError=0x600000000000 {Error Domain=NSPOSIXErrorDomain Code=2 \"No such file or directory\" UserInfo={DIErrorVerboseInfo=stat failed}}, MessageParameters=(\n    \"studio.sparsebundle\",\n    2\n)}"}
{"timestamp": "2026-11-19 19:22:20.866840-0600", "messageType": "Error", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupDispatching", "eventMessage": "Backup failed: BACKUP_DELAYED_NOT_ENOUGH_ELAPSED_TIME (107)"}
{"timestamp": "2026-11-19 19:40:49.320222-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupJob", "eventMessage": "Attempting backup with mode \"automatic backup\""}
{"timestamp": "2026-11-19 20:01:22.536368-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupEngine", "eventMessage": "Backing up 1 volumes to Backups of studio (/dev/disk7s1,TMBackupOptions(rawValue: 1)): /Volumes/Backups of studio 1"}
{"timestamp": "2026-11-19 20:30:51.178972-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupEngine", "eventMessage": "Successfully completed backing up 5.22 GB to '/Volumes/.timemachine/5A0C1D2E-0000-4000-8000-00000000A001/2026-11-19-203021.backup/2026-11-19-203021.backup'"}
{"timestamp": "2026-11-19 20:30:59.509357-0600", "messageType": "Info", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupDispatching", "eventMessage": "Backup succeeded\nElapsed time: About 30 minutes"}
{"timestamp": "2026-11-19 20:41:46.464529-0600", "messageType": "Error", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupDispatching", "eventMessage": "Backup failed: BACKUP_DELAYED_NOT_ENOUGH_ELAPSED_TIME (107)"}
{"timestamp": "2026-11-19 20:41:51.095836-0600", "messageType": "Error", "eventType": "logEvent", "subsystem": "com.apple.TimeMachine", "category": "BackupDispatching", "eventMessage": "Backup failed: BACKUP_DELAYED_NOT_ENOUGH_ELAPSED_TIME (107)"}
"""#

    /// /Library/Preferences/com.apple.TimeMachine.plist (abridged: fewer SnapshotDates, opaque keys dropped).
    static let prefsPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>AutoBackup</key><integer>1</integer>
        <key>AutoBackupInterval</key><integer>86400</integer>
        <key>Destinations</key>
        <array>
            <dict>
                <key>AttemptDates</key><array><date>2026-11-17T12:54:50Z</date><date>2026-11-19T12:30:29Z</date></array>
                <key>BytesAvailable</key><integer>120979218432</integer>
                <key>BytesUsed</key><integer>879196864512</integer>
                <key>ConsistencyScanDate</key><date>2026-11-16T07:42:27Z</date>
                <key>DestinationID</key><string>1E000000-0000-4000-8000-0000000000B2</string>
                <key>DestinationUUIDs</key><array><string>5A0C1D2E-0000-4000-8000-00000000B002</string></array>
                <key>FilesystemTypeName</key><string>apfs</string>
                <key>LastKnownEncryptionState</key><string>NotEncrypted</string>
                <key>LastKnownVolumeName</key><string>Archive</string>
                <key>RESULT</key><integer>0</integer>
                <key>SnapshotDates</key>
                <array><date>2026-09-29T15:39:46Z</date><date>2026-11-01T02:21:51Z</date><date>2026-11-13T20:45:12Z</date><date>2026-11-19T17:27:49Z</date></array>
            </dict>
            <dict>
                <key>AttemptDates</key><array><date>2025-04-03T03:22:19Z</date><date>2026-11-20T01:40:49Z</date></array>
                <key>BytesAvailable</key><integer>13025987420160</integer>
                <key>BytesUsed</key><integer>2972415180800</integer>
                <key>ConsistencyScanDate</key><date>2026-08-31T03:43:19Z</date>
                <key>DestinationID</key><string>1E000000-0000-4000-8000-0000000000A1</string>
                <key>DestinationUUIDs</key><array><string>5A0C1D2E-0000-4000-8000-00000000A001</string></array>
                <key>LastKnownVolumeName</key><string>Backups of studio</string>
                <key>NetworkURL</key><string>smb://tm@10.0.0.20/tm_share</string>
                <key>RESULT</key><integer>26</integer>
                <key>SnapshotDates</key>
                <array><date>2026-10-06T19:02:26Z</date><date>2026-10-19T15:45:58Z</date><date>2026-11-18T15:54:49Z</date><date>2026-11-20T02:30:21Z</date></array>
            </dict>
        </array>
        <key>LastDestinationID</key><string>1E000000-0000-4000-8000-0000000000A1</string>
    </dict>
    </plist>
    """

    /// `tmutil destinationinfo -X`.
    static let destinationInfo = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Destinations</key>
        <array>
            <dict>
                <key>Kind</key><string>Network</string>
                <key>URL</key><string>smb://tm@10.0.0.20/tm_share</string>
                <key>Name</key><string>tm_share</string>
                <key>ID</key><string>1E000000-0000-4000-8000-0000000000A1</string>
                <key>LastDestination</key><integer>1</integer>
            </dict>
            <dict>
                <key>Kind</key><string>Local</string>
                <key>ID</key><string>1E000000-0000-4000-8000-0000000000B2</string>
                <key>Name</key><string>Archive</string>
                <key>MountPoint</key><string>/Volumes/Archive</string>
            </dict>
        </array>
    </dict>
    </plist>
    """

    /// `tmutil status -X` while idle (captured).
    static let statusIdle = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>ClientID</key><string>com.apple.backupd</string>
        <key>Percent</key><real>-1</real>
        <key>Running</key><false/>
    </dict>
    </plist>
    """

    /// `tmutil status -X` while copying (reconstructed; see the header).
    static let statusRunning = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>BackupPhase</key><string>Copying</string>
        <key>ClientID</key><string>com.apple.backupd</string>
        <key>DestinationID</key><string>1E000000-0000-4000-8000-0000000000A1</string>
        <key>DestinationMountPoint</key><string>/Volumes/Backups of studio</string>
        <key>Percent</key><real>0.42</real>
        <key>Progress</key>
        <dict>
            <key>Percent</key><real>0.42</real>
            <key>TimeRemaining</key><integer>780</integer>
            <key>bytes</key><integer>2190000000</integer>
            <key>files</key><integer>8204</integer>
            <key>totalBytes</key><integer>5220000000</integer>
            <key>totalFiles</key><integer>28144</integer>
        </dict>
        <key>Running</key><true/>
        <key>Stopping</key><integer>0</integer>
    </dict>
    </plist>
    """

    /// `tmutil destinationinfo` with nothing configured.
    static let noDestinations = "tmutil: No destinations configured.\n"
}
