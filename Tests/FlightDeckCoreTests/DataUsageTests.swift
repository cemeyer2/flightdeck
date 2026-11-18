// Tests for per-app daily data usage: the byte counter (restarts, counter resets, nettop gaps), the DailyLog rollup
// across midnight and relaunches, old daily-log files decoding, and the report's ranges and "unusual" flags.
import XCTest
@testable import FlightDeckCore

final class DataUsageTests: XCTestCase {
    /// 2026-01-01 00:00 UTC.
    let t0 = Date(timeIntervalSince1970: 1_767_225_600)
    let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    func proc(_ name: String, pid: Int32, start: UInt64 = 1, totalIn: UInt64?, totalOut: UInt64 = 0) -> ProcessSample {
        var p = BlackBoxTests.base.processes[0]; p.restricted = false
        p.identity = ProcessIdentity(pid: pid, startTime: start)
        p.name = name; p.path = "/Applications/\(name).app/Contents/MacOS/\(name)"
        p.network = totalIn.map { ProcessNetwork(inBps: 0, outBps: 0, totalIn: $0, totalOut: totalOut, connections: 0) }
        return p
    }

    func pass(_ c: inout NetUsageCounter, _ procs: [ProcessSample]) -> [String: NetUsageCounter.Delta]? {
        c.pass(procs, keys: AppUsage.groupKeys(procs))
    }

    func testCounterDeltasRestartsAndGaps() {
        var c = NetUsageCounter()
        let app = "/Applications/Browser.app"
        // First sight counts from zero: the sampler's totals start when FlightDeck starts watching.
        XCTAssertEqual(pass(&c, [proc("Browser", pid: 10, totalIn: 1000, totalOut: 100)])?[app]?.bytesIn, 1000)
        XCTAssertEqual(pass(&c, [proc("Browser", pid: 10, totalIn: 1500, totalOut: 100)])?[app], .init(name: "Browser", bytesIn: 500, bytesOut: 0))
        // nettop unavailable: nothing counted, baselines kept, so the next pass picks up the traffic in between.
        XCTAssertNil(pass(&c, [proc("Browser", pid: 10, totalIn: nil)]))
        XCTAssertEqual(pass(&c, [proc("Browser", pid: 10, totalIn: 2000, totalOut: 100)])?[app]?.bytesIn, 500)
        // The app restarted: a new process (new start time) with its own counter from zero, same app row.
        XCTAssertEqual(pass(&c, [proc("Browser", pid: 10, start: 2, totalIn: 300)])?[app]?.bytesIn, 300)
        // A counter going down for the same identity restarted from zero: its whole value is new.
        XCTAssertEqual(pass(&c, [proc("Browser", pid: 10, start: 2, totalIn: 120)])?[app]?.bytesIn, 120)
        // Helpers roll up to their app; idle processes produce no row; exited ones leave `prev`.
        var helper = proc("Browser", pid: 11, totalIn: 50); helper.path = "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        let d = pass(&c, [proc("Browser", pid: 10, start: 2, totalIn: 120), helper, proc("Idle", pid: 12, totalIn: 0)])
        XCTAssertEqual(d?[app]?.bytesIn, 50); XCTAssertNil(d?["/Applications/Idle.app"])
        XCTAssertEqual(c.prev.count, 3)
        _ = pass(&c, [proc("Idle", pid: 12, totalIn: 0)])
        XCTAssertEqual(c.prev.count, 1)
    }

    func snap(_ t: Date, _ procs: [ProcessSample]) -> Snapshot {
        var s = BlackBoxTests.base
        s.time = t; s.processes = procs; s.cpu.total = .value(5); s.power.powerSource = "AC Power"; s.power.battery = nil
        return s
    }

    /// 10 s samples: bytes go to the day of the pass that saw them; after midnight a new day starts; a relaunch the
    /// same day (new DailyLog, sampler totals from zero) continues the saved day.
    func testDailyRollupAcrossMidnightAndRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = DailyLog(dir: dir, calendar: utc, osVersion: "26.1", osBuild: "x")
        let start = t0.addingTimeInterval(86_400 - 60)   // 23:59:00
        for i in 0...12 {   // until 00:01:00, +1 MB in / 0.1 MB out per 10 s
            l.ingest(snap(start.addingTimeInterval(Double(i) * 10), [proc("Browser", pid: 10, totalIn: UInt64(i) * 1_000_000, totalOut: UInt64(i) * 100_000)]))
        }
        var h = l.history()
        XCTAssertEqual(h.days.count, 2)
        let d1 = try XCTUnwrap(h.days[0].dataUsage), d2 = try XCTUnwrap(h.days[1].dataUsage)
        XCTAssertEqual(d1.apps.first?.bytesIn, 5_000_000, "passes at 23:59:10…23:59:50")
        XCTAssertEqual(d2.apps.first?.bytesIn, 7_000_000, "passes at 00:00:00…00:01:00")
        XCTAssertEqual(d1.total + d2.total, 13_200_000, "nothing lost or double-counted at midnight")
        XCTAssertEqual(d2.firstCounted, t0.addingTimeInterval(86_400))
        l.flush()
        // Relaunch: the saved open day continues; the new sampler's totals start from zero again.
        let l2 = DailyLog(dir: dir, calendar: utc, osVersion: "26.1", osBuild: "x")
        l2.ingest(snap(t0.addingTimeInterval(86_400 + 3600), [proc("Browser", pid: 99, totalIn: 2_000_000)]))
        h = l2.history()
        XCTAssertEqual(h.days.count, 2)
        XCTAssertEqual(h.days[1].dataUsage?.apps.first?.bytesIn, 9_000_000)
        XCTAssertEqual(h.days[0].dataUsage?.apps.first?.bytesIn, 5_000_000, "closed day kept")
    }

    /// No network data at all → the day has no dataUsage (not counted), rather than zeros.
    func testUncountedDayIsNil() {
        let l = DailyLog(dir: nil, calendar: utc, osVersion: "26.1", osBuild: "x")
        for i in 0..<5 { l.ingest(snap(t0.addingTimeInterval(Double(i) * 10), [proc("Browser", pid: 10, totalIn: nil)])) }
        XCTAssertNil(l.history().days.last?.dataUsage)
    }

    /// A daily-log.json written before data usage existed still loads.
    func testOldDailyLogDecodes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = #"{"version":1,"days":[{"day":"2026-01-01","start":1767225600,"observedSeconds":3600,"cpuAverage":12,"apps":[{"id":"proc:x","name":"x","cpuSeconds":5,"peakMemory":10,"memorySeconds":0,"runningSeconds":60}]}]}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("daily-log.json"))
        let l = DailyLog(dir: dir, calendar: utc, osVersion: "26.1", osBuild: "x")
        let d = try XCTUnwrap(l.history().days.first)
        XCTAssertEqual(d.cpuAverage, 12); XCTAssertEqual(d.apps.first?.name, "x")
        XCTAssertNil(d.dataUsage)
    }

    func day(_ back: Int, _ apps: [(String, UInt64)]?) -> DayRecord {
        let start = utc.date(byAdding: .day, value: -back, to: t0)!
        var d = DayRecord(day: "d\(back)", start: start)
        if let apps {
            let list = apps.map { AppNetDay(id: $0.0, name: $0.0, bytesIn: $0.1) }
            d.dataUsage = DataUsageDay(apps: list, totalIn: list.reduce(0) { $0 + $1.bytesIn }, totalOut: 0, countedSeconds: 3600, firstCounted: start)
        }
        return d
    }

    func testReportRangesSparklineAndUnusual() {
        let mb: UInt64 = 1_000_000
        var days: [DayRecord] = []
        for back in stride(from: 20, through: 1, by: -1) where back != 3 {   // day 3: FlightDeck didn't run
            days.append(day(back, back == 10 ? [("Video", 5000 * mb)] : [("Video", 400 * mb), ("Sync", 10 * mb)]))
        }
        days.append(day(0, [("Video", 500 * mb), ("Sync", 900 * mb)]))
        let r = DataUsageReport.build(days: days, now: t0.addingTimeInterval(3600), calendar: utc)
        let video = r.rows.first { $0.id == "Video" }!, sync = r.rows.first { $0.id == "Sync" }!
        XCTAssertEqual(r.rows.first?.id, "Video", "sorted by 30-day bytes")
        XCTAssertEqual(video.today, 500 * mb)
        XCTAssertEqual(video.week, 500 * mb + 5 * 400 * mb, "today + 6 earlier days, one of them not counted")
        XCTAssertEqual(r.todayTotal, 1400 * mb)
        XCTAssertEqual(r.countedDays, 20)
        XCTAssertEqual(video.daily.count, 30)
        XCTAssertNil(video.daily[26], "uncounted day is a gap"); XCTAssertNil(video.daily[0], "before history began")
        XCTAssertEqual(sync.daily[19], 0, "counted day where the app used nothing is a real zero")
        XCTAssertNil(video.unusual, "500 MB vs usual 400 MB")
        XCTAssertEqual(sync.unusual, "900.0 MB today; usually about 10.0 MB a day")
        XCTAssertNil(DataUsageReport.unusual(today: 900 * mb, history: [1, 2, 3, 4]), "needs 5 days of history")
        XCTAssertNil(DataUsageReport.unusual(today: 90 * mb, history: Array(repeating: 0, count: 10)), "below 100 MB")
        XCTAssertNil(DataUsageReport.unusual(today: 2500 * mb, history: Array(repeating: 1000e6, count: 10)), "under 3× usual")
    }
}
