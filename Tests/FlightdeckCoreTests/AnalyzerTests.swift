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
