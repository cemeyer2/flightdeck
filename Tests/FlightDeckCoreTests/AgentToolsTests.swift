// The tools for coding agents end to end: mark storage and expiry, mark → measure → compare_to through MCPTools,
// the standalone wording, query_metrics downsampling, gaps and size cap, and the cost of measuring a full 24 h box.
import XCTest
@testable import FlightDeckCore

final class AgentToolsTests: XCTestCase {
    typealias X = MeasureFixtures

    func tools(_ src: MCPDataSource, now: Date, marks: MarkStore) -> MCPTools {
        var t = MCPTools(source: src)
        t.now = { now }
        t.marks = marks
        return t
    }

    func call(_ t: MCPTools, _ name: String, _ args: JSON) async throws -> JSON {
        let r = await t.call(name, arguments: args)
        XCTAssertFalse(r.isError, r.text)
        return try JSON.parse(Data(r.text.utf8))
    }

    // MARK: Marks

    func testMarkStorageLookupAndExpiry() throws {
        let store = tempMarks()
        let a = try store.add(label: "  tests-start ", at: X.t0)
        XCTAssertEqual(a.label, "tests-start", "trimmed")
        XCTAssertTrue(a.id.hasPrefix("m-"))
        let b = try store.add(label: "tests-start", at: X.t0)
        XCTAssertNotEqual(a.id, b.id, "two marks in the same millisecond still get distinct ids")
        let c = try store.add(label: "Tests-Start", at: X.t0.addingTimeInterval(100))
        XCTAssertEqual(store.find("tests-start", now: X.t0.addingTimeInterval(200))?.id, c.id, "a label resolves to its latest use")
        XCTAssertEqual(store.find("tests-start", notAfter: X.t0.addingTimeInterval(50), now: X.t0.addingTimeInterval(200))?.id, b.id)
        XCTAssertEqual(store.find(a.id, now: X.t0)?.time, X.t0, "an exact id wins")
        XCTAssertThrowsError(try store.add(label: "   ", at: X.t0))
        // A second store on the same file (the app vs `--mcp`) sees the same marks.
        XCTAssertEqual(MarkStore(url: store.url).all(now: X.t0.addingTimeInterval(1)).count, 3)
        // 48 h later the first three have expired; adding prunes them from the file.
        let later = X.t0.addingTimeInterval(MarkStore.retention + 150)
        XCTAssertEqual(store.all(now: later).map(\.id), [], "c is 48 h + 50 s old")
        try store.add(label: "new", at: later)
        let raw = try JSONDecoder().decode([Mark].self, from: Data(contentsOf: store.url))
        XCTAssertEqual(raw.map(\.label), ["new"], "expired marks are removed from the file on write")
    }

    func testMarkCap() throws {
        let store = tempMarks()
        for i in 0..<(MarkStore.maxMarks + 5) { try store.add(label: "m\(i)", at: X.t0.addingTimeInterval(Double(i))) }
        let all = store.all(now: X.t0.addingTimeInterval(2000))
        XCTAssertEqual(all.count, MarkStore.maxMarks)
        XCTAssertEqual(all.first?.label, "m5", "the oldest go first")
    }

    // MARK: mark → measure → compare_to

    func testMarkMeasureAndCompare() async throws {
        let src = TraceSource()
        // Baseline build at t0 … t0+60; the same build again 1000 s later, with the compilers using twice the CPU time.
        let base = X.build()
        let again: [Snapshot] = base.map { f in
            var g = f; g.time = f.time.addingTimeInterval(1000)
            g.processes = f.processes.map { p in
                var q = p; q.identity.startTime += 1_000_000_000
                if q.name == "swift-frontend" { q.cpuTime *= 2 }
                if q.name == "Safari" { q.cpuTime += 30 }
                return q
            }
            return g
        }
        src.frames = base + again
        let marks = tempMarks()
        try marks.add(label: "baseline-start", at: X.t0.addingTimeInterval(10)); try marks.add(label: "baseline-end", at: X.t0.addingTimeInterval(60))
        let now = X.t0.addingTimeInterval(1070)
        let t = tools(src, now: now, marks: marks)
        let start = try await call(t, "mark", ["label": "change-start"])
        XCTAssertEqual(start["label"]?.string, "change-start")
        XCTAssertEqual(start["black_box"]?.string, "recording")
        // Back-date the change marks to the second build.
        try marks.add(label: "change-start", at: X.t0.addingTimeInterval(1010)); try marks.add(label: "change-end", at: X.t0.addingTimeInterval(1060))
        let j = try await call(t, "measure", ["from": "change-start", "to": "change-end", "process": "xcodebuild",
                                              "compare_to": ["from": "baseline-start", "to": "baseline-end"]])
        XCTAssertEqual(j["filter"]?["cpu_seconds"]?.double, 29, "10 + 3 × 6 + 1")
        XCTAssertEqual(j["filter"]?["processes_seen"]?.int, 5)
        let verdict = try XCTUnwrap(j["comparison"]?["verdict"]?.string)
        XCTAssertTrue(verdict.contains("hungrier"), verdict)
        XCTAssertTrue(verdict.contains("CPU time 45% higher"), verdict)
        XCTAssertNotNil(j["comparison"]?["whole_mac"], "whole-Mac context when a filter is given")
        XCTAssertNotNil(j["accuracy_note"]?.string?.range(of: "lower bounds"))
        XCTAssertEqual(j["window"]?["from_mark"]?.string?.hasPrefix("change-start"), true)
        // Whole Mac, no filter: the system block and rankings.
        let w = try await call(t, "measure", ["from": "change-start", "to": "change-end"])
        XCTAssertEqual(w["system"]?["cpu_percent"]?["avg"]?.double, 50)
        XCTAssertEqual(w["top_processes"]?["by_cpu_seconds"]?.array?.first?.array?.first?.string, "Safari")
        XCTAssertEqual(w["system"]?["energy_wh"]?.double, 0.5, "36 W × 50 s")
        let marksList = try await call(t, "marks", [:])
        XCTAssertEqual(marksList["rows"]?.array?.first?.array?[1].string, "change-start", "newest first: the one the tool set at now")
    }

    func testMeasureArgumentErrors() async throws {
        let src = TraceSource(); src.frames = X.build()
        let t = tools(src, now: X.t0.addingTimeInterval(70), marks: tempMarks())
        for (args, text) in [(["from": "nope"] as JSON, "there are no marks yet"), (["from": "-1m", "to": "-2m"], "must be before"),
                             (["from": "-25h"], "only keeps the last 24 h"), (["from": "-1m", "process": "a", "app": "b"], "not both"),
                             (["from": "-1m", "process": "ghost"], "Busiest recorded")] {
            let r = await t.call("measure", arguments: args)
            XCTAssertTrue(r.isError && r.text.contains(text), "\(args.text): \(r.text)")
        }
    }

    // MARK: Standalone

    /// `--mcp` without the app: marks are still stored, and measuring an unrecorded window says why, plainly.
    func testStandaloneSaysMeasuringNeedsTheApp() async throws {
        let src = TraceSource(); src.standalone = true
        let marks = tempMarks()
        let t = tools(src, now: X.t0, marks: marks)
        let m = try await call(t, "mark", ["label": "start"])
        XCTAssertEqual(m["source"]?.string, "standalone")
        XCTAssertTrue(m["black_box"]?.string?.hasPrefix("not recording") == true)
        XCTAssertEqual(marks.all(now: X.t0).count, 1, "the mark is stored for the app to show later")
        let j = try await call(t, "measure", ["from": "-5m"])
        let s = try XCTUnwrap(j["summary"]?.string)
        XCTAssertTrue(s.hasPrefix("Can't measure") && s.contains("standalone") && s.contains("Open FlightDeck"), s)
    }
}
