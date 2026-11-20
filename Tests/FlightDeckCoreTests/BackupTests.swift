import XCTest
@testable import FlightDeckCore

/// Backups page: Time Machine's plist, tmutil output and backupd's log messages, from fixtures (CI has no Time Machine).
final class BackupTests: XCTestCase {
    typealias F = BackupFixtures

    func prefs() throws -> TimeMachinePrefs {
        let d = try XCTUnwrap(BackupParse.plist(Data(F.prefsPlist.utf8)))
        return BackupParse.prefs(d)
    }
    func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    func store() -> BackupStore {
        let s = BackupStore(dir: nil)
        s.add(events: BackupLog.parse(ndjson: F.ndjson), scannedTo: iso("2026-11-20T03:00:00Z"))
        return s
    }

    func testPrefs() throws {
        let p = try prefs()
        XCTAssertEqual(p.autoBackup, true); XCTAssertEqual(p.interval, 86_400); XCTAssertEqual(p.lastDestinationID, F.netID)
        XCTAssertEqual(p.destinations.map(\.id), [F.localID, F.netID])
        let local = p.destinations[0], net = p.destinations[1]
        XCTAssertEqual(local.volumeName, "Archive"); XCTAssertNil(local.networkURL); XCTAssertEqual(local.encrypted, false)
        XCTAssertEqual(net.networkURL, "smb://tm@10.0.0.20/tm_share"); XCTAssertNil(net.encrypted); XCTAssertEqual(net.lastResult, 26)
        XCTAssertEqual(net.bytesAvailable, 13_025_987_420_160); XCTAssertEqual(net.snapshots.count, 4)
        XCTAssertEqual(net.volumeUUIDs, ["5A0C1D2E-0000-4000-8000-00000000A001"])
        XCTAssertEqual(p.latestBackup, iso("2026-11-20T02:30:21Z"))
        // Checkup's reader shares the parser and keeps its behaviour.
        let tm = CheckupParse.timeMachine(try XCTUnwrap(BackupParse.plist(Data(F.prefsPlist.utf8))))
        XCTAssertEqual(tm, CheckupParse.TimeMachine(autoBackup: true, destinations: 2, latest: iso("2026-11-20T02:30:21Z")))
        // Missing keys stay unknown, not 0.
        let empty = BackupParse.prefs(["Destinations": [["DestinationID": "X"]]])
        XCTAssertNil(empty.autoBackup); XCTAssertNil(empty.interval); XCTAssertNil(empty.destinations[0].bytesAvailable)
    }

    func testDestinationInfoAndStatus() throws {
        let info = try XCTUnwrap(BackupParse.destinationInfo(F.destinationInfo))
        XCTAssertEqual(info.map(\.kind), [.network, .local]); XCTAssertEqual(info[0].name, "tm_share"); XCTAssertEqual(info[1].mountPoint, "/Volumes/Archive")
        XCTAssertEqual(BackupParse.destinationInfo(F.noDestinations), [])
        XCTAssertNil(BackupParse.destinationInfo("tmutil: something went wrong"))

        let idle = try XCTUnwrap(BackupParse.status(F.statusIdle))
        XCTAssertFalse(idle.running); XCTAssertNil(idle.fraction); XCTAssertEqual(idle.phaseTitle, "Idle")
        let run = try XCTUnwrap(BackupParse.status(F.statusRunning))
        XCTAssertTrue(run.running); XCTAssertEqual(run.fraction ?? 0, 0.42, accuracy: 1e-9); XCTAssertEqual(run.phaseTitle, "Copying")
        XCTAssertEqual(run.bytesCopied, 2_190_000_000); XCTAssertEqual(run.totalBytes, 5_220_000_000); XCTAssertEqual(run.timeRemaining, 780)
        XCTAssertEqual(run.destinationID, F.netID)
        XCTAssertEqual(BackupStatusNow(running: true, phase: "LazyThinning").phaseTitle, "Lazy thinning")
        XCTAssertNil(BackupParse.status("not a plist"))
    }

    func testLogRuns() {
        let events = BackupLog.parse(ndjson: F.ndjson)
        XCTAssertFalse(events.contains { $0.text?.hasPrefix("BACKUP_DELAYED") == true }, "scheduler delays aren't runs")
        let ids = ["5A0C1D2E-0000-4000-8000-00000000A001": F.netID, "5A0C1D2E-0000-4000-8000-00000000B002": F.localID]
        let runs = BackupLog.runs(events, volumeIDs: ids)
        XCTAssertEqual(runs.count, 6)
        let last = runs[0]
        XCTAssertEqual(last.outcome, .succeeded); XCTAssertEqual(last.destinationName, "Backups of studio"); XCTAssertEqual(last.destinationID, F.netID)
        XCTAssertEqual(last.bytesCopied, 5_220_000_000); XCTAssertEqual(last.elapsedText, "About 30 minutes")
        XCTAssertEqual(last.duration ?? 0, 50 * 60 + 10, accuracy: 2)   // attempt 19:40:49 → succeeded 20:30:59
        XCTAssertEqual(runs[1].outcome, .failed(name: "BACKUP_FAILED_DISCONNECTED_NETWORK", code: 26))
        XCTAssertEqual(runs[2].elapsedText, "About 6 minutes"); XCTAssertEqual(runs[2].destinationName, "Backups of studio")
        XCTAssertEqual(runs[4].destinationID, F.localID); XCTAssertEqual(runs[4].bytesCopied, 7_220_000_000)
        // The oldest run's start had rotated out of the log: its duration is unknown, not 5 seconds.
        XCTAssertEqual(runs[5].outcome, .succeeded); XCTAssertFalse(runs[5].startSeen); XCTAssertNil(runs[5].duration)
        XCTAssertEqual(BackupLog.event(time: Date(), message: "Successfully completed backing up 512 KB to '/x'")?.number, 512_000)
    }

    func testFailureExplanations() {
        XCTAssertEqual(BackupFailures.explain("BACKUP_FAILED_DISCONNECTED_NETWORK").title, "Lost the connection to the network backup disk")
        XCTAssertEqual(BackupFailures.explain("BACKUP_FAILED_NOT_ENOUGH_SPACE").title, "Not enough space on the backup disk")
        XCTAssertEqual(BackupFailures.explain("BACKUP_FAILED_ODD_THING").title, "Backup failed: odd thing")
        XCTAssertEqual(BackupFailures.common.count, 7)
    }

    func testGaps() {
        let now = iso("2026-11-20T00:00:00Z"), day = 86_400.0
        let s = [-40, -38, -20, -19, -18, -8, -7].map { now.addingTimeInterval($0 * day) }
        let gaps = BackupParse.gaps(successes: s, threshold: 3 * day, window: 90 * day, thinnedBefore: now.addingTimeInterval(-30 * day), now: now)
        // -38 → -20 (18 days), -18 → -8 (10 days), and the open 7 days; -40 → -38 is under the threshold.
        XCTAssertEqual(gaps.map { Int($0.length / day) }, [18, 10, 7])
        XCTAssertTrue(gaps[2].ongoing)
        // A 5-day gap that ended before the cut may be thinning: not reported.
        let thinned = BackupParse.gaps(successes: [-50, -45, -1].map { now.addingTimeInterval($0 * day) }, threshold: 3 * day,
                                       window: 90 * day, thinnedBefore: now.addingTimeInterval(-30 * day), now: now)
        XCTAssertEqual(thinned.map { Int($0.length / day) }, [44])
        XCTAssertEqual(BackupParse.gapThreshold(interval: 3600), 3 * day)
        XCTAssertEqual(BackupParse.gapThreshold(interval: 7 * day), 21 * day)
    }

    func testReportAndFinding() throws {
        let p = try prefs(), info = BackupParse.destinationInfo(F.destinationInfo), st = store()
        let now = iso("2026-11-20T03:00:00Z")
        let r = BackupsReport.build(prefs: p, info: info, status: BackupParse.status(F.statusIdle), store: st, snapshots: [], now: now)
        XCTAssertEqual(r.state, .idle)
        let net = try XCTUnwrap(r.destinations.first { $0.id == F.netID })
        XCTAssertEqual(net.name, "tm_share"); XCTAssertEqual(net.kind, .network); XCTAssertTrue(net.isLast)
        XCTAssertEqual(net.address, "smb://10.0.0.20/tm_share", "the account name is dropped")
        XCTAssertEqual(net.lastSuccess?.timeIntervalSince1970 ?? 0, iso("2026-11-20T02:30:59Z").timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(r.failures.count, 3)
        XCTAssertNil(r.ongoingGap); XCTAssertTrue(BackupFindings.evaluate(r, now: now).isEmpty)

        let later = now.addingTimeInterval(10.5 * 86_400)
        let r2 = BackupsReport.build(prefs: p, info: info, status: nil, store: st, snapshots: nil, now: later)
        let f = BackupFindings.evaluate(r2, now: later)
        XCTAssertEqual(f.count, 1); XCTAssertEqual(f.first?.id, "backup-gap"); XCTAssertEqual(f.first?.severity, .caution)
        XCTAssertEqual(f.first?.title, "No successful Time Machine backup for 10 days")
        XCTAssertEqual(f.first?.destination, BackupFindings.destination)

        var off = p; off.autoBackup = false
        let r3 = BackupsReport.build(prefs: off, info: info, status: nil, store: st, snapshots: nil, now: later)
        XCTAssertEqual(r3.state, .disabled); XCTAssertTrue(BackupFindings.evaluate(r3, now: later).isEmpty)
        let none = BackupsReport.build(prefs: TimeMachinePrefs(), info: [], status: nil, store: BackupStore(dir: nil), snapshots: nil, now: later)
        XCTAssertEqual(none.state, .notConfigured); XCTAssertTrue(BackupFindings.evaluate(none, now: later).isEmpty)

        let running = BackupsReport.build(prefs: p, info: info, status: BackupParse.status(F.statusRunning), store: st, snapshots: nil, now: now)
        XCTAssertEqual(running.state, .backingUp); XCTAssertEqual(running.destinations.first { $0.backingUpNow }?.id, F.netID)
    }

    func testStorePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = iso("2026-11-20T03:00:00Z")
        let s = BackupStore(dir: dir)
        let events = BackupLog.parse(ndjson: F.ndjson)
        s.add(events: events, scannedTo: now)
        s.add(events: events, scannedTo: now)   // an overlapping scan adds nothing
        XCTAssertEqual(s.events.count, events.count)
        s.note(prefs: try prefs(), at: now)
        s.note(prefs: try prefs(), at: now.addingTimeInterval(3600))   // unchanged: no new point
        s.save(now: now)
        let back = BackupStore(dir: dir)
        XCTAssertEqual(back.events.count, events.count); XCTAssertEqual(back.logScannedTo, now)
        XCTAssertEqual(back.space(F.netID).count, 1); XCTAssertEqual(back.successes(F.localID).count, 4)
        XCTAssertNotNil(back.watchingSince)
        // Read-only stores never write.
        let ro = BackupStore(dir: dir, readOnly: true); ro.add(events: [], scannedTo: now.addingTimeInterval(99)); ro.save(now: now)
        XCTAssertEqual(BackupStore(dir: dir).logScannedTo, now)
    }

    func testMCPOutput() throws {
        let now = iso("2026-11-20T03:00:00Z")
        let r = BackupsReport.build(prefs: try prefs(), info: BackupParse.destinationInfo(F.destinationInfo), status: BackupParse.status(F.statusRunning),
                                    store: store(), snapshots: nil, now: now)
        let j = MCPTools.backupsJSON(r, days: 30, now: now)
        XCTAssertEqual(j["state"]?.string, "Backing up")
        XCTAssertEqual(j["status_now"]?["phase"]?.string, "Copying")
        XCTAssertEqual(j["destinations"]?.array?.count, 2)
        let runs = try XCTUnwrap(j["runs"]?.array)
        XCTAssertEqual(runs.count, 6)
        XCTAssertEqual(runs[1]["reason"]?["code"]?.string, "BACKUP_FAILED_DISCONNECTED_NETWORK")
        XCTAssertNil(runs[5]["started"], "a start that rotated out of the log isn't invented")
        XCTAssertEqual(j["local_snapshots"]?.string?.hasPrefix("unavailable"), true)
        XCTAssertTrue(j["summary"]?.string?.contains("3 failed runs") ?? false)
    }
}
