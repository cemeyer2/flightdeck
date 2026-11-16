// Tests for the long-term history: daily rollups (DailyLog), per-app baselines and their findings, per-charge drain
// attribution and the before/after-an-update comparison. Inputs are clones of one real sample (`BlackBoxTests.base`)
// with every field the code reads overridden, at fixed UTC times, so results don't depend on the test machine.
import XCTest
@testable import FlightDeckCore

final class DailyLogTests: XCTestCase {
    /// 2026-01-01 00:00 UTC.
    let t0 = Date(timeIntervalSince1970: 1_767_225_600)
    let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    func log(dir: URL? = nil) -> DailyLog { DailyLog(dir: dir, calendar: utc, osVersion: "26.1", osBuild: "25B78") }

    /// An app process. `start` is the process start time; the default (1970) means "already running at launch".
    func proc(_ name: String, pid: Int32, cpuTime: Double, mem: UInt64, energy: Double? = nil, start: Date = Date(timeIntervalSince1970: 1)) -> ProcessSample {
        var p = BlackBoxTests.base.processes[0]
        p.identity = ProcessIdentity(pid: pid, startTime: UInt64(start.timeIntervalSince1970 * 1e6))
        p.name = name; p.path = "/Applications/\(name).app/Contents/MacOS/\(name)"
        p.cpuTime = cpuTime; p.cpu = 0; p.memory = mem; p.energyTotal = energy; p.energyWatts = nil
        return p
    }

    func snap(_ t: Date, cpu: Double = 10, watts: Double? = nil, battery: Double? = nil, procs: [ProcessSample]) -> Snapshot {
        var s = BlackBoxTests.base
        s.time = t; s.processes = procs; s.cpu.total = .value(cpu)
        s.memory.pressure = .value(20); s.memory.swapUsed = .value(0); s.power.hottest = .value(50); s.power.thermalState = 0
        s.power.systemWatts = watts.map { .value($0) } ?? .unavailable("test")
        s.power.powerSource = battery == nil ? "AC Power" : "Battery"
        if let battery, var b = s.power.battery ?? BlackBoxTests.base.power.battery { b.percent = battery; s.power.battery = b }
        else if let battery {
            s.power.battery = BatteryInfo(percent: battery, isCharging: false, externalConnected: false, cycleCount: 100, maxCapacity: 90, designCapacity: 100)
        } else { s.power.battery = nil }
        return s
    }

    /// Statistics roll up per day: time-weighted averages, a histogram 95th percentile, integrated energy, per-app CPU
    /// time from cumulative counters, peak memory; unmeasured app energy stays nil; a sample after midnight closes the day.
    func testRollupAccumulatesAndSplitsDays() {
        let l = log()
        let base = t0.addingTimeInterval(3600)
        for i in 0..<100 {
            let t = base.addingTimeInterval(Double(i))
            var procs = [proc("App", pid: 10, cpuTime: Double(i) * 0.5, mem: i < 50 ? 1_000_000_000 : 2_000_000_000)]
            // Started after FlightDeck began watching: its CPU time is counted from zero on first sight.
            if i >= 50 { procs.append(proc("Late", pid: 11, cpuTime: 3 + Double(i - 50) * 0.1, mem: 1_000, start: base.addingTimeInterval(49))) }
            l.ingest(snap(t, cpu: i < 50 ? 10 : 90, watts: 36, procs: procs))
        }
        l.ingest(snap(t0.addingTimeInterval(86_400 + 60), procs: []))   // next day
        let h = l.history()
        XCTAssertEqual(h.days.count, 2)
        let d = h.days[0]
        XCTAssertEqual(d.day, "2026-01-01")
        XCTAssertEqual(d.cpuAverage ?? 0, 50, accuracy: 0.5)
        XCTAssertEqual(d.cpuP95, 91, "the 90% bin's upper edge")
        XCTAssertEqual(d.energyWh ?? 0, 36 * 99 / 3600, accuracy: 1e-6)
        XCTAssertEqual(d.osVersion, "26.1")
        let app = d.apps.first { $0.name == "App" }!
        XCTAssertEqual(app.cpuSeconds, 45, accuracy: 1e-6, "passes every 10 s up to sample 90: 90 s × 0.5")
        XCTAssertEqual(app.peakMemory, 2_000_000_000)
        XCTAssertNil(app.energyWh, "no energy reported → nil, not 0")
        let late = d.apps.first { $0.name == "Late" }!
        XCTAssertEqual(late.cpuSeconds, 3 + 4, accuracy: 1e-6, "3 s before its first sighting + 40 s × 0.1")
        // The second day only has one snapshot and no energy readings: energy unmeasured, not 0.
        XCTAssertNil(h.days[1].energyWh)
    }

    /// Runs `minutes` of 10 s samples of one app on day `day`, starting at 09:00; returns every finding seen.
    @discardableResult
    func runDay(_ l: DailyLog, day: Int, minutes: Int, mem: (Int) -> UInt64) -> [Finding] {
        var seen: [Finding] = []
        let start = t0.addingTimeInterval(Double(day) * 86_400 + 9 * 3600)
        for i in 0..<(minutes * 6) {
            let t = start.addingTimeInterval(Double(i) * 10)
            let cpuTime = Double(day * 10_000) + Double(i) * 0.5   // 5% of a core
            seen += l.ingest(snap(t, procs: [proc("Browser", pid: 20, cpuTime: cpuTime, mem: mem(i / 6))]))
        }
        return seen
    }

    /// A baseline needs `minDays` of history: a big, sustained excess on day 5 is not reported; with 5 days of
    /// history it is, but only after it has lasted 10 minutes, and a 5-minute spike never is.
    func testBaselineNeedsHistoryAndSustainedExcess() {
        let l = log()
        let gb: UInt64 = 1_000_000_000
        for d in 0..<4 { runDay(l, day: d, minutes: 40) { _ in gb } }
        let early = runDay(l, day: 4, minutes: 40) { m in m >= 20 ? 4 * gb : gb }
        XCTAssertTrue(early.isEmpty, "only 4 days of history: no baseline, no finding")
        XCTAssertNil(l.history().baselines["/Applications/Browser.app"])
        let spike = runDay(l, day: 5, minutes: 40) { m in (10..<15).contains(m) ? 4 * gb : gb }
        XCTAssertNotNil(l.history().baselines["/Applications/Browser.app"], "5 closed days → baseline")
        XCTAssertTrue(spike.isEmpty, "a 5-minute excess isn't sustained")
        let small = runDay(l, day: 6, minutes: 40) { m in m >= 10 ? 2 * gb : gb }
        XCTAssertTrue(small.isEmpty, "2× isn't large enough")
        let real = runDay(l, day: 7, minutes: 40) { m in m >= 10 ? 4 * gb : gb }
        let f = real.last { $0.id == "usual-mem:/Applications/Browser.app" }
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.title.contains("Browser is using 4× its usual memory"), f!.title)
        XCTAssertEqual(f!.pids, [20])
        let firstSeen = real.first { $0.id == f!.id }!
        XCTAssertEqual(firstSeen.since, t0.addingTimeInterval(7 * 86_400 + 9 * 3600 + 600), "since = when the excess began")
    }

    /// Energy on battery is attributed per app since the unplug; shares are of measured system energy; plugging in
    /// closes the session and keeps it as the last one.
    func testDrainAttributionSinceUnplug() {
        let l = log()
        func procs(_ t: Double) -> [ProcessSample] {
            [proc("Photos", pid: 30, cpuTime: 0, mem: 1, energy: 3 * t), proc("Safari", pid: 31, cpuTime: 0, mem: 1, energy: 1 * t)]
        }
        l.ingest(snap(t0, watts: 8, procs: procs(0)))   // on AC
        for i in 1...60 { l.ingest(snap(t0.addingTimeInterval(Double(i) * 10), watts: 8, battery: 80 - Double(i) / 30, procs: procs(Double(i) * 10))) }
        let s = l.chargeStatus().current!
        XCTAssertTrue(s.sawUnplug)
        XCTAssertEqual(s.duration, 590, accuracy: 1e-6)
        XCTAssertEqual(s.systemWh ?? 0, 8 * 600 / 3600, accuracy: 1e-6)
        XCTAssertEqual(s.percentUsed ?? 0, 2 - 1.0 / 30, accuracy: 1e-6)
        let a = s.attribution()
        XCTAssertTrue(a.ofSystem)
        XCTAssertEqual(a.rows.map(\.name), ["Photos", "Safari"])
        XCTAssertEqual(a.rows[0].share, 0.375, accuracy: 1e-6)
        XCTAssertEqual(a.rows[1].share, 0.125, accuracy: 1e-6)
        XCTAssertEqual(a.otherShare ?? 0, 0.5, accuracy: 1e-6)
        XCTAssertEqual(a.summary, "Photos 38%, Safari 13%")
        l.ingest(snap(t0.addingTimeInterval(610), watts: 8, procs: procs(610)))   // plugged in
        XCTAssertNil(l.chargeStatus().current)
        XCTAssertNotNil(l.chargeStatus().last?.end)
        // Already on battery at launch: the session says it didn't see the unplug.
        let l2 = log()
        l2.ingest(snap(t0, watts: 8, battery: 50, procs: []))
        XCTAssertEqual(l2.chargeStatus().current?.sawUnplug, false)
        // No system power sensor: shares are of the energy billed to apps.
        let l3 = log()
        l3.ingest(snap(t0, procs: procs(0)))
        for i in 1...6 { l3.ingest(snap(t0.addingTimeInterval(Double(i) * 10), battery: 70, procs: procs(Double(i) * 10))) }
        let a3 = l3.chargeStatus().current!.attribution()
        XCTAssertFalse(a3.ofSystem)
        XCTAssertNil(l3.chargeStatus().current!.systemWh, "unmeasured, not 0")
        XCTAssertEqual(a3.rows[0].share, 0.75, accuracy: 1e-6)
    }

    /// A version change becomes an update event, and the before/after comparison names the regressions.
    func testUpdateComparisonFindsRegressions() {
        func day(_ k: Int, version: String, watts: Double, hangs: Int) -> DayRecord {
            var d = DayRecord(day: "2026-01-\(String(format: "%02d", k + 1))", start: t0.addingTimeInterval(Double(k) * 86_400))
            d.observedSeconds = 3600; d.osVersion = "26.1"; d.crashesByProcess = [:]; d.hangsByProcess = hangs > 0 ? ["Safari": hangs] : [:]
            var a = AppDay(id: "/Applications/Safari.app", name: "Safari"); a.version = version
            a.runningSeconds = 3600; a.energyWh = watts; a.cpuSeconds = 360; a.memorySeconds = 1e9 * 3600; a.peakMemory = 1_000_000_000
            d.apps = [a]
            return d
        }
        var days = (0..<4).map { day($0, version: "19.1", watts: 1, hangs: 0) }
        days.append(day(4, version: "19.2", watts: 1.4, hangs: 0))   // update day: excluded
        days += (5..<8).map { day($0, version: "19.2", watts: 1.4, hangs: 1) }
        let ups = Trends.updates(days)
        XCTAssertEqual(ups.map(\.title), ["Safari 19.2"])
        let c = Trends.compare(days, around: ups[0])
        XCTAssertEqual(c.beforeDays, 3); XCTAssertEqual(c.afterDays, 3)
        XCTAssertEqual(c.summary, "Since Safari 19.2: energy +40%, 3 hangs vs 0")
        // One day after the update isn't enough.
        let young = Trends.compare(Array(days.prefix(6)), around: ups[0])
        XCTAssertEqual(young.needsMoreDaysAfter, 1)
        XCTAssertTrue(young.summary.contains("needs 1 more day"), young.summary)
    }

    /// The log survives a relaunch (open day and closed days), and a log without a directory writes nothing.
    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = log(dir: dir)
        for i in 0..<30 { l.ingest(snap(t0.addingTimeInterval(Double(i)), procs: [proc("App", pid: 1, cpuTime: Double(i), mem: 5)])) }
        l.ingest(snap(t0.addingTimeInterval(86_400), procs: []))
        l.flush()
        let back = log(dir: dir)
        let h = back.history()
        XCTAssertEqual(h.days.map(\.day), ["2026-01-01", "2026-01-02"])
        XCTAssertEqual(h.days[0].apps.first?.cpuSeconds ?? 0, 20, accuracy: 1e-6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("daily-log.json").path))
        let mem = log()
        mem.ingest(snap(t0, procs: [])); mem.flush()
        XCTAssertNil(mem.dir)
    }
}
