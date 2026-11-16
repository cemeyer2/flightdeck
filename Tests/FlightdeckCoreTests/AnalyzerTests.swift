import XCTest
@testable import FlightdeckCore

final class AnalyzerTests: XCTestCase {
    static let base: Snapshot = BlackBoxTests.base

    func proc(_ name: String, path: String, pid: Int32, cpu: Double = 1, mem: UInt64 = 100_000_000) -> ProcessSample {
        var p = Self.base.processes[0]
        p.identity = ProcessIdentity(pid: pid, startTime: 1); p.name = name; p.path = path
        p.cpu = cpu; p.memory = mem; p.wakeups = 0; p.diskReadBps = 0; p.diskWriteBps = 0; p.network = nil
        return p
    }

    func snap(_ t: Date, cpu: Double = 10, procs: [ProcessSample], free: UInt64? = nil) -> Snapshot {
        var s = Self.base
        s.time = t; s.cpu.total = .value(cpu); s.processes = procs
        s.memory.pressureLevel = 1; s.memory.swapUsed = .value(0); s.power.thermalState = 0
        s.disk.readBps = .value(0); s.disk.writeBps = .value(0); s.network.inBps = .value(0); s.network.outBps = .value(0)
        s.power.battery = nil
        s.disk.volumes = [VolumeInfo(name: "HD", path: "/", capacity: 1_000_000_000_000, available: free ?? 500_000_000_000, fileSystem: "apfs", isInternal: true)]
        return s
    }

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

    func testDiskFullForecast() {
        let a = Analyzer(); let t0 = Date(timeIntervalSince1970: 3_000_000)
        // loses 10 GB/hour from 100 GB free: ~10 h left at the end of a 3 h window
        for m in stride(from: 0, through: 180, by: 1) {
            let free = UInt64(100e9 - Double(m) / 60 * 10e9)
            a.ingest(snap(t0.addingTimeInterval(Double(m) * 60), procs: [], free: free))
        }
        let days = a.daysUntilFull()
        XCTAssertNotNil(days)
        XCTAssertEqual(days!, 70.0 / 10 / 24, accuracy: 0.02)
        XCTAssertTrue(a.findings.contains { $0.id == "disk-full" && $0.severity == .caution })
    }

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

final class IncidentLogTests: XCTestCase {
    func f(_ id: String, since: Date, _ sev: Finding.Severity = .caution) -> Finding {
        Finding(id: id, severity: sev, icon: "x", title: id, detail: nil, since: since, destination: nil)
    }

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

final class EnergyBudgetTests: XCTestCase {
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

final class ExportTests: XCTestCase {
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

final class AwakeFindingTests: XCTestCase {
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

final class ProcessQueryTests: XCTestCase {
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

final class TimelineTests: XCTestCase {
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

final class SwappingTests: XCTestCase {
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

final class ThrottleTests: XCTestCase {
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
    func testThrottlingNeedsLowClocksWhileBusyAndHot() {
        XCTAssertTrue(run(mhz: 1800, hot: 98))
        XCTAssertFalse(run(mhz: 3100, hot: 98), "full clocks are not throttling")
        XCTAssertFalse(run(mhz: 1800, hot: 60), "cool and slow is just power management")
    }
}
