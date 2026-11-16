// Tests for the power-user tools in core: the footprint / vmmap parsers behind the inspector's memory breakdown, the
// launch/exit diff and respawn detection behind the Launches view, the command palette's fuzzy matcher, and the
// diagnostic capture's process selection, summary and log cap. Tool fixtures are in MemoryFixtures.swift.
import XCTest
@testable import FlightDeckCore

final class MemoryBreakdownTests: XCTestCase {
    /// Default `footprint <pid>` output (formatted units, no swapped column) for a tiny process (`sleep`).
    static let footprintFormatted = #"""
    ======================================================================
    sleep [34830]: 64-bit    Footprint: 1024 KB (16384 bytes per page)
    ======================================================================

      Dirty      Clean  Reclaimable    Regions    Category
        ---        ---          ---        ---    ---
     400 KB        0 B          0 B          9    Malloc Metadata
     176 KB        0 B          0 B          1    page table
     117 KB        0 B          0 B         71    __DATA_DIRTY
      84 KB        0 B          0 B        190    unused dyld shared cache area
      48 KB        0 B          0 B          2    Malloc Small
      32 KB        0 B          0 B          1    Malloc Tiny
      32 KB        0 B          0 B          5    Untagged
      32 KB        0 B          0 B          2    Stack
        0 B      16 KB          0 B         83    __TEXT
        0 B        0 B          0 B          1    mapped file
        ---        ---          ---        ---    ---
    1024 KB      48 KB          0 B        501    TOTAL

    Auxiliary data:
        phys_footprint: 1024 KB
        phys_footprint_peak: 1040 KB
    """#

    func testFootprintBytes() throws {
        let b = try XCTUnwrap(MemoryBreakdownReader.parseFootprint(MemoryFixtures.footprintBytes))
        XCTAssertEqual(b.source, .footprint)
        XCTAssertEqual(b.footprint, 253_248_616)
        XCTAssertEqual(b.peak, 314_623_056)
        XCTAssertFalse(b.categories.contains { $0.name == "TOTAL" })
        let small = try XCTUnwrap(b.categories.first { $0.name == "Malloc Small" })
        // Dirty 185139200 includes 30556160 swapped; resident dirty is the difference.
        XCTAssertEqual(small.swapped, 30_556_160)
        XCTAssertEqual(small.dirty, 185_139_200 - 30_556_160)
        XCTAssertEqual(small.footprint, 185_139_200)
        XCTAssertEqual(small.reclaimable, 9_895_936)
        XCTAssertEqual(small.regions, 208)
        XCTAssertEqual(small.group, .malloc)
        // Multi-word categories with parentheses keep their full name.
        let g = try XCTUnwrap(b.categories.first { $0.name == "Owned physical footprint (unmapped) (graphics)" })
        XCTAssertEqual(g.group, .graphics)
        XCTAssertEqual(b.categories.first { $0.name == "IOSurface" }?.group, .graphics)
        XCTAssertEqual(b.categories.first { $0.name == "mapped file" }?.clean, 53_936_128)
        XCTAssertEqual(b.categories.first { $0.name == "mapped file" }?.group, .mappedFiles)
        XCTAssertEqual(b.categories.first { $0.name == "__TEXT" }?.group, .code)
        XCTAssertEqual(b.categories.first { $0.name == "page table" }?.group, .kernel)
        XCTAssertEqual(b.categories.first { $0.name == "Stack" }?.group, .stack)
        // Category footprints add up to the TOTAL row (= the process footprint), and the column totals match too.
        XCTAssertEqual(b.categories.reduce(0) { $0 + $1.footprint }, 253_248_616)
        XCTAssertEqual(b.totalSwapped, 79_265_792)
        XCTAssertEqual(b.totalClean, 64_307_200)
        XCTAssertEqual(b.groups.first?.group, .malloc, "the heap dominates Finder")
        XCTAssertEqual(b.groups.reduce(0) { $0 + $1.footprint }, 253_248_616, "grouping loses nothing")
    }

    func testFootprintFormattedWithoutSwap() throws {
        let b = try XCTUnwrap(MemoryBreakdownReader.parseFootprint(Self.footprintFormatted))
        XCTAssertEqual(b.footprint, 1024 * 1024)
        XCTAssertEqual(b.peak, 1040 * 1024)
        let meta = try XCTUnwrap(b.categories.first { $0.name == "Malloc Metadata" })
        XCTAssertEqual(meta.dirty, 400 * 1024)
        XCTAssertNil(meta.swapped, "no swapped column: unknown, not zero")
        XCTAssertNil(b.totalSwapped)
        XCTAssertNil(b.groups.first?.swapped)
        XCTAssertEqual(b.categories.first { $0.name == "unused dyld shared cache area" }?.group, .code)
        XCTAssertEqual(b.categories.count, 10)
    }

    func testVmmapSummary() throws {
        let b = try XCTUnwrap(MemoryBreakdownReader.parseVmmapSummary(MemoryFixtures.vmmapSummary))
        let mb = { (v: Double) in UInt64((v * 1_048_576).rounded()) }
        XCTAssertEqual(b.source, .vmmap)
        XCTAssertEqual(b.footprint, mb(241.5))
        XCTAssertEqual(b.peak, mb(300))
        let small = try XCTUnwrap(b.categories.first { $0.name == "Malloc Small" })
        XCTAssertEqual(small.dirty, mb(147.3))
        XCTAssertEqual(small.swapped, mb(28.8))
        XCTAssertEqual(small.clean, mb(154.6) - mb(147.3), "clean = resident - dirty")
        XCTAssertEqual(small.regions, 863)
        // Names with spaces, and rows with a trailing note column.
        XCTAssertNotNil(b.categories.first { $0.name == "AttributeGraph Data (old mapping)" })
        XCTAssertEqual(b.categories.first { $0.name == "Malloc Small (empty)" }?.group, .malloc)
        XCTAssertEqual(b.categories.first { $0.name == "unused but dirty shlib __DATA" }?.group, .code)
        XCTAssertEqual(b.categories.first { $0.name == "page table in kernel" }?.group, .kernel)
        // Bare byte counts ("72") parse; reserved-only regions (guard pages, reserved stack) are dropped.
        XCTAssertEqual(b.categories.first { $0.name == "Dyld Private Memory" }?.dirty, 72)
        XCTAssertNil(b.categories.first { $0.name == "Guard" })
        XCTAssertNil(b.categories.first { $0.name == "Stack Guard" })
        XCTAssertNil(b.categories.first { $0.name == "Stack (reserved)" })
        // The MALLOC ZONE table below TOTAL must not leak in, nor the TOTAL rows themselves.
        XCTAssertNil(b.categories.first { $0.name.hasPrefix("DefaultMallocZone") || $0.name.hasPrefix("TOTAL") })
        XCTAssertEqual(b.groups.first?.group, .malloc)
    }

    func testGarbageIsNil() {
        XCTAssertNil(MemoryBreakdownReader.parseFootprint("footprint: unable to get task for pid 1: (os/kern) failure"))
        XCTAssertNil(MemoryBreakdownReader.parseVmmapSummary("vmmap cannot examine process 1 because you do not have appropriate privileges"))
        XCTAssertNil(MemoryBreakdownReader.parseFootprint(""))
        XCTAssertNil(MemoryBreakdownReader.parseVmmapSummary(""))
    }

    func testSizes() {
        XCTAssertEqual(MemoryBreakdownReader.size("2048K"), 2048 * 1024)
        XCTAssertEqual(MemoryBreakdownReader.size("1.5G"), 1_610_612_736)
        XCTAssertEqual(MemoryBreakdownReader.size("824"), 824)
        XCTAssertEqual(MemoryBreakdownReader.size("9664", unit: "KB"), 9664 * 1024)
        XCTAssertNil(MemoryBreakdownReader.size("(empty)"))
        XCTAssertNil(MemoryBreakdownReader.size("12", unit: "XB"))
    }

    /// The real tools against this test process (always the user's own). Another user's process is refused up front.
    func testLiveOwnProcess() throws {
        if getuid() != 0, case .failure(let f) = MemoryBreakdownReader.read(pid: 1, ownedByUser: false) {
            XCTAssertEqual(f, .notOwnProcess)
        }
        guard case .success(let b) = MemoryBreakdownReader.read(pid: getpid(), ownedByUser: true) else {
            throw XCTSkip("footprint/vmmap can't read this process here")
        }
        XCTAssertFalse(b.categories.isEmpty)
        XCTAssertGreaterThan(b.footprint ?? 0, 0)
    }
}

final class LaunchLogTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A process sample with just the fields LaunchLog uses; `started` is seconds after `t0`.
    func proc(_ pid: Int32, _ name: String, started: Double, ppid: Int32 = 1, path: String? = nil) -> ProcessSample {
        let start = UInt64((t0.timeIntervalSince1970 + started) * 1e6)
        return ProcessSample(identity: ProcessIdentity(pid: pid, startTime: start), ppid: ppid, name: name, path: path ?? "/usr/bin/\(name)",
                             user: "me", uid: 501, cpu: 0, cpuTime: 0, memory: 0, threads: 1, diskReadBps: 0, diskWriteBps: 0,
                             diskRead: 0, diskWritten: 0, energyWatts: nil, wakeups: 0, restricted: false)
    }

    func log() -> LaunchLog { let l = LaunchLog(capacity: 50); l.isAlive = { _ in false }; return l }

    func testFirstSampleIsBaselineThenDiff() {
        let l = log()
        let launchd = proc(1, "launchd", started: -10_000, ppid: 0), a = proc(100, "a", started: -50, ppid: 1)
        l.ingest([launchd, a], at: t0)
        XCTAssertTrue(l.events.isEmpty, "everything already running is not a launch")
        // b starts between the samples; a exits.
        let b = proc(200, "b", started: 0.4, ppid: 1)
        l.ingest([launchd, b], at: t0.addingTimeInterval(1))
        let ev = l.events
        XCTAssertEqual(ev.count, 2)
        let launch = ev.first { $0.kind == .launch }, exit = ev.first { $0.kind == .exit }
        XCTAssertEqual(launch?.identity.pid, 200)
        XCTAssertEqual(launch?.parentName, "launchd")
        XCTAssertEqual(launch?.time.timeIntervalSince1970 ?? 0, t0.timeIntervalSince1970 + 0.4, accuracy: 0.001)
        XCTAssertEqual(exit?.identity.pid, 100)
        XCTAssertEqual(exit?.lastSeen, t0)
        XCTAssertEqual(exit?.lifetime ?? 0, 51, accuracy: 0.001)
        // Nothing changes: nothing new.
        l.ingest([launchd, b], at: t0.addingTimeInterval(2))
        XCTAssertEqual(l.events.count, 2)
    }

    /// A recycled PID is a different identity: one exit and one launch, not "no change".
    func testRecycledPID() {
        let l = log()
        l.ingest([proc(300, "old", started: -100)], at: t0)
        l.ingest([proc(300, "new", started: 0.5)], at: t0.addingTimeInterval(1))
        XCTAssertEqual(l.events.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.exit, .launch])
        XCTAssertEqual(l.events.first { $0.kind == .launch }?.name, "new")
    }

    /// A process that only became readable now (its start time is old) isn't reported as a launch, and one with an
    /// unknown start time is ignored.
    func testOldOrUnknownStartIsNotALaunch() {
        let l = log()
        l.ingest([], at: t0)
        var unknown = proc(400, "u", started: 0); unknown.identity.startTime = 0
        l.ingest([proc(401, "late", started: -3600), unknown], at: t0.addingTimeInterval(1))
        XCTAssertTrue(l.events.isEmpty)
    }

    /// Missing from one sample but still alive (the PID's identity is unchanged): no exit is recorded, and it isn't a
    /// new launch when it reappears.
    func testTransientMissIsNotAnExit() {
        let l = LaunchLog(capacity: 50)
        let p = proc(500, "p", started: -10)
        l.isAlive = { $0 == p.identity }
        l.ingest([p], at: t0)
        l.ingest([], at: t0.addingTimeInterval(1))
        l.ingest([p], at: t0.addingTimeInterval(2))
        XCTAssertTrue(l.events.isEmpty)
    }

    func testRingBufferKeepsNewest() {
        let l = log()
        l.ingest([], at: t0)
        for i in 1...200 {
            l.ingest([proc(Int32(1000 + i), "x", started: Double(i) - 0.5)], at: t0.addingTimeInterval(Double(i)))
        }
        let ev = l.events
        XCTAssertLessThanOrEqual(ev.count, 55, "capacity 50 plus at most 10% slack before a batch trim")
        XCTAssertGreaterThanOrEqual(ev.count, 50)
        // Newest first: the last sample noticed 1199's exit (t = 200), just after 1200 started (t = 199.5).
        XCTAssertEqual(ev.first?.identity.pid, 1199)
        XCTAssertEqual(ev.first?.kind, .exit)
        XCTAssertEqual(ev.first { $0.kind == .launch }?.identity.pid, 1200)
        XCTAssertTrue(zip(ev, ev.dropFirst()).allSatisfy { $0.time >= $1.time })
    }

    /// 25 launches of the same tool within 5 minutes trips the respawn finding (limit 20); `since` stays fixed while it
    /// lasts, and it clears once the launches age out of the window.
    func testRespawnFinding() {
        let l = log()
        l.ingest([], at: t0)
        var now = t0
        for i in 1...25 {
            now = t0.addingTimeInterval(Double(i) * 10)
            // each instance lives under 10 s: launched in one sample, gone by the next
            l.ingest([proc(Int32(2000 + i), "crashy", started: Double(i) * 10 - 0.5, path: "/Library/Crashy/crashy")], at: now)
        }
        let f = l.findings(now: now)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f.first?.id, "respawn:/Library/Crashy/crashy")
        XCTAssertEqual(f.first?.destination, "Launches")
        XCTAssertTrue(f.first?.title.contains("25 times") ?? false, f.first?.title ?? "")
        let since = f.first?.since
        XCTAssertEqual(l.findings(now: now.addingTimeInterval(1)).first?.since, since, "stable since")
        XCTAssertTrue(l.findings(now: now.addingTimeInterval(400)).isEmpty, "aged out of the 5-minute window")

        let groups = l.groups(window: 600, now: now)
        XCTAssertEqual(groups.first?.name, "crashy")
        XCTAssertEqual(groups.first?.launches, 25)
        XCTAssertEqual(groups.first?.exits, 24)
    }

    func testBelowLimitIsQuiet() {
        let l = log()
        l.ingest([], at: t0)
        for i in 1...20 { l.ingest([proc(Int32(3000 + i), "ok", started: Double(i) - 0.5)], at: t0.addingTimeInterval(Double(i))) }
        XCTAssertTrue(l.findings(now: t0.addingTimeInterval(21)).isEmpty, "exactly the limit is not 'more than'")
    }

    /// Cost stays linear: 5,000 processes diffed 20 times well within a sampling budget.
    func testDiffIsCheap() {
        let l = log()
        let procs = (0..<5000).map { proc(Int32(10_000 + $0), "p\($0)", started: -100) }
        l.ingest(procs, at: t0)
        let start = Date()
        for i in 1...20 { l.ingest(procs, at: t0.addingTimeInterval(Double(i))) }
        XCTAssertLessThan(Date().timeIntervalSince(start) / 20, 0.02, "per-sample diff of 5,000 processes")
    }
}

final class FuzzyMatchTests: XCTestCase {
    func testRanking() {
        XCTAssertNotNil(FuzzyMatch.score("fl", "Flight Log"))
        XCTAssertNil(FuzzyMatch.score("xyz", "Flight Log"))
        XCTAssertEqual(FuzzyMatch.score("", "anything"), 0)
        // Prefix beats a word-start substring, which beats a scattered subsequence.
        let prefix = FuzzyMatch.score("perf", "Performance")!, word = FuzzyMatch.score("perf", "Go to Performance")!
        let scattered = FuzzyMatch.score("perf", "Power & Freq")
        XCTAssertGreaterThan(prefix, word)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(word, scattered!)
        // Word starts: "sbb" finds "Save from Black Box".
        XCTAssertNotNil(FuzzyMatch.score("sbb", "Save from Black Box"))
        XCTAssertNotNil(FuzzyMatch.score("flight log", "Flight Log"))
        XCTAssertNotNil(FuzzyMatch.score("SAF", "safari"), "case-insensitive")
    }
}

final class DiagnosticCaptureTests: XCTestCase {
    func sample(_ pid: Int32, cpu: Double, uid: UInt32, hung: Bool? = nil) -> ProcessSample {
        var p = ProcessSample(identity: ProcessIdentity(pid: pid, startTime: 1), ppid: 1, name: "p\(pid)", path: "", user: "u", uid: uid,
                              cpu: cpu, cpuTime: 0, memory: 0, threads: 1, diskReadBps: 0, diskWriteBps: 0, diskRead: 0, diskWritten: 0,
                              energyWatts: nil, wakeups: 0, restricted: false)
        p.notResponding = hung
        return p
    }

    /// Top 3 by CPU among the user's own processes, plus hung apps; other users' and FlightDeck itself are excluded.
    func testTargets() {
        let procs = [sample(10, cpu: 300, uid: 0), sample(11, cpu: 90, uid: 501), sample(12, cpu: 80, uid: 501), sample(13, cpu: 70, uid: 501),
                     sample(14, cpu: 60, uid: 501), sample(15, cpu: 1, uid: 501, hung: true), sample(16, cpu: 500, uid: 501), sample(17, cpu: 0, uid: 88, hung: true)]
        let t = DiagnosticCapture.targets(procs, uid: 501, exclude: 16)
        XCTAssertEqual(t.map(\.identity.pid), [11, 12, 13, 15])
        XCTAssertEqual(t.last?.reason, "not responding")
    }

    /// The summary leaves out machine identifiers and prints unmeasured values as "—".
    func testSummaryOmitsIdentifiers() {
        let info = [InfoItem(section: "System", key: "Serial Number", value: "SERIAL123"), InfoItem(section: "System", key: "Hardware UUID", value: "UUID-1"),
                    InfoItem(section: "System", key: "Model", value: "Mac99,1")]
        let text = DiagnosticCapture.summaryText(snapshot: nil, findings: [], info: info)
        XCTAssertFalse(text.contains("SERIAL123")); XCTAssertFalse(text.contains("UUID-1"))
        XCTAssertTrue(text.contains("Mac99,1"))
    }

    /// A whole capture with nothing to sample: folder layout, README with the privacy note, progress for every step,
    /// and the zip replacing the folder.
    func testRunWritesFolderAndZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = DiagnosticCapture.Input(blackBox: nil, summary: "hello", targets: [], reportsSince: Date())
        let seen = NSLock(); nonisolated(unsafe) var updates = 0
        let folder = dir.appendingPathComponent("Capture")
        let (url, steps) = DiagnosticCapture.run(input, into: folder, zip: false) { _ in seen.lock(); updates += 1; seen.unlock() }
        XCTAssertEqual(url, folder)
        XCTAssertEqual(steps.first { $0.id == "blackbox" }?.state, .skipped)
        XCTAssertEqual(steps.first { $0.id == "stacks" }?.state, .skipped)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("summary.txt"), encoding: .utf8), "hello")
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("README.txt"), encoding: .utf8).contains("REVIEW BEFORE SHARING"))
        XCTAssertGreaterThanOrEqual(updates, steps.count * 2, "a running and a final update per step")

        let (zipURL, _) = DiagnosticCapture.run(input, into: dir.appendingPathComponent("Zipped"), zip: true) { _ in }
        XCTAssertEqual(zipURL.pathExtension, "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Zipped").path), "folder removed after zipping")
    }

    /// The real `log show`, cut at a tiny cap: the file stops near the cap and says it was cut.
    func testLogCap() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("fd-log-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: f) }
        guard let (bytes, truncated) = DiagnosticCapture.captureLog(to: f, limit: 4096) else { throw XCTSkip("log unavailable") }
        XCTAssertLessThanOrEqual(bytes, 4096)
        let size = try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 4096 + 200)
        if truncated { XCTAssertTrue(try String(contentsOf: f, encoding: .utf8).contains("cut at")) }
    }
}
