// Tests for the analysis layer built on top of the samplers: Analyzer findings (sustained CPU, leaks, disk-full
// forecast, baseline, swapping, throttling, awake), IncidentLog, EnergyBudget, CSV export, ProcessQuery, Timeline and
// RuleEngine. Inputs are Snapshots cloned from one real sample (`BlackBoxTests.base`) at fixed timestamps, with every
// field the code under test reads overridden, so results don't depend on what the test machine is doing.
import XCTest
@testable import FlightDeckCore

/// Analyzer behaviour on synthetic sample streams. `proc` and `snap` are also used by the other test classes in this
/// file to build quiet, fully measured snapshots that only differ in what each test sets.
final class AnalyzerTests: XCTestCase {
    static let base: Snapshot = BlackBoxTests.base

    /// A process sample with the given identity and load, and every other per-process metric zeroed/absent so it can't
    /// trigger unrelated findings.
    func proc(_ name: String, path: String, pid: Int32, cpu: Double = 1, mem: UInt64 = 100_000_000) -> ProcessSample {
        var p = Self.base.processes[0]
        p.identity = ProcessIdentity(pid: pid, startTime: 1); p.name = name; p.path = path
        p.uid = getuid(); p.energyTotal = nil; p.cpu = cpu; p.memory = mem; p.wakeups = 0; p.diskReadBps = 0; p.diskWriteBps = 0; p.network = nil
        return p
    }

    /// A calm system snapshot (normal pressure, no swap, no I/O, no battery, half-full disk) at time `t`.
    func snap(_ t: Date, cpu: Double = 10, procs: [ProcessSample], free: UInt64? = nil) -> Snapshot {
        var s = Self.base
        s.time = t; s.cpu.total = .value(cpu); s.processes = procs
        s.memory.pressureLevel = 1; s.memory.swapUsed = .value(0); s.power.thermalState = 0
        s.disk.readBps = .value(0); s.disk.writeBps = .value(0); s.network.inBps = .value(0); s.network.outBps = .value(0)
        s.power.battery = nil
        s.disk.volumes = [VolumeInfo(name: "HD", path: "/", capacity: 1_000_000_000_000, available: free ?? 500_000_000_000, fileSystem: "apfs", isInternal: true)]
        return s
    }

    /// Protects the core "which app is responsible" rule: helper processes roll up into their `.app`, the finding lists
    /// every responsible PID (for Inspect/Quit), `since` is when the condition began (not when it was reported), a short
    /// spell under the threshold isn't flagged, and a long sampling gap restarts the condition rather than bridging it.
    func testSustainedAppCPUGroupsHelpersAndKeepsStartTime() {
        let a = Analyzer(); let t0 = Date(timeIntervalSince1970: 1_000_000)
        func procs(_ c: Double) -> [ProcessSample] {
            [proc("Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode", pid: 10, cpu: c / 2),
             proc("SourceKitService", path: "/Applications/Xcode.app/Contents/SharedFrameworks/x.framework/SourceKitService", pid: 11, cpu: c / 2),
             proc("idle", path: "/usr/bin/idle", pid: 12, cpu: 1)]
        }
        for i in 0..<5 { a.ingest(snap(t0.addingTimeInterval(Double(i)), procs: procs(10))) }
        XCTAssertFalse(a.findings.contains { $0.id.hasPrefix("cpu:") })
        for i in 5..<120 { a.ingest(snap(t0.addingTimeInterval(Double(i)), procs: procs(160))) }
        let f = a.findings.first { $0.id == "cpu:/Applications/Xcode.app" }
        XCTAssertNotNil(f, "two Xcode processes at 80% each roll up to one app at 160%")
        XCTAssertTrue(f!.title.contains("Xcode (2 processes)"))
        XCTAssertEqual(Set(f!.pids ?? []), [10, 11], "responsible processes are attached for Inspect/Quit")
        XCTAssertLessThan(f!.since.timeIntervalSince(t0), 30, "since is when it started, not now")
        // a 5-minute gap resets sustained conditions
        a.ingest(snap(t0.addingTimeInterval(420), procs: procs(160)))
        XCTAssertEqual(a.findings.first { $0.id == "cpu:/Applications/Xcode.app" }?.since, t0.addingTimeInterval(420))
    }

    /// A leak finding needs steady growth. Memory that jumps around, even by more in total, must not be reported,
    /// or every app with a large cache would be called leaky.
    func testMemoryLeakDetectedOnlyForSteadyGrowth() {
        let a = Analyzer(); let t0 = Date(timeIntervalSince1970: 2_000_000)
        for i in 0...40 {   // 20 minutes, 30 s apart; leaky grows 1 → 3 GB, noisy jumps around
            let leaky = UInt64(1e9 + Double(i) * 5e7)
            let noisy = UInt64(i % 2 == 0 ? 1e9 : 2.5e9)
            a.ingest(snap(t0.addingTimeInterval(Double(i) * 30), procs: [
                proc("Leaky", path: "/Applications/Leaky.app/Contents/MacOS/Leaky", pid: 20, mem: leaky),
                proc("Noisy", path: "/Applications/Noisy.app/Contents/MacOS/Noisy", pid: 21, mem: noisy)]))
        }
        XCTAssertTrue(a.findings.contains { $0.id == "leak:/Applications/Leaky.app" })
        XCTAssertFalse(a.findings.contains { $0.id == "leak:/Applications/Noisy.app" })
    }

    /// The startup-disk forecast extrapolates the free-space trend linearly (days until full) and raises a caution
    /// finding when that is close.
    func testDiskFullForecast() {
        let a = Analyzer(); let t0 = Date(timeIntervalSince1970: 3_000_000)
        // Loses 10 GB/hour from 100 GB free over a 3 h window, ending with 70 GB free: ~7 h (0.29 days) left.
        for m in stride(from: 0, through: 180, by: 1) {
            let free = UInt64(100e9 - Double(m) / 60 * 10e9)
            a.ingest(snap(t0.addingTimeInterval(Double(m) * 60), procs: [], free: free))
        }
        let days = a.daysUntilFull()
        XCTAssertNotNil(days)
        XCTAssertEqual(days!, 70.0 / 10 / 24, accuracy: 0.02)
        XCTAssertTrue(a.findings.contains { $0.id == "disk-full" && $0.severity == .caution })
    }

    /// The "unusual for this Mac" baseline is seeded from history (the black box) and only flags load well above it:
    /// a modest rise (20% vs a 5–14% baseline) is ignored, a sustained 70% is reported.
    func testBaselineFlagsUnusualCPU() {
        let a = Analyzer(); let t0 = Date(timeIntervalSince1970: 4_000_000)
        a.seed(history: (0..<400).map { snap(t0.addingTimeInterval(Double($0) * 10), cpu: Double(5 + $0 % 10), procs: []) })
        XCTAssertNotNil(a.baseline?.cpu)
        let t1 = t0.addingTimeInterval(5000)
        for i in 0..<30 { a.ingest(snap(t1.addingTimeInterval(Double(i)), cpu: 20, procs: [])) }
        XCTAssertFalse(a.findings.contains { $0.id == "unusual-cpu" })
        for i in 30..<300 { a.ingest(snap(t1.addingTimeInterval(Double(i)), cpu: 70, procs: [])) }
        XCTAssertTrue(a.findings.contains { $0.id == "unusual-cpu" })
    }
}

/// Incident logging: the persistent "what happened at 3:14 pm" history built from findings.
final class IncidentLogTests: XCTestCase {
    func f(_ id: String, since: Date, _ sev: Finding.Severity = .caution) -> Finding {
        Finding(id: id, severity: sev, icon: "x", title: id, detail: nil, since: since, destination: nil)
    }

    /// Short blips (under `minDuration`, 20 s) are noise and never logged; a lasting finding is reported once, keeps its
    /// original start and its worst severity, gets an end time when it clears, and survives a save/reload round trip.
    func testLogsOnlyLastingFindingsAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inc-\(UUID().uuidString).json")
        let log = IncidentLog(url: url)
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        for i in 0..<10 { log.update([f("blip", since: t0)], at: t0.addingTimeInterval(Double(i))) }
        log.update([], at: t0.addingTimeInterval(10))
        XCTAssertTrue(log.incidents.isEmpty, "a 10 s blip is noise")
        var logged: [Incident] = []
        for i in 0..<60 { logged += log.update([f("hog", since: t0, i > 40 ? .warning : .caution)], at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(logged.count, 1, "reported once, when it crosses minDuration")
        log.update([], at: t0.addingTimeInterval(60))
        XCTAssertEqual(log.incidents.count, 1)
        XCTAssertEqual(log.incidents[0].start, t0)
        XCTAssertEqual(log.incidents[0].end, t0.addingTimeInterval(60))
        XCTAssertEqual(log.incidents[0].severity, .warning, "keeps the worst severity")
        log.save()
        XCTAssertEqual(IncidentLog(url: url).incidents.count, 1)
    }
}

/// Energy budget integration over black-box frames.
final class EnergyBudgetTests: XCTestCase {
    /// Energy is integrated per app over time (W × s → Wh) and a 1000 s hole in the recording contributes nothing:
    /// gaps are missing data, not time at the last known power. The average is over recorded time only.
    func testIntegratesPerAppAndSkipsGaps() {
        let t0 = Date(timeIntervalSince1970: 6_000_000)
        var base = AnalyzerTests.base
        base.power.systemWatts = .value(10); base.power.powerSource = "AC Power"
        var p = base.processes[0]; p.identity = ProcessIdentity(pid: 5, startTime: 1)
        p.path = "/Applications/Hot.app/Contents/MacOS/Hot"; p.energyWatts = 3.6
        var frames: [Snapshot] = []
        for i in 0..<3601 where !(1000..<2000).contains(i) {   // 1 Hz for an hour, with a 1000 s gap
            var s = base; s.time = t0.addingTimeInterval(Double(i)); s.processes = [p]; frames.append(s)
        }
        let b = EnergyBudget.compute(Trace(host: "h", model: "m", interval: 1, frames: frames))
        XCTAssertEqual(b.apps.first?.name, "Hot")
        XCTAssertEqual(b.apps.first!.wattHours, 3.6 * 2600 / 3600, accuracy: 0.01, "the gap is not counted")
        XCTAssertEqual(b.apps.first!.averageWatts, 3.6, accuracy: 0.001)
        XCTAssertEqual(b.systemWattHours!, 10 * 2600 / 3600, accuracy: 0.01)
    }
}

/// CSV export and recording statistics.
final class ExportTests: XCTestCase {
    /// Unmeasured values must export as empty cells, not 0, so spreadsheets and averages aren't skewed by invented
    /// zeros; statistics likewise ignore the unmeasured frame (average 50 of 40 and 60, not 33).
    func testCSVLeavesUnmeasuredEmptyAndStats() {
        var a = AnalyzerTests.base; a.time = Date(timeIntervalSince1970: 7_000_000); a.cpu.total = .unavailable("warming up")
        var b = a; b.time = a.time.addingTimeInterval(1); b.cpu.total = .value(40)
        var c = b; c.time = b.time.addingTimeInterval(1); c.cpu.total = .value(60)
        let t = Trace(host: "h", model: "m", interval: 1, frames: [a, b, c])
        let rows = TraceExport.systemCSV(t).split(separator: "\n")
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows[1].split(separator: ",", omittingEmptySubsequences: false)[1].isEmpty, "unmeasured CPU is an empty cell, not 0")
        XCTAssertEqual(rows[2].split(separator: ",")[1], "40.000")
        let st = TraceStats.compute(t)
        XCTAssertEqual(st.cpu!.avg, 50, accuracy: 0.001)
        XCTAssertEqual(st.cpu!.peak, 60)
        XCTAssertFalse(TraceExport.processCSV(t).isEmpty)
    }
}

/// Sleep-prevention assertions become a plain-English finding.
final class AwakeFindingTests: XCTestCase {
    /// An app holding a display-sleep assertion is reported per app, with the reason string the app gave macOS.
    func testAppKeepingMacAwake() {
        let t = AnalyzerTests()
        var p = t.proc("Zoom", path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us", pid: 40)
        p.uid = 501; p.powerAssertions = [PowerAssertion(type: "PreventUserIdleDisplaySleep", name: "In a meeting")]
        let a = Analyzer()
        a.ingest(t.snap(Date(timeIntervalSince1970: 8_000_000), procs: [p]))
        let f = a.findings.first { $0.id == "awake:/Applications/zoom.us.app" }
        XCTAssertEqual(f?.title, "zoom.us keeps the display awake")
        XCTAssertEqual(f?.detail, "Reason given: “In a meeting”.")
    }
}

/// The Processes filter mini-language.
final class ProcessQueryTests: XCTestCase {
    /// Each term type (cpu>, mem> with unit suffixes, user:, kind:intel for Rosetta, app: on the bundle path, free text
    /// on name, bare numbers as PID) matches as documented, all terms must match, and a blank query is empty.
    func testQueries() {
        let t = AnalyzerTests()
        var chrome = t.proc("Google Chrome Helper", path: "/Applications/Google Chrome.app/Contents/Frameworks/x/Helper", pid: 7, cpu: 60, mem: 2 << 30)
        chrome.user = "cmeyer"; chrome.translated = false
        var old = t.proc("OldTool", path: "/usr/local/bin/oldtool", pid: 8, cpu: 1, mem: 10 << 20)
        old.user = "root"; old.translated = true
        func q(_ s: String) -> [Int32] { [chrome, old].filter(ProcessQuery(s).matches).map(\.pid) }
        XCTAssertEqual(q("cpu>50"), [7])
        XCTAssertEqual(q("mem>1g"), [7])
        XCTAssertEqual(q("mem<100m"), [8])
        XCTAssertEqual(q("user:root"), [8])
        XCTAssertEqual(q("kind:intel"), [8])
        XCTAssertEqual(q("app:chrome cpu>10"), [7])
        XCTAssertEqual(q("helper"), [7])
        XCTAssertEqual(q("8"), [8])
        XCTAssertEqual(q("cpu>50 user:root"), [])
        XCTAssertTrue(ProcessQuery("  ").isEmpty)
    }
}

/// Timeline bucketing for the Flight Log strips.
final class TimelineTests: XCTestCase {
    /// Buckets with no samples are gaps (nil values, `isGap`), never zero, so the timeline can hatch periods when the
    /// Mac was asleep or FlightDeck wasn't running instead of drawing them as idle.
    func testBucketsAndGaps() {
        let t0 = Date(timeIntervalSince1970: 9_000_000)
        var frames: [Snapshot] = []
        for i in 0..<60 where i < 20 || i >= 40 {   // 20 min, 20 min gap, 20 min
            var s = AnalyzerTests.base; s.time = t0.addingTimeInterval(Double(i) * 60); s.cpu.total = .value(Double(i)); frames.append(s)
        }
        let b = Timeline.build(frames, from: t0, to: t0.addingTimeInterval(3600), buckets: 6)
        XCTAssertEqual(b.count, 6)
        XCTAssertEqual(b[0].samples, 10); XCTAssertEqual(b[0].cpuMax, 9); XCTAssertEqual(b[0].cpuAvg!, 4.5, accuracy: 0.001)
        XCTAssertTrue(b[2].isGap && b[3].isGap, "no samples = gap, not zero")
        XCTAssertNil(b[2].cpuAvg)
        XCTAssertEqual(b[5].cpuMax, 59)
    }
}

/// Swap activity thresholds.
final class SwappingTests: XCTestCase {
    /// The "swapping" finding is driven by the swap-out rate derived from cumulative page counters: ~49 MB/s is flagged,
    /// ~1.6 MB/s of background swap is not.
    func testHeavySwapIsFlaggedLightIsNot() {
        let t = AnalyzerTests(); let t0 = Date(timeIntervalSince1970: 10_000_000)
        func run(_ pagesPerSec: UInt64) -> Bool {
            let a = Analyzer()
            for i in 0..<60 {
                var s = t.snap(t0.addingTimeInterval(Double(i)), procs: [])
                s.memory.pageSize = 16384; s.memory.swapOuts = UInt64(i) * pagesPerSec
                a.ingest(s)
            }
            return a.findings.contains { $0.id == "swapping" }
        }
        XCTAssertTrue(run(3000), "~49 MB/s")
        XCTAssertFalse(run(100), "~1.6 MB/s is not heavy")
    }
}

/// Measured CPU throttling.
final class ThrottleTests: XCTestCase {
    /// Feeds a minute of busy (95% active) P-cluster samples at the given clock and hotspot temperature.
    func run(mhz: Double, hot: Double) -> Bool {
        let t = AnalyzerTests(); let a = Analyzer(); let t0 = Date(timeIntervalSince1970: 11_000_000)
        for i in 0..<60 {
            var s = t.snap(t0.addingTimeInterval(Double(i)), procs: [])
            s.power.hottest = .value(hot)
            s.gpuDetail = GPUDetail(clients: [], cpuClusters: [ClusterFrequency(name: "P-cluster", mhz: mhz, active: 95, maxMHz: 3228)])
            a.ingest(s)
        }
        return a.findings.contains { $0.id == "cpu-throttled" }
    }
    /// Throttling is only claimed when busy P-cores run well below their top clock *and* the Mac is hot; low clocks
    /// alone are ordinary power management, and high clocks while hot aren't throttling.
    func testThrottlingNeedsLowClocksWhileBusyAndHot() {
        XCTAssertTrue(run(mhz: 1800, hot: 98))
        XCTAssertFalse(run(mhz: 3100, hot: 98), "full clocks are not throttling")
        XCTAssertFalse(run(mhz: 1800, hot: 60), "cool and slow is just power management")
    }
}

/// Findings that should show in the UI but not clutter the incident log.
final class NoiseTests: XCTestCase {
    /// "Keeps the Mac awake" is usually intentional (a video call, a download), so it is excluded from incidents even
    /// when it lasts.
    func testAwakeIsNotAnIncident() {
        let log = IncidentLog(url: nil); let t0 = Date(timeIntervalSince1970: 12_000_000)
        let f = Finding(id: "awake:/Applications/x.app", severity: .info, icon: "x", title: "x keeps the display awake", detail: nil, since: t0, destination: nil)
        for i in 0..<60 { log.update([f], at: t0.addingTimeInterval(Double(i))) }
        XCTAssertTrue(log.incidents.isEmpty)
    }
}

/// User automation rules.
final class RuleEngineTests: XCTestCase {
    /// Guards the safety properties of rules, which can quit processes: a rule fires only after its condition has held
    /// for `minutes`, once per occurrence (not every sample), targets every process of the matched app, respects its
    /// cooldown when the condition breaks and returns, and never targets protected processes (kernel_task,
    /// WindowServer…) even with a match-everything rule. Also checks the examples survive save/load.
    func testFiresOncePerOccurrenceAfterDurationWithCooldownAndProtection() {
        let t = AnalyzerTests(); let t0 = Date(timeIntervalSince1970: 13_000_000)
        let e = RuleEngine()
        e.rules = [Rule(name: "hog", target: .app, match: "busy", metric: .cpu, threshold: 100, minutes: 1, action: .quit, cooldownMinutes: 5)]
        func procs(_ c: Double) -> [ProcessSample] {
            [t.proc("Busy", path: "/Applications/Busy.app/Contents/MacOS/Busy", pid: 50, cpu: c / 2),
             t.proc("Busy Helper", path: "/Applications/Busy.app/Contents/Helpers/H", pid: 51, cpu: c / 2),
             t.proc("kernel_task", path: "", pid: 0, cpu: 500), t.proc("WindowServer", path: "/System/x/WindowServer", pid: 60, cpu: 500)]
        }
        var firings: [RuleFiring] = []
        for i in 0..<200 { firings += e.evaluate(t.snap(t0.addingTimeInterval(Double(i)), procs: procs(150))) }
        XCTAssertEqual(firings.count, 1, "once per occurrence, after 60 s")
        XCTAssertEqual(firings[0].time.timeIntervalSince(t0), 60, accuracy: 1)
        XCTAssertEqual(Set(firings[0].targets.map(\.pid)), [50, 51], "the app's processes")
        // condition breaks, then returns within the cooldown: no second firing
        for i in 200..<205 { firings += e.evaluate(t.snap(t0.addingTimeInterval(Double(i)), procs: procs(10))) }
        for i in 205..<280 { firings += e.evaluate(t.snap(t0.addingTimeInterval(Double(i)), procs: procs(150))) }
        XCTAssertEqual(firings.count, 1, "cooldown")
        // protected processes are never targets, even with a match-all rule
        let any = RuleEngine(); any.rules = [Rule(name: "any", target: .process, metric: .cpu, threshold: 100, minutes: 0, action: .forceQuit)]
        let f = any.evaluate(t.snap(t0, procs: procs(150)))
        XCTAssertFalse(f.contains { ["kernel_task", "WindowServer"].contains($0.subject) })
        XCTAssertEqual(RuleEngine.load(RuleEngine.save(RuleEngine.examples)).count, 3)
    }
}
