// Demo mode's Backups page: an invented NAS share ("Backups on HomeVault") backed up daily for five weeks, with a
// six-day gap (a trip away from home) and one failed run when the Wi-Fi dropped, an invented travel SSD used weekly,
// and a backup to the NAS in progress. Nothing comes from this Mac: the invented settings, tmutil output and log
// messages go through the real report builder, so the page shows what it would for such a history.
import Foundation
import FlightDeckCore

enum DemoBackups {
    static let nasID = "D3M0D3M0-0000-4000-8000-00000000AA01", ssdID = "D3M0D3M0-0000-4000-8000-00000000BB02"
    static let nasVolume = "D3M0D3M0-0000-4000-8000-0000000A0001", ssdVolume = "D3M0D3M0-0000-4000-8000-0000000B0002"

    static func report(now: Date = Date()) -> BackupsReport {
        let day = 86_400.0, gb: Int64 = 1_000_000_000
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var events: [BackupLogEvent] = []
        var nas: [Date] = [], ssd: [Date] = []
        func run(_ start: Date, minutes: Double, name: String, volume: String, bytes: Int64) {
            let copy = start.addingTimeInterval(40), end = start.addingTimeInterval(minutes * 60)
            events += [BackupLogEvent(time: start, kind: .attempt, text: "automatic backup"),
                       BackupLogEvent(time: copy, kind: .copying, text: name),
                       BackupLogEvent(time: end.addingTimeInterval(-6), kind: .completed, number: bytes, volumeUUID: volume),
                       BackupLogEvent(time: end, kind: .succeeded, elapsed: "About \(Int(minutes.rounded())) minutes")]
        }
        // Daily NAS backups at ~13:xx for 35 days, except days 17–12 ago (away from home).
        for k in stride(from: 35, through: 1, by: -1) where !(12...17).contains(k) {
            let start = today.addingTimeInterval(-Double(k) * day + 13 * 3600 + Double(k % 7) * 420)
            if k == 3 {
                // The Wi-Fi dropped mid-copy; the retry two hours later succeeded.
                events += [BackupLogEvent(time: start, kind: .attempt, text: "automatic backup"),
                           BackupLogEvent(time: start.addingTimeInterval(35), kind: .copying, text: "Backups on HomeVault"),
                           BackupLogEvent(time: start.addingTimeInterval(11 * 60), kind: .failed, text: "BACKUP_FAILED_DISCONNECTED_NETWORK",
                                          number: 26, elapsed: "About 11 minutes")]
                let retry = start.addingTimeInterval(2 * 3600)
                run(retry, minutes: 24, name: "Backups on HomeVault", volume: nasVolume, bytes: 3 * gb)
                nas.append(retry.addingTimeInterval(24 * 60))
                continue
            }
            let minutes = 9 + Double((k * 7) % 23), bytes = Int64(400 + (k * 389) % 4100) * 1_000_000
            // The first backup after the trip copied six days of changes.
            run(start, minutes: k == 11 ? 68 : minutes, name: "Backups on HomeVault", volume: nasVolume, bytes: k == 11 ? 14 * gb : bytes)
            nas.append(start.addingTimeInterval((k == 11 ? 68 : minutes) * 60))
        }
        // The travel SSD, plugged in about once a week in the evening.
        for k in [33, 26, 19, 8, 2] {
            let start = today.addingTimeInterval(-Double(k) * day + 20 * 3600)
            run(start, minutes: 18 + Double(k % 5) * 3, name: "Travel SSD", volume: ssdVolume, bytes: Int64(2 + k % 4) * gb)
            ssd.append(start.addingTimeInterval((18 + Double(k % 5) * 3) * 60))
        }
        // The backup in progress, to the NAS.
        let current = now.addingTimeInterval(-14 * 60)
        events += [BackupLogEvent(time: current, kind: .attempt, text: "automatic backup"),
                   BackupLogEvent(time: current.addingTimeInterval(30), kind: .copying, text: "Backups on HomeVault")]

        let store = BackupStore(dir: nil)
        store.add(events: events, scannedTo: now.addingTimeInterval(-60))
        func prefs(nasFree: UInt64) -> TimeMachinePrefs {
            TimeMachinePrefs(autoBackup: true, interval: day, destinations: [
                .init(id: nasID, volumeName: "Backups on HomeVault", networkURL: "smb://homevault.local/TimeMachine",
                      bytesAvailable: nasFree, bytesUsed: 3_200_000_000_000 - nasFree, snapshots: nas, attempts: [current],
                      lastResult: 0, lastVerified: today.addingTimeInterval(-9 * day + 14 * 3600), volumeUUIDs: [nasVolume]),
                .init(id: ssdID, volumeName: "Travel SSD", bytesAvailable: 612_400_000_000, bytesUsed: 387_600_000_000,
                      snapshots: ssd, attempts: ssd, lastResult: 0, encrypted: true, lastVerified: ssd.last, volumeUUIDs: [ssdVolume]),
            ], lastDestinationID: nasID)
        }
        // Free space on the NAS, falling about 9 GB a day (FlightDeck saw it every few hours).
        for k in stride(from: 30, through: 0, by: -1) {
            store.note(prefs: prefs(nasFree: 1_420_000_000_000 - UInt64(30 - k) * 9_000_000_000), at: now.addingTimeInterval(-Double(k) * day))
        }
        let info = [TMDestinationInfo(id: nasID, name: "TimeMachine on HomeVault", kind: .network, url: "smb://homevault.local/TimeMachine"),
                    TMDestinationInfo(id: ssdID, name: "Travel SSD", kind: .local, mountPoint: nil)]
        let status = BackupStatusNow(running: true, phase: "Copying", fraction: 0.63, bytesCopied: 1_840_000_000, totalBytes: 2_920_000_000,
                                     filesCopied: 6_212, totalFiles: 9_870, timeRemaining: 6 * 60, destinationID: nasID,
                                     destinationMount: "/Volumes/Backups on HomeVault")
        let snaps = [-23.0, -15, -7, -1].map { h -> LocalSnapshot in
            LocalSnapshot(name: "com.apple.TimeMachine.demo-\(Int(-h)).local", kind: .timeMachine, date: now.addingTimeInterval(h * 3600))
        } + [LocalSnapshot(name: "com.apple.os.update-DEMO", kind: .osUpdate, date: nil)]
        var r = BackupsReport.build(prefs: prefs(nasFree: 1_150_000_000_000), info: info, status: status, store: store, snapshots: snaps, now: now)
        r.watchingSince = now.addingTimeInterval(-36 * day)
        return r
    }
}
