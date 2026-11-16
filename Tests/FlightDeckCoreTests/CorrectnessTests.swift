// Regression tests for the correctness sprint: each test pins one bug that was found in review and fixed.
import XCTest
import IOKit.pwr_mgt
@testable import FlightDeckCore

final class CorrectnessTests: XCTestCase {
    let t = AnalyzerTests()
    let t0 = Date(timeIntervalSince1970: 14_000_000)

    /// Other users' processes (here launchd, owned by root) still get a real start time, so their identity is usable.
    func testIdentityOfOtherUsersProcess() {
        let id = ProcessSampler.identity(of: 1)
        XCTAssertNotNil(id)
        XCTAssertGreaterThan(id?.startTime ?? 0, 1_000_000_000_000_000 / 1000, "a real date, not 1970")
        let launchd = ProcessSampler().sample().first { $0.pid == 1 }
        XCTAssertEqual(launchd?.identity, id)
    }

    /// Unknown readings never satisfy a comparison: "gpu<1" must not list processes whose GPU use is unknown.
    func testQueryIgnoresUnknownValues() {
        var a = t.proc("a", path: "/bin/a", pid: 1); a.gpu = nil; a.energyWatts = nil; a.network = nil
        var b = t.proc("b", path: "/bin/b", pid: 2); b.gpu = 0.5
        XCTAssertEqual([a, b].filter(ProcessQuery("gpu<1").matches).map(\.pid), [2])
        XCTAssertTrue([a].filter(ProcessQuery("energy<1").matches).isEmpty)
        XCTAssertTrue([a].filter(ProcessQuery("net<1").matches).isEmpty)
    }

    /// VPN tunnels aren't added to machine totals (their bytes also cross the physical interface).
    func testTunnelsAreNotCountedTwice() {
        XCTAssertTrue(NetworkSampler.isVirtual("utun3")); XCTAssertTrue(NetworkSampler.isVirtual("lo0"))
        XCTAssertFalse(NetworkSampler.isVirtual("en0")); XCTAssertFalse(NetworkSampler.isVirtual("awdl0"))
    }

    /// A rule that becomes due during its cooldown fires once the cooldown ends, if the condition still holds.
    func testRuleDueDuringCooldownFiresAfterIt() {
        let e = RuleEngine()
        e.rules = [Rule(name: "r", target: .process, match: "hog", metric: .cpu, threshold: 50, minutes: 1, action: .notify, cooldownMinutes: 2)]
        func at(_ s: Double, _ cpu: Double) -> [RuleFiring] { e.evaluate(t.snap(t0.addingTimeInterval(s), procs: [t.proc("hog", path: "/bin/hog", pid: 9, cpu: cpu)])) }
        var times: [Double] = []
        for s in stride(from: 0.0, through: 70, by: 1) { times += at(s, 90).map { $0.time.timeIntervalSince(t0) } }     // fires at 60
        for s in stride(from: 71.0, through: 75, by: 1) { _ = at(s, 1) }                                                // dips
        for s in stride(from: 76.0, through: 260, by: 1) { times += at(s, 90).map { $0.time.timeIntervalSince(t0) } }  // due at 136, cooldown until 180
        XCTAssertEqual(times, [60, 180])
    }

    /// After incidents are closed (e.g. sampling paused) the same finding returning doesn't create an overlapping incident.
    func testNoOverlappingIncidentsAfterPause() {
        let log = IncidentLog(url: nil)
        let f = Finding(id: "cpu:x", severity: .caution, icon: "x", title: "x", detail: nil, since: t0, destination: nil)
        for i in 0..<30 { log.update([f], at: t0.addingTimeInterval(Double(i))) }
        log.closeAll(at: t0.addingTimeInterval(30))
        for i in 60..<100 { log.update([f], at: t0.addingTimeInterval(Double(i))) }   // analyzer still reports the old `since`
        XCTAssertEqual(log.incidents.count, 2)
        XCTAssertGreaterThanOrEqual(log.incidents[1].start, log.incidents[0].end!)
    }

    /// An idle main thread is reported as idle, and short wait names don't match unrelated symbols.
    func testStackSummaryIdleAndWaitMatching() {
        let idle = """
        Call graph:
            100 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 100 start  (in dyld) + 1  [0x1]
            +   100 main  (in App) + 1  [0x2]
            +     100 NSApplicationMain  (in AppKit) + 1  [0x3]
            +       100 __CFRunLoopServiceMachPort  (in CoreFoundation) + 1  [0x4]
            +         100 mach_msg2_trap  (in libsystem_kernel.dylib) + 1  [0x5]
        Total number in stack:
        """
        XCTAssertEqual(StackSummary.summarize(idle), "Main thread idle in the event loop (not stuck)")
        XCTAssertFalse(StackSummary.isWait("spread_items")); XCTAssertFalse(StackSummary.isWait("pthread_getname"))
        XCTAssertTrue(StackSummary.isWait("read")); XCTAssertTrue(StackSummary.isWait("mach_msg2_trap")); XCTAssertTrue(StackSummary.isWait("kevent_qos"))
    }

    /// Seeded disk-space history that arrives after live samples still counts toward the forecast.
    func testSeedAfterLiveKeepsDiskTrend() {
        let a = Analyzer()
        let now = t0.addingTimeInterval(4 * 3600)
        a.ingest(t.snap(now, procs: [], free: 60_000_000_000))                      // a live sample first
        let history = (0..<240).map { m in t.snap(t0.addingTimeInterval(Double(m) * 60), procs: [], free: UInt64(100e9 - Double(m) * 1e8)) }
        a.seed(history: history)                                                   // 4 h shrinking at 6 GB/h
        XCTAssertNotNil(a.daysUntilFull(), "the seeded history is used even though it arrived after a live point")
    }

    /// A drive below its spare threshold says why it needs attention.
    func testDriveSpareWarning() {
        let d = DriveHealth(model: "SSD", serial: nil, criticalWarning: 0, temperature: 30, availableSpare: 5, spareThreshold: 10, percentUsed: 1,
                            bytesRead: 0, bytesWritten: 0, powerOnHours: 1, powerCycles: 1, unsafeShutdowns: 0, mediaErrors: 0, errorLogEntries: 0)
        XCTAssertFalse(d.healthy); XCTAssertTrue(d.warnings.contains("spare capacity below threshold"))
    }

    /// Launch Daemons are looked up in the system domain, so loaded ones aren't all shown as "Not loaded".
    func testLaunchDaemonsCanBeLoaded() {
        let daemons = Launchd.startupItems().filter { $0.kind == "Launch Daemon" }
        guard !daemons.isEmpty else { return }
        XCTAssertTrue(daemons.contains(where: \.loaded), "at least one installed daemon is running")
    }
}

final class TimeBucketTests: XCTestCase {
    /// Downsampling for reports and charts keeps time gaps as nil instead of squeezing them out.
    func testGapsSurvive() {
        let t0 = Date(timeIntervalSince1970: 0)
        let pts = (0..<10).map { (t0.addingTimeInterval(Double($0)), 1.0) } + (90..<100).map { (t0.addingTimeInterval(Double($0)), 3.0) }
        let b = timeBuckets(pts, buckets: 10)
        XCTAssertEqual(b.first!, 1); XCTAssertEqual(b.last!, 3)
        XCTAssertTrue(b[2...7].allSatisfy { $0 == nil })
    }
}
