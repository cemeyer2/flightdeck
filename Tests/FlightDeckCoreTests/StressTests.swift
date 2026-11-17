// Tests for the Stress Map scoring (Stress.swift): misery = share × stress, attributed to the right app and subsystem,
// hung apps maxed out, and unmeasured data never turned into blame. Snapshots are cloned from one real sample
// (`BlackBoxTests.base`) with every field the scoring reads overridden, so results don't depend on the test machine.
import XCTest
@testable import FlightDeckCore

final class StressTests: XCTestCase {
    /// A process with only the given load; every other metric is zero or absent.
    func proc(_ name: String, path: String, pid: Int32, cpu: Double = 0.5, mem: UInt64 = 50_000_000) -> ProcessSample {
        var p = BlackBoxTests.base.processes[0]; p.restricted = false   // copied from a real process, which may be a restricted system one
        p.identity = ProcessIdentity(pid: pid, startTime: 1); p.name = name; p.path = path
        p.cpu = cpu; p.memory = mem; p.wakeups = 0; p.diskReadBps = 0; p.diskWriteBps = 0
        p.network = nil; p.gpu = nil; p.energyWatts = nil; p.notResponding = nil
        return p
    }

    /// A calm, fully measured machine: low CPU and pressure, no swap or I/O, idle GPU, cool, 8 W.
    func snap(cpu: Double = 5, pressure: Double = 30, procs: [ProcessSample]) -> Snapshot {
        var s = BlackBoxTests.base
        s.cpu.total = .value(cpu); s.processes = procs
        s.memory.total = 16 << 30; s.memory.used = 8 << 30
        s.memory.pressure = .value(pressure); s.memory.pressureLevel = 1; s.memory.swapUsed = .value(0)
        s.disk.readBps = .value(0); s.disk.writeBps = .value(0); s.network.inBps = .value(0); s.network.outBps = .value(0)
        s.gpu = .value(2); s.power.thermalState = 0; s.power.hottest = .value(45); s.power.systemWatts = .value(8)
        return s
    }

    /// A typical set of background apps on an idle Mac.
    var background: [ProcessSample] {
        [proc("Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", pid: 10, cpu: 2, mem: 900_000_000),
         proc("Mail", path: "/System/Applications/Mail.app/Contents/MacOS/Mail", pid: 11, cpu: 1, mem: 400_000_000),
         proc("mds", path: "/usr/libexec/mds", pid: 12, cpu: 1.5, mem: 60_000_000),
         proc("WindowServer", path: "/System/Library/WindowServer", pid: 13, cpu: 4, mem: 300_000_000)]
    }

    /// An idle Mac must show "All quiet": no app above the threshold and every hub calm.
    func testIdleSnapshotHasNoSignificantMisery() {
        let r = Stress.report(snap(procs: background))
        XCTAssertTrue(r.apps.isEmpty, "idle machine blames nobody: \(r.apps.map { ($0.app.name, $0.total) })")
        for h in r.hubs { XCTAssertLessThan(h.stress ?? 0, 0.1, "\(h.subsystem) is calm") }
    }

    /// One app saturating a busy CPU is the top misery causer, with CPU as its main subsystem; helpers roll into it.
    func testCPUHogOnBusyCPUIsTopWithCPUMain() {
        let hog = [proc("Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode", pid: 20, cpu: 600),
                   proc("SourceKitService", path: "/Applications/Xcode.app/Contents/SharedFrameworks/S.framework/SourceKitService", pid: 21, cpu: 300)]
        let r = Stress.report(snap(cpu: 95, procs: background + hog))
        let top = try! XCTUnwrap(r.apps.first)
        XCTAssertEqual(top.app.name, "Xcode")
        XCTAssertEqual(top.main, .cpu)
        XCTAssertGreaterThan(top.contributions[.cpu] ?? 0, 0.8)
        XCTAssertEqual(top.busiest?.pid, 20, "the inspector opens the busiest member process")
        XCTAssertGreaterThan(r.hub(.cpu)?.stress ?? 0, 0.85)
    }

    /// The same CPU share on an idle CPU is no misery: blame needs both share and stress.
    func testShareWithoutStressIsNoMisery() {
        let r = Stress.report(snap(cpu: 8, procs: [proc("Solo", path: "/Applications/Solo.app/Contents/MacOS/Solo", pid: 30, cpu: 60)]))
        XCTAssertTrue(r.apps.isEmpty)
    }

    /// A memory hog under critical pressure is blamed on Memory, not CPU.
    func testMemoryHogUnderPressureAttributesToMemory() {
        var s = snap(cpu: 20, pressure: 92, procs: background + [proc("Docker", path: "/Applications/Docker.app/Contents/MacOS/Docker", pid: 40, cpu: 3, mem: 6 << 30)])
        s.memory.pressureLevel = 4; s.memory.swapUsed = .value(Double(4 << 30))
        let r = Stress.report(s)
        let top = try! XCTUnwrap(r.apps.first)
        XCTAssertEqual(top.app.name, "Docker")
        XCTAssertEqual(top.main, .memory)
        XCTAssertGreaterThan(r.hub(.memory)?.stress ?? 0, 0.85)
    }

    /// A hung app is maximal misery even when it uses nothing, and the inspector targets its hung process.
    func testHungAppMaxesOut() {
        var stuck = proc("Pages", path: "/Applications/Pages.app/Contents/MacOS/Pages", pid: 50, cpu: 0)
        stuck.notResponding = true
        let r = Stress.report(snap(procs: background + [stuck]))
        let top = try! XCTUnwrap(r.apps.first)
        XCTAssertEqual(top.app.name, "Pages")
        XCTAssertTrue(top.hung)
        XCTAssertEqual(top.total, 1)
        XCTAssertEqual(top.busiest?.pid, 50)
    }

    /// Unmeasured subsystems have no stress (nil, not 0) and blame nobody, even for an app that dominates the resource.
    func testUnmeasuredDataIsNoEvidence() {
        var s = snap(procs: [proc("Burn", path: "/Applications/Burn.app/Contents/MacOS/Burn", pid: 60, cpu: 800)])
        s.cpu.total = .unavailable("warming up"); s.gpu = .unavailable("n/a"); s.power.systemWatts = .unavailable("desktop")
        s.disk.readBps = .unavailable("warming up"); s.disk.writeBps = .unavailable("warming up")
        let r = Stress.report(s)
        XCTAssertNil(r.hub(.cpu)?.stress); XCTAssertNil(r.hub(.gpu)?.stress)
        XCTAssertNil(r.hub(.energy)?.stress); XCTAssertNil(r.hub(.disk)?.stress)
        XCTAssertEqual(r.hub(.cpu)?.reading, "—")
        XCTAssertTrue(r.apps.allSatisfy { $0.contributions[.cpu] == nil })
    }

    /// Heavy disk traffic is blamed on the app doing it, with Disk as its main subsystem.
    func testDiskTrafficAttributesToDisk() {
        var copier = proc("Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", pid: 70, cpu: 5)
        copier.diskWriteBps = 300 * 1_048_576
        var s = snap(cpu: 15, procs: background + [copier])
        s.disk.writeBps = .value(310 * 1_048_576)
        let top = try! XCTUnwrap(Stress.report(s).apps.first)
        XCTAssertEqual(top.app.name, "Finder"); XCTAssertEqual(top.main, .disk)
    }

    /// `combine` stays in 0…1, never drops below the largest part, and rewards hurting several things.
    func testCombineAndRamp() {
        XCTAssertEqual(Stress.combine([]), 0)
        XCTAssertEqual(Stress.combine([0.5, 0.5]), 0.75, accuracy: 1e-9)
        XCTAssertEqual(Stress.combine([1, 0.3]), 1)
        XCTAssertEqual(Stress.ramp(0.6, knee: 0.6, kneeStress: 0.25), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Stress.ramp(1.5, knee: 0.6, kneeStress: 0.25), 1)
        XCTAssertEqual(Stress.ramp(-1, knee: 0.6, kneeStress: 0.25), 0)
    }
}
