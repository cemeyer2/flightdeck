// `measure` logic on synthetic traces: per-process costs from cumulative counters, process-tree aggregation through
// recorded ancestry, system totals and gaps, and `compare_to` deltas and verdicts.
import XCTest
@testable import FlightDeckCore

final class MeasureTests: XCTestCase {
    typealias X = MeasureFixtures
    let from = MeasureFixtures.t0.addingTimeInterval(10), to = MeasureFixtures.t0.addingTimeInterval(60)

    func measured() -> WindowMeasurement { WindowMeasurement.compute(X.build(), interval: 10, from: from, to: to) }

    /// Processes born in the window are charged their whole counter even when seen once; a process running across the
    /// window start is charged from its last pre-window sighting.
    func testCumulativeCPUTime() throws {
        let m = measured()
        let byName = Dictionary(m.processes.values.map { ($0.name + "#\($0.identity.pid)", $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byName["xcodebuild#200"]?.cpuSeconds, 10, "born at t0+12, so from 0, not from its first sighting (2)")
        XCTAssertEqual(byName["xcodebuild#200"]?.startedInWindow, true)
        XCTAssertEqual(byName["swift-frontend#302"]?.cpuSeconds, 3, "one sighting is enough for a short-lived child")
        XCTAssertEqual(byName["Safari#50"]?.cpuSeconds, 30, "130 at the end minus 100 at the baseline frame before the window")
        XCTAssertEqual(byName["zsh#100"]?.cpuSeconds, 0)
        XCTAssertEqual(byName["xcodebuild#200"]?.energyJoules, 100)
        XCTAssertEqual(byName["xcodebuild#200"]?.peakMemory, 300 << 20)
        XCTAssertEqual(m.topProcesses(\.cpuSeconds, 1).first?.name, "Safari")
        XCTAssertEqual(m.topApps(\.cpuSeconds, 1).first?.name, "Safari")
    }

    /// The tree is the root and every recorded descendant, matched through PID + start time; an orphan whose parent was
    /// never recorded, and an older process with a reused PID, stay out.
    func testProcessTreeIncludesChildren() throws {
        let m = measured()
        let tree = try XCTUnwrap(m.tree(process: "xcodebuild", app: nil, frames: X.build()))
        XCTAssertEqual(tree.processes, 5, "xcodebuild, three compilers, one helper")
        XCTAssertEqual(tree.spawned, 5)
        XCTAssertEqual(tree.cpuSeconds, 20, "10 + 3 × 3 + 1")
        XCTAssertEqual(tree.diskBytes, 3_000_000)
        XCTAssertEqual(tree.byName.first?.name, "xcodebuild")
        XCTAssertEqual(tree.byName.first { $0.name == "swift-frontend" }?.count, 3)
        // Peak memory is the largest per-frame sum: at t0+30, xcodebuild 300 MB + two compilers + helper.
        XCTAssertEqual(tree.peakMemory, (300 << 20) + 2 * (500 << 20) + (100 << 20))
        let byPID = try XCTUnwrap(m.tree(process: "200", app: nil, frames: X.build()))
        XCTAssertEqual(byPID.cpuSeconds, 20, "a PID selects the same tree")
        let zsh = try XCTUnwrap(m.tree(process: "zsh", app: nil, frames: X.build()))
        XCTAssertEqual(zsh.cpuSeconds, 20, "the shell's tree includes the build (zsh itself used nothing in the window)")
        XCTAssertNil(m.tree(process: "nonexistent", app: nil, frames: X.build()))
        XCTAssertEqual(m.tree(process: nil, app: "safari", frames: X.build())?.cpuSeconds, 30, "app names match case-insensitively")
    }

    /// Restricted processes whose counters the kernel refused have no CPU time, not 0.
    func testUnreadableCountersAreNil() {
        var p = X.proc("root-thing", pid: 9, ppid: 1, start: X.t0.addingTimeInterval(15), cpuTime: 0)
        p.restricted = true
        let frames = [X.frame(X.t0.addingTimeInterval(20), [p])]
        let m = WindowMeasurement.compute(frames, interval: 10, from: from, to: to)
        XCTAssertNil(m.processes.values.first?.cpuSeconds)
        XCTAssertTrue(m.topProcesses(\.cpuSeconds, 5).isEmpty, "not ranked as 0")
    }

    /// System figures: counters integrate exactly, energy over recorded time only, gaps are reported, and a metric
    /// no frame measured is nil.
    func testSystemTotalsAndGaps() throws {
        let t = { (s: Double) in X.t0.addingTimeInterval(s) }
        // 1 Hz for 10 s, a 21 s gap, 1 Hz for 10 s. Disk counter +1 MB/s throughout (it keeps counting in the gap).
        let frames = (Array(0..<10) + Array(30..<40)).map { i in
            X.frame(t(Double(i)), [], cpu: 40, watts: 36, hottest: i >= 30 ? 90 : 60, diskTotal: UInt64(i) * 1_000_000, netTotal: UInt64(i) * 4000, thermal: i >= 30 ? 2 : 0)
        }
        let m = WindowMeasurement.compute(frames, interval: 1, from: t(0), to: t(39))
        XCTAssertEqual(m.frames, 20)
        XCTAssertEqual(m.recordedSeconds, 19, accuracy: 0.01, "9 × 1 s, one interval after the gap, 9 × 1 s; the first frame sits at `from`")
        XCTAssertEqual(m.gaps.count, 1)
        XCTAssertEqual(m.gaps.first?.seconds ?? 0, 21, accuracy: 0.01)
        XCTAssertEqual(m.diskRead ?? 0, 39_000_000, accuracy: 1)
        XCTAssertEqual(m.netIn ?? 0, 39 * 4000, accuracy: 1)
        XCTAssertEqual(m.energyWh ?? 0, 36 * 19 / 3600, accuracy: 1e-6, "watts × recorded seconds, not × the gap")
        XCTAssertEqual(m.systemCPUSeconds ?? 0, 0.4 * 10 * 19, accuracy: 1e-6)
        XCTAssertEqual(m.hottest?.peak, 90)
        XCTAssertEqual(m.worstThermalState, 2)
        XCTAssertEqual(m.throttledSeconds, 10, accuracy: 0.01)
        let none = WindowMeasurement.compute(frames.map { var f = $0; f.power.systemWatts = .unavailable("no sensor"); return f },
                                             interval: 1, from: t(0), to: t(39))
        XCTAssertNil(none.energyWh, "unmeasured power is nil, never 0 Wh")
        let empty = WindowMeasurement.compute([], interval: 1, from: t(0), to: t(39))
        XCTAssertNil(empty.cpu); XCTAssertNil(empty.diskRead); XCTAssertEqual(empty.gaps.count, 1)
    }

    func testDeltasAndVerdicts() {
        XCTAssertEqual(MeasureCompare.delta("duration_s", 125, 100)?.verdict, .higher)
        XCTAssertEqual(MeasureCompare.delta("duration_s", 125, 100)?.words, "25% higher")
        XCTAssertEqual(MeasureCompare.delta("cpu_seconds", 300, 100)?.words, "3.0× higher")
        XCTAssertEqual(MeasureCompare.delta("cpu_seconds", 103, 100)?.verdict, .same, "under the 5% noise band")
        XCTAssertEqual(MeasureCompare.delta("cpu_seconds", 0.6, 0.2)?.verdict, .same, "3× but under the 1 CPU-s floor")
        XCTAssertEqual(MeasureCompare.delta("peak_memory", 1e9, 2e9)?.verdict, .lower)
        XCTAssertNil(MeasureCompare.delta("energy_wh", nil, 1), "not measured in one window: no delta, not a 100% drop")

        let slower = [MeasureCompare.delta("duration_s", 130, 100)!, MeasureCompare.delta("cpu_seconds", 200, 100)!,
                      MeasureCompare.delta("peak_memory", 1.0e9, 1.01e9)!]
        let v = MeasureCompare.verdict(slower, subject: "the swift-build process tree")
        XCTAssertTrue(v.hasPrefix("Compared with the baseline, the swift-build process tree was slower and hungrier"), v)
        XCTAssertTrue(v.contains("it took 30% longer"), v)
        XCTAssertTrue(v.contains("CPU time 2.0× higher"), v)
        XCTAssertFalse(v.contains("peak memory"), "unchanged figures aren't listed")
        let faster = [MeasureCompare.delta("duration_s", 70, 100)!, MeasureCompare.delta("cpu_seconds", 60, 100)!]
        XCTAssertTrue(MeasureCompare.verdict(faster, subject: "x").contains("faster and leaner"))
        let same = [MeasureCompare.delta("duration_s", 101, 100)!]
        XCTAssertTrue(MeasureCompare.verdict(same, subject: "x").hasPrefix("No meaningful change"))
    }

    /// With a filter, the tree's figures are compared and whole-Mac levels are left to the context block.
    func testFiguresForATreeExcludeWholeMacLevels() throws {
        let m = measured()
        let f = MeasureFigures(m, tree: m.tree(process: "xcodebuild", app: nil, frames: X.build()))
        XCTAssertEqual(f.cpuSeconds, 20)
        XCTAssertNil(f.avgCPUPercent); XCTAssertNil(f.hottest); XCTAssertNil(f.networkBytes)
        let whole = MeasureFigures(m, tree: nil)
        XCTAssertEqual(whole.avgCPUPercent, 50)
        XCTAssertNotNil(whole.cpuSeconds)
    }
}
