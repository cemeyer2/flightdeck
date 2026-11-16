// Console (log insights) tests: the ndjson parser on lines captured from `log show` / `log stream --style ndjson`
// on macOS 26 (backtraces and unused keys trimmed to keep the file readable; field formats unchanged), timestamp
// parsing, and grouping, sparklines, the memory cap and the noisiest-process summary.
import XCTest
@testable import FlightDeckCore

final class LogInsightsTests: XCTestCase {
    /// Captured lines, in output order: the banner `log stream` prints first, five events, and the final count record
    /// that `log show` ends with.
    static let captured = #"""
    Filtering the log data using "logType == 16 OR logType == 17"
    {"timezoneName":"","messageType":"Fault","eventType":"logEvent","source":null,"formatString":"[DAS] Cannot submit dynamic background task %{public}s: Task is running","userID":501,"subsystem":"com.apple.spotlightknowledge","category":"Scheduler","threadID":14141961,"processImagePath":"\/usr\/libexec\/spotlightknowledged.updater","senderImagePath":"\/System\/Library\/PrivateFrameworks\/SpotlightKnowledgeDaemon.framework\/Versions\/A\/SpotlightKnowledgeDaemon","timestamp":"2026-11-16 13:11:02.856331-0600","eventMessage":"[DAS] Cannot submit dynamic background task com.apple.spotlightknowledged.pipelines.migration.journal-processing: Task is running","processID":650}
    {"timezoneName":"","messageType":"Error","eventType":"logEvent","source":null,"formatString":"AKS: Error: Locked: %u","userID":501,"subsystem":"","category":"","threadID":14144004,"backtrace":{"frames":[{"imageOffset":270688,"imageUUID":"C6AB626B-C582-38AA-BC81-FBF0029AD0F7"}]},"processImagePath":"\/usr\/sbin\/usernoted","timestamp":"2026-11-16 13:11:02.857101-0600","eventMessage":"AKS: Error: Locked: 4294967295","processID":566}
    {"timezoneName":"","messageType":"Error","eventType":"logEvent","source":null,"formatString":"AKS: Error: Locked: %u","userID":501,"subsystem":"","category":"","threadID":14144004,"processImagePath":"\/usr\/sbin\/usernoted","timestamp":"2026-11-16 13:11:02.858665-0600","eventMessage":"AKS: Error: Locked: 4294967295","processID":566}
    {"timezoneName":"","messageType":"Error","eventType":"logEvent","source":null,"formatString":"Couldn't %{public}s %{private}s due to %{public}s","userID":0,"subsystem":"com.apple.defaults","category":"cfprefsd","threadID":14141250,"processImagePath":"\/usr\/sbin\/cfprefsd","timestamp":"2026-11-16 13:10:39.431849-0600","eventMessage":"Couldn't open <private> due to No such file or directory","processID":198}
    {"timezoneName":"","messageType":"Error","eventType":"logEvent","source":null,"formatString":"SID: 0x%X task: %p buffer: %p  buffer->fClientTask = %p not found\n","userID":0,"subsystem":"","category":"","threadID":2705,"processImagePath":"\/kernel","timestamp":"2026-11-16 13:12:00.000000+0000","eventMessage":"SID: 0x0 task: 0x0 buffer: 0x0  buffer->fClientTask = 0x0 not found","processID":0}
    {"count":1671,"finished":1}
    {"timezoneName":"","messageType":"Error","eventType":"logEvent","source":null,"formatString":"cut off by the output cap
    """#

    func entries() -> [LogEntry] { Self.captured.split(separator: "\n").compactMap { LogParser.parse(String($0)) } }

    /// Every real event parses with the right fields; the banner, the count record and a truncated line are skipped
    /// rather than producing a bogus entry.
    func testParsesCapturedLines() throws {
        let e = entries()
        XCTAssertEqual(e.count, 5)
        XCTAssertEqual(e[0].level, .fault)
        XCTAssertEqual(e[0].process, "spotlightknowledged.updater", "process name is the executable's file name")
        XCTAssertEqual(e[0].pid, 650)
        XCTAssertEqual(e[0].subsystem, "com.apple.spotlightknowledge")
        XCTAssertEqual(e[0].category, "Scheduler")
        XCTAssertTrue(e[0].message.hasPrefix("[DAS] Cannot submit"))
        XCTAssertEqual(e[1].subsystem, "", "no subsystem stays empty, not invented")
        XCTAssertEqual(e[4].process, "kernel")
        XCTAssertTrue(e[3].isRedacted)
        XCTAssertFalse(e[0].isRedacted)
        // 13:11:02.856331 at UTC-6 is 19:11:02.856331 UTC.
        XCTAssertEqual(e[0].time.timeIntervalSince1970, 1_794_856_262.856331, accuracy: 1e-5)
        XCTAssertEqual(e[4].time.timeIntervalSince1970, 1_794_834_720, accuracy: 1e-6)
    }

    /// The hand-written timestamp parser agrees with ISO8601DateFormatter, including fractions and both offset signs,
    /// and rejects malformed input.
    func testTimestampParsing() {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(LogParser.parseTimestamp("2024-02-29 23:59:59+0530"), iso.date(from: "2024-02-29T23:59:59+05:30"))
        XCTAssertEqual(LogParser.parseTimestamp("1999-12-31 00:00:00-0800"), iso.date(from: "1999-12-31T00:00:00-08:00"))
        XCTAssertEqual(LogParser.parseTimestamp("2026-01-01 00:00:00.5+0000")!.timeIntervalSince1970,
                       iso.date(from: "2026-01-01T00:00:00Z")!.timeIntervalSince1970 + 0.5, accuracy: 1e-9)
        XCTAssertNil(LogParser.parseTimestamp("yesterday"))
        XCTAssertNil(LogParser.parseTimestamp("2026-13-01 00:00:00+0000"))
    }

    /// Long messages are capped so one dumped plist can't dominate memory.
    func testLongMessagesAreCapped() {
        let long = String(repeating: "x", count: 5000)
        let line = #"{"messageType":"Error","eventType":"logEvent","processImagePath":"\/bin\/a","timestamp":"2026-01-01 00:00:00+0000","eventMessage":"\#(long)","processID":1}"#
        XCTAssertEqual(LogParser.parse(line)?.message.count, LogParser.maxMessageLength + 1)   // + the ellipsis
    }

    /// Grouping by process + subsystem: counts include every entry, groups sort by volume, repeated messages fold into
    /// one sample with a count, the noisiest-process summary sums a process's subsystems, and redactions are counted.
    func testGroupingAndSummary() {
        let agg = LogAggregator(bucketWidth: 60)
        for e in entries() { agg.add(e) }
        let s = agg.summary()
        XCTAssertEqual(s.total, 5); XCTAssertEqual(s.faults, 1); XCTAssertEqual(s.redacted, 1)
        XCTAssertEqual(s.groups.count, 4)
        XCTAssertEqual(s.groups[0].process, "usernoted"); XCTAssertEqual(s.groups[0].count, 2)
        XCTAssertEqual(s.groups[0].samples.count, 1, "identical messages fold into one sample")
        XCTAssertEqual(s.groups[0].samples[0].count, 2)
        XCTAssertEqual(s.noisiestProcesses(1).first?.process, "usernoted")
        XCTAssertEqual(s.noisiestProcesses(1).first!.share, 0.4, accuracy: 1e-9)
        XCTAssertEqual(s.groups(matching: "DEFAULTS").map(\.process), ["cfprefsd"], "filter matches subsystem, case-insensitively")
        XCTAssertEqual(s.groups(matching: "journal-processing").count, 1, "filter matches sample messages")
        XCTAssertEqual(s.groups(matching: "  ").count, 4)
        XCTAssertEqual(s.entries(of: s.groups[0]).count, 2)
        XCTAssertEqual(s.earliest, entries()[4].time); XCTAssertEqual(s.latest, entries()[2].time)
    }

    /// The memory cap keeps only the newest entries (even when they arrive out of order, as chunks do), while counts and
    /// sparklines still cover everything; a group's distinct samples are bounded too.
    func testCapKeepsNewestAndCountsEverything() {
        let agg = LogAggregator(bucketWidth: 10, maxEntries: 100)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Two "chunks", newer first, 300 entries each, one second apart.
        for chunk in [1, 0] {
            for i in 0..<300 {
                agg.add(LogEntry(time: t0.addingTimeInterval(Double(chunk * 300 + i)), level: .error, process: "p", pid: 1,
                                 subsystem: "s", category: "", message: "m\(i % 20)"))
            }
        }
        let s = agg.summary()
        XCTAssertEqual(s.total, 600)
        XCTAssertEqual(s.entries.count, 100)
        XCTAssertEqual(s.entries.first?.time, t0.addingTimeInterval(599), "newest first")
        XCTAssertEqual(s.entries.last?.time, t0.addingTimeInterval(500))
        XCTAssertEqual(s.groups[0].count, 600)
        XCTAssertEqual(s.groups[0].samples.count, LogAggregator.samplesPerGroup)
        let spark = s.groups[0].sparkline(from: t0, to: t0.addingTimeInterval(600), bucketWidth: 10, slots: 6)
        XCTAssertEqual(spark, [100, 100, 100, 100, 100, 100], "sparkline covers all 600 entries evenly")
        XCTAssertEqual(spark.reduce(0, +), 600)
    }

    /// Reads one real minute of the log. Skips where `log` can't run (sandboxed CI, restricted VMs).
    func testReadsTheRealLog() throws {
        let agg = LogAggregator(bucketWidth: 10)
        let r = LogReader().show(window: 60, into: agg) { _ in }
        if case .failed(let m) = r { throw XCTSkip("log show unavailable: \(m)") }
        XCTAssertEqual(r, .finished)
        // Times must fall inside the window (with a little slack for the rounded end).
        if let e = agg.earliest { XCTAssertGreaterThan(e.timeIntervalSinceNow, -62) }
    }

    /// Cancelling stops a running query promptly.
    func testCancelStopsQuery() throws {
        let reader = LogReader(), agg = LogAggregator(bucketWidth: 60)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { reader.cancel() }
        let t = Date()
        let r = reader.show(window: 86_400, into: agg) { _ in }
        if case .failed(let m) = r { throw XCTSkip("log show unavailable: \(m)") }
        XCTAssertEqual(r, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(t), 10)
    }
}
