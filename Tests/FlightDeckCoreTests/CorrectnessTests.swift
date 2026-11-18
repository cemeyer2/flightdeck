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

/// Rules must never be able to hurt the system or the user's current work.
final class RuleSafetyTests: XCTestCase {
    let t = AnalyzerTests()
    let t0 = Date(timeIntervalSince1970: 15_000_000)

    func run(_ r: Rule, _ procs: [ProcessSample], seconds: Int = 120, frontmost: Int32? = nil) -> [RuleFiring] {
        let e = RuleEngine(); e.rules = [r]; e.frontmostPID = frontmost
        return (0..<seconds).flatMap { e.evaluate(t.snap(t0.addingTimeInterval(Double($0)), procs: procs)) }
    }

    /// Platform binaries and the frontmost app are never quit, even by a matching rule.
    func testDestructiveRulesSkipSystemAndFrontmost() {
        let sys = t.proc("mds_stores", path: "/System/Library/Frameworks/x/mds_stores", pid: 20, cpu: 400)
        let front = t.proc("Editor", path: "/Applications/Editor.app/Contents/MacOS/Editor", pid: 21, cpu: 400)
        let other = t.proc("Hog", path: "/Applications/Hog.app/Contents/MacOS/Hog", pid: 22, cpu: 400)
        var r = Rule(name: "q", target: .process, match: "", metric: .cpu, threshold: 100, minutes: 1, action: .quit)
        r.acknowledgedBroadMatch = true
        let f = run(r, [sys, front, other], frontmost: 21)
        XCTAssertEqual(f.map(\.subject), ["Hog"])
        // …while notify may still watch system processes
        let n = run(Rule(name: "n", target: .process, match: "mds", metric: .cpu, threshold: 100, minutes: 1, action: .notify), [sys])
        XCTAssertEqual(n.count, 1)
    }

    /// A destructive match-everything rule doesn't run until the user acknowledges it; and destructive rules wait ≥ 1 min.
    func testBroadDestructiveNeedsAcknowledgementAndMinimumDuration() {
        let hog = t.proc("Hog", path: "/Applications/Hog.app/Contents/MacOS/Hog", pid: 22, cpu: 400)
        var r = Rule(name: "q", target: .app, match: "", metric: .cpu, threshold: 100, minutes: 0, action: .forceQuit)
        XCTAssertNotNil(r.problem)
        XCTAssertTrue(run(r, [hog]).isEmpty)
        r.acknowledgedBroadMatch = true
        let f = run(r, [hog])
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].time.timeIntervalSince(t0), 60, accuracy: 1, "0 minutes is raised to 1 for destructive actions")
        XCTAssertEqual(f[0].subjectID, "/Applications/Hog.app")
    }

    /// Invalid rules never run; rules saved by older versions still load.
    func testValidationAndOldRulesDecode() {
        XCTAssertNotNil(Rule(name: "z", threshold: 0).problem)
        let old = #"[{"id":"6F9C0F5E-0E7B-4E2C-9C7A-2E6E8B1C9A11","name":"old","enabled":true,"target":"App","match":"x","metric":"CPU %","threshold":50,"minutes":2,"action":"Notify me","command":"","cooldownMinutes":30}]"#
        let rules = RuleEngine.load(Data(old.utf8))
        XCTAssertEqual(rules.first?.name, "old"); XCTAssertEqual(rules.first?.resumeAfterMinutes, 5)
    }

    /// Dry run replays recorded frames through a fresh engine.
    func testDryRun() {
        let hog = t.proc("Hog", path: "/Applications/Hog.app/Contents/MacOS/Hog", pid: 22, cpu: 400)
        let frames = (0..<200).map { t.snap(t0.addingTimeInterval(Double($0)), procs: [hog]) }
        let r = Rule(name: "n", enabled: false, target: .app, match: "hog", metric: .cpu, threshold: 100, minutes: 1, action: .notify)
        XCTAssertEqual(RuleEngine.dryRun(r, frames: frames).count, 1)
    }
}

/// Long-range totals from sparse, trimmed recordings must be exact when cumulative counters are available.
final class FidelityTests: XCTestCase {
    let t = AnalyzerTests()
    func testEnergyFromCumulativeCountersIsExactDespiteGapsAndTrimming() {
        let t0 = Date(timeIntervalSince1970: 16_000_000)
        var frames: [Snapshot] = []
        // A process drawing exactly 2 W for an hour, recorded only every 10 s and missing from 2 of every 3 frames.
        for i in 0..<360 where i % 3 == 0 || i == 359 {
            var p = t.proc("Busy", path: "/Applications/Busy.app/Contents/MacOS/Busy", pid: 70)
            p.energyTotal = Double(i) * 10 * 2          // joules so far
            p.energyWatts = i % 30 == 0 ? 50 : 0.1      // misleading instantaneous rates (bursty)
            var s = t.snap(t0.addingTimeInterval(Double(i) * 10), procs: [p]); s.power.systemWatts = .value(5)
            frames.append(s)
        }
        let b = EnergyBudget.compute(Trace(host: "h", model: "m", interval: 10, frames: frames))
        XCTAssertEqual(b.apps.first?.wattHours ?? 0, 2.0 * 3590 / 3600, accuracy: 0.01, "2 W × the recorded span, from the counter")
        XCTAssertEqual(b.apps.first?.averageWatts ?? 0, 2.0, accuracy: 0.01)
        XCTAssertNotNil(b.unattributedWattHours)
    }

    func testAverageCPUFromCumulativeCPUTime() {
        let t0 = Date(timeIntervalSince1970: 17_000_000)
        let frames = (0..<61).filter { $0 % 4 == 0 || $0 == 60 }.map { i -> Snapshot in
            var p = t.proc("Half", path: "/Applications/Half.app/Contents/MacOS/Half", pid: 80, cpu: i % 8 == 0 ? 400 : 0)
            p.cpuTime = Double(i) * 0.5                  // half a core, steadily
            return t.snap(t0.addingTimeInterval(Double(i)), procs: [p])
        }
        let st = TraceStats.compute(Trace(host: "h", model: "m", interval: 1, frames: frames))
        XCTAssertEqual(st.topCPU.first?.avg ?? 0, 50, accuracy: 0.5)
    }
}

/// The smaller bugs from the review.
final class SmallBugTests: XCTestCase {
    /// Empty arguments are real arguments: they must not shift the argv/environment boundary.
    func testEmptyArgumentsDontShiftEnvironment() throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 5; true", "", "x"]   // two commands, so sh stays sh instead of exec-ing sleep
        try p.run(); defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let d = ProcessInspector.details(pid: p.processIdentifier, path: "/bin/sh")
        XCTAssertEqual(d.arguments.value, ["/bin/sh", "-c", "sleep 5; true", "", "x"])
        // macOS doesn't expose another process's environment: it must read as unavailable, never as "0 variables",
        // and an argument must never leak into it.
        if let env = d.environment.value { XCTAssertFalse(env.contains("x")); XCTAssertFalse(env.isEmpty) }
        else { XCTAssertNil(d.environment.value) }
    }

    /// Every connection gets a unique ID, even identical unconnected sockets.
    func testConnectionIDsAreUnique() {
        let c = Connections.list()
        XCTAssertEqual(Set(c.map(\.id)).count, c.count)
    }

    /// A process that starts between two samples shows its real average since launch, not 0%.
    func testNewProcessIsntShownIdle() throws {
        let s = ProcessSampler(); _ = s.sample()
        let hog = FileManager.default.temporaryDirectory.appendingPathComponent("fd-hog-\(UUID().uuidString)")
        let src = hog.appendingPathExtension("c")
        try "int main(void){volatile unsigned long x=0;for(;;)x++;}".write(to: src, atomically: true, encoding: .utf8)
        let cc = Process(); cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc"); cc.arguments = ["-o", hog.path, src.path]
        try cc.run(); cc.waitUntilExit()
        guard cc.terminationStatus == 0 else { throw XCTSkip("no C compiler") }
        _ = s.sample()                               // baseline after compiling, before the hog exists
        let p = Process(); p.executableURL = hog; try p.run()
        defer { p.terminate(); try? FileManager.default.removeItem(at: hog); try? FileManager.default.removeItem(at: src) }
        Thread.sleep(forTimeInterval: 0.6)
        let first = s.sample().first { $0.pid == p.processIdentifier }
        XCTAssertGreaterThan(first?.cpu ?? 0, 40, "first appearance already shows its CPU use")
    }

    /// A memory sample whose statistics couldn't be read is flagged, so views show "—" instead of zeros.
    func testUnmeasuredMemoryIsFlagged() {
        var m = BlackBoxTests.base.memory
        XCTAssertTrue(m.isMeasured)
        m.measured = false
        XCTAssertFalse(m.isMeasured)
    }
}

/// Remaining review findings in the core library.
final class CoreFindingsTests: XCTestCase {
    /// macOS writes "Using Batt" as well as "Using BATT"; both mean the Mac was on battery.
    func testSleepLogBatteryCaseInsensitive() {
        let log = "2026-11-16 00:10:00 -0600 Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:90%) 600 secs"
        XCTAssertEqual(SleepLog.parse(log, since: .distantPast).events.first?.onBattery, true)
    }

    /// A custom SIP configuration lists per-protection lines with both words; only the status line counts.
    func testCustomSIPConfiguration() {
        XCTAssertEqual(SystemInfo.parseCSR("System Integrity Protection status: enabled.\n"), "Enabled")
        XCTAssertEqual(SystemInfo.parseCSR("System Integrity Protection status: unknown (Custom Configuration).\n\nConfiguration:\n\tKext Signing: disabled\n\tFilesystem Protections: enabled\n"), "Custom configuration")
    }

    /// launchd's override database is parsed (it wins over a plist's own Disabled key).
    func testLaunchdDisabledOverrides() {
        let out = "disabled services = {\n\t\t\"com.docker.helper\" => enabled\n\t\t\"com.example.agent\" => disabled\n\t}\n"
        XCTAssertEqual(Launchd.parseDisabled(out), ["com.docker.helper": false, "com.example.agent": true])
    }

    /// An incident open when the app crashed keeps the duration known at the last save, not zero.
    func testIncidentOpenAtCrashKeepsLastSeen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString).json")
        let log = IncidentLog(url: url)
        let start = Date().addingTimeInterval(-300)
        let f = Finding(id: "cpu:x", severity: .caution, icon: "x", title: "x", detail: nil, since: start, destination: nil)
        log.update([f], at: Date())
        log.save()   // "crash" here: no closeAll
        let reloaded = IncidentLog(url: url).incidents.first
        XCTAssertGreaterThan(reloaded?.duration ?? 0, 250)
    }

    func testTimelineWithNoBuckets() {
        XCTAssertTrue(Timeline.build([], from: Date(), to: Date(), buckets: 0).isEmpty)
    }

    /// A trace remembers the macOS version that recorded it.
    func testTraceRecordsOSVersion() throws {
        let t = Trace(host: "h", model: "m", interval: 1, frames: [BlackBoxTests.base])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("os-\(UUID().uuidString).flightlog")
        try t.write(to: url)
        XCTAssertEqual(try Trace.read(from: url).osVersion, ProcessInfo.processInfo.operatingSystemVersionString)
    }
}

final class SleepFindingTests: XCTestCase {
    /// A night with many dark wakes and real battery drain yields both findings, naming the main cause.
    func testRestlessNight() {
        var lines = ["2026-11-16 00:00:00 -0600 Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:90%) 60 secs"]
        for i in 0..<35 {
            let t = String(format: "2026-11-16 %02d:%02d:00 -0600", 1 + i / 6, (i % 6) * 10)
            lines.append("\(t) DarkWake            \tDarkWake from Deep Idle [CDNPB] : due to smc.sysState.Wake(0x70070000) bluetooth-pcie/ Using BATT (Charge:88%) 10 secs")
            lines.append("\(t) Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using BATT (Charge:88%) 590 secs")
        }
        lines.append("2026-11-16 07:00:00 -0600 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to EC.LidOpen/Lid Open Using BATT (Charge:76%)")
        let r = SleepLog.parse(lines.joined(separator: "\n"), since: .distantPast)
        let now = SleepLog.stamp.date(from: "2026-11-16 08:00:00 -0600")!
        let f = SleepLog.findings(r, now: now)
        XCTAssertEqual(f.map(\.id).sorted(), ["sleep-drain", "sleep-wakes"])
        XCTAssertTrue(f.first { $0.id == "sleep-wakes" }!.title.contains("bluetooth"))
        XCTAssertTrue(f.first { $0.id == "sleep-drain" }!.title.hasPrefix("Lost 14% battery"))
        XCTAssertTrue(SleepLog.findings(r, now: now.addingTimeInterval(13 * 3600)).isEmpty, "only for 12 hours after waking")
    }
}

/// Volume free space and decimal storage units.
final class VolumeSpaceTests: XCTestCase {
    /// External and network volumes report 0 "available for important usage"; that must not read as a full disk.
    func testFreeSpaceFallsBackWhenImportantUsageIsZero() {
        XCTAssertEqual(DiskSampler.freeSpace(important: 0, available: 135_560_000_000), 135_560_000_000)
        XCTAssertEqual(DiskSampler.freeSpace(important: nil, available: 42), 42)
        // The startup volume: important usage (including purgeable space) wins when it is reported.
        XCTAssertEqual(DiskSampler.freeSpace(important: 171_720_000_000, available: 103_510_000_000), 171_720_000_000)
        XCTAssertEqual(DiskSampler.freeSpace(important: nil, available: nil), 0)
    }

    /// Disk sizes use decimal units like Finder: a "1 TB" drive is 1.00 TB, not 931.3 GB.
    func testStorageUsesDecimalUnits() {
        XCTAssertEqual(Fmt.storage(UInt64(1_000_384_000_000)), "1.00 TB")
        XCTAssertEqual(Fmt.storage(UInt64(994_662_584_320)), "994.66 GB")
        XCTAssertEqual(Fmt.storage(UInt64(500_000)), "500.0 KB")
    }
}

/// Temperature display units.
final class TemperatureUnitTests: XCTestCase {
    override func tearDown() { UserDefaults.standard.removeObject(forKey: TemperatureUnit.defaultsKey) }

    func testConversionAndFormatting() {
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(100), 212, accuracy: 0.001)
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(0), 32, accuracy: 0.001)
        XCTAssertEqual(TemperatureUnit.celsius.convert(52), 52)
        UserDefaults.standard.set("fahrenheit", forKey: TemperatureUnit.defaultsKey)
        XCTAssertEqual(Fmt.temp(52), "126 °F")
        XCTAssertEqual(Fmt.tempNumber(36.6, digits: 1), "97.9")
        UserDefaults.standard.set("celsius", forKey: TemperatureUnit.defaultsKey)
        XCTAssertEqual(Fmt.temp(52), "52 °C")
    }
}

/// Folder scan progress: totals only grow, and they match the tree.
final class FolderScanProgressTests: XCTestCase {
    func testProgressCountsFilesAndNeverGoesBackwards() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for d in ["a", "b", "b/c"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        for i in 0..<1200 { try Data(count: 10).write(to: root.appendingPathComponent("a/f\(i)")) }   // > 500: mid-item progress
        for i in 0..<3 { try Data(count: 10).write(to: root.appendingPathComponent("b/c/g\(i)")) }
        try Data(count: 10).write(to: root.appendingPathComponent("top.txt"))
        let items = DiskUsage.scanItems(of: root.path)
        XCTAssertEqual(items.count, 3)
        final class Log: @unchecked Sendable { var p: [DiskUsage.ScanProgress] = []; var e: [DirEntry] = [] }
        let log = Log()
        DiskUsage.scan(items: items, progress: { log.p.append($0) }, entry: { log.e.append($0) }, cancelled: { false })
        XCTAssertEqual(log.e.count, 3)
        XCTAssertEqual(log.p.first?.total, 3)
        XCTAssertEqual(log.p.last?.done, 3)
        XCTAssertTrue(zip(log.p, log.p.dropFirst()).allSatisfy { $0.files <= $1.files && $0.bytes <= $1.bytes && $0.done <= $1.done },
                      "progress never goes backwards")
        // a: 1200 files; b: c + 3 files = 4 entries; top.txt: 1.
        XCTAssertEqual(log.p.last?.files, 1200 + 4 + 1)
    }

    func testCancelStopsInsideALargeFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("big"), withIntermediateDirectories: true)
        for i in 0..<2000 { try Data(count: 1).write(to: root.appendingPathComponent("big/f\(i)")) }
        final class Flag: @unchecked Sendable { var calls = 0; var entries = 0 }
        let f = Flag()
        DiskUsage.scan(items: DiskUsage.scanItems(of: root.path), progress: { _ in }, entry: { _ in f.entries += 1 },
                       cancelled: { f.calls += 1; return f.calls > 2 })
        XCTAssertEqual(f.entries, 0, "cancelled mid-folder: the half-measured folder is not reported")
    }
}
