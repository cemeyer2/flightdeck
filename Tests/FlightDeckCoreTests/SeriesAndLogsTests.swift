// query_metrics (downsampling, gaps as null, the size cap), process_logs (grouping captured ndjson, predicates, a
// real read where allowed), the new tools' schemas and annotations, and the cost of measuring a full 24 h black box.
import XCTest
@testable import FlightDeckCore

final class SeriesAndLogsTests: XCTestCase {
    typealias X = MeasureFixtures

    // MARK: query_metrics

    /// 1 Hz for 10 s, a gap, 1 Hz again: 5 s slots average CPU, take the max temperature, and are null in the gap.
    func testDownsamplingAndGaps() throws {
        let t = { (s: Double) in X.t0.addingTimeInterval(s) }
        let clang = X.proc("clang", pid: 7, ppid: 1, start: t(-1), cpuTime: 1, mem: 1 << 20)
        let seconds: [Int] = Array(0..<10) + Array(30..<40)
        let frames: [Snapshot] = seconds.map { (i: Int) -> Snapshot in
            let procs: [ProcessSample] = i % 2 == 0 ? [clang] : []
            return X.frame(t(Double(i)), procs, cpu: Double(i * 10), watts: nil, hottest: Double(i))
        }
        let ms = ["cpu", "hottest_c", "watts", "process:clang.rss"].compactMap(MetricSeries.metric)
        XCTAssertEqual(ms.count, 4)
        let v = MetricSeries.series(frames, metrics: ms, from: t(0), step: 5, count: 8)
        XCTAssertEqual(v[0][0], 20, "average of 0, 10, 20, 30, 40")
        XCTAssertEqual(v[1][0], 4, "maximum")
        XCTAssertEqual(v[0][2], nil, "the gap is null, not 0")
        XCTAssertEqual(v[0][6], 320)
        XCTAssertTrue(v[2].allSatisfy { $0 == nil }, "an unmeasured metric is all null")
        XCTAssertEqual(v[3][0], 1, "1 MB")
        XCTAssertNil(MetricSeries.metric("process:clang.bogus"))
        XCTAssertNil(MetricSeries.metric("cpu_total"))
        // A frame without the process gives null for it, even while the system metrics have values.
        let odd = MetricSeries.series([frames[1]], metrics: ms, from: t(0), step: 1, count: 2)
        XCTAssertNil(odd[3][1]); XCTAssertEqual(odd[0][1], 10)
        XCTAssertEqual(MetricSeries.autoStep(span: 86_400, minStep: 10, maxPoints: 300), 300)
        XCTAssertEqual(MetricSeries.autoStep(span: 3600, minStep: 1, maxPoints: 300), 15)
        XCTAssertEqual(MetricSeries.autoStep(span: 60, minStep: 2, maxPoints: 300), 2, "never below the sampling interval")
    }

    func testQueryMetricsToolAndSizeCap() async throws {
        let src = TraceSource(); src.interval = 10
        let now = X.t0.addingTimeInterval(86_000)
        src.frames = stride(from: 0.0, to: 86_000, by: 10).map { X.frame(X.t0.addingTimeInterval($0), [], cpu: 30) }
        var t = MCPTools(source: src); t.now = { now }; t.marks = tempMarks()
        let r = await t.call("query_metrics", arguments: ["metrics": ["cpu", "memory_used", "swap", "disk_read", "disk_write", "net_in",
                                                                       "net_out", "watts", "hottest_c", "gpu", "battery_pct", "cpu_user"],
                                                          "from": "-23h", "step": 10])
        XCTAssertTrue(r.isError && r.text.contains("Use step"), r.text)
        let ok = await t.call("query_metrics", arguments: ["metrics": ["cpu", "battery_pct"], "from": "-23h"])
        XCTAssertFalse(ok.isError, ok.text)
        let j = try JSON.parse(Data(ok.text.utf8))
        XCTAssertEqual(j["step_s"]?.double, 300, "automatic step: at most 300 points")
        XCTAssertEqual(j["t"]?.array?.count, j["points"]?.int)
        XCTAssertEqual(j["t"]?.array?[1].double, 300, "offsets from start")
        XCTAssertEqual(j["series"]?["cpu"]?.array?.first?.double, 30)
        XCTAssertEqual(j["series"]?["battery_pct"]?.array?.first, .null, "no battery: null, never 0")
        XCTAssertLessThan(ok.text.utf8.count, MCPServer.maxToolTextBytes)
        let bad = await t.call("query_metrics", arguments: ["metrics": ["cpu", "warp_drive"]])
        XCTAssertTrue(bad.isError && bad.text.contains("warp_drive"))
    }

    // MARK: process_logs

    /// Captured `log show --style ndjson` lines (fields trimmed): default and info messages from one process, two of
    /// which differ only in a number.
    static let captured = #"""
    {"messageType":"Default","eventType":"logEvent","subsystem":"com.example.build","category":"net","processImagePath":"\/usr\/bin\/swift-build","timestamp":"2026-11-19 16:00:01.000000-0600","eventMessage":"Request 123 failed after 0x1f ms","processID":4242}
    {"messageType":"Default","eventType":"logEvent","subsystem":"com.example.build","category":"net","processImagePath":"\/usr\/bin\/swift-build","timestamp":"2026-11-19 16:00:05.000000-0600","eventMessage":"Request 456 failed after 0x2a ms","processID":4242}
    {"messageType":"Error","eventType":"logEvent","subsystem":"com.example.build","category":"io","processImagePath":"\/usr\/bin\/swift-build","timestamp":"2026-11-19 16:00:03.000000-0600","eventMessage":"Couldn't open <private>","processID":4242}
    {"messageType":"Info","eventType":"logEvent","subsystem":"","category":"","processImagePath":"\/usr\/bin\/swift-build","timestamp":"2026-11-19 16:00:02.000000-0600","eventMessage":"starting","processID":4242}
    {"count":4,"finished":1}
    """#

    func entries(_ levels: Set<LogEntry.Level>) -> [LogEntry] {
        Self.captured.split(separator: "\n").compactMap { LogParser.parse(String($0), levels: levels) }
    }

    func testGroupingCapturedLines() {
        XCTAssertEqual(entries(LogParser.errorLevels).count, 1, "the Console's default parse still skips default and info")
        let all = entries([.fault, .error, .default, .info])
        XCTAssertEqual(all.count, 4)
        let r = ProcessLogs.group(all)
        XCTAssertEqual(r.total, 4)
        XCTAssertEqual(r.groups.count, 3, "the two requests share a shape")
        XCTAssertEqual(r.groups.first?.count, 2)
        XCTAssertEqual(r.groups.first?.message, "Request 456 failed after 0x2a ms", "newest first, latest message kept verbatim")
        XCTAssertEqual(r.redacted, 1)
        XCTAssertEqual(r.byLevel[.default], 2)
        XCTAssertEqual(ProcessLogs.shape("pid 12 uuid 1B4E28BA-2FA1-11D2-883F-0016D3CCA427 at 0xff"), "pid # uuid # at #")
    }

    func testPredicates() {
        var q = ProcessLogs.Query(app: "My \"App\"", level: .error, from: X.t0, to: X.t0.addingTimeInterval(60))
        XCTAssertEqual(ProcessLogs.predicate(q), #"(process ==[c] "My \"App\"" OR processImagePath CONTAINS[c] "/My \"App\".app/") AND (messageType == fault OR messageType == error)"#)
        q = ProcessLogs.Query(pid: 42, subsystem: "com.apple.network", level: .fault, from: X.t0, to: X.t0)
        XCTAssertEqual(ProcessLogs.predicate(q), #"processID == 42 AND (subsystem == "com.apple.network" OR subsystem BEGINSWITH "com.apple.network.") AND (messageType == fault)"#)
    }

    func testProcessLogsTool() async throws {
        var t = MCPTools(source: TraceSource()); t.now = { X.t0 }; t.marks = tempMarks()
        let all = entries([.fault, .error, .default, .info])
        t.logRunner = { _ in ProcessLogs.group(all) }
        let r = await t.call("process_logs", arguments: ["app": "swift-build", "level": "info", "last_minutes": 30])
        XCTAssertFalse(r.isError, r.text)
        let j = try JSON.parse(Data(r.text.utf8))
        XCTAssertEqual(j["rows"]?.array?.count, 3)
        XCTAssertEqual(j["rows"]?.array?.first?.array?[2].int, 2)
        XCTAssertNotNil(j["redacted"]?.string?.range(of: "<private>"))
        let none = await t.call("process_logs", arguments: [:])
        XCTAssertTrue(none.isError && none.text.contains("at least one of"))
        let long = await t.call("process_logs", arguments: ["pid": 1, "level": "default", "last_minutes": 120])
        XCTAssertTrue(long.isError && long.text.contains("limited to 60 minutes"))
    }

    /// A real `log show` for this test process over the last minute. Skipped on CI (GitHub's VMs) and where `log`
    /// isn't usable; it only checks that the read finishes within its bounds.
    func testRealLogRead() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("needs the real unified log") }
        let q = ProcessLogs.Query(pid: getpid(), level: .error, from: Date().addingTimeInterval(-60), to: Date())
        let r = ProcessLogs.read(q)
        if r.outcome.hasPrefix("failed") { throw XCTSkip("log show unavailable: \(r.outcome)") }
        XCTAssertFalse(r.outcome.hasPrefix("timed out"), r.outcome)
    }

    // MARK: Schemas

    func testAgentToolSchemasAndAnnotations() async throws {
        let specs = MCPTools(source: TraceSource()).specs
        for name in ["mark", "marks", "measure", "query_metrics", "process_logs"] { XCTAssertTrue(specs.contains { $0.name == name }, name) }
        XCTAssertEqual(specs.filter { !$0.readOnly }.map(\.name), ["mark"], "only mark writes")
        let server = MCPServer(version: "t", instructions: "", tools: MCPTools(source: TraceSource()))
        let reply = await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        let list = try XCTUnwrap(reply.body?["result"]?["tools"]?.array)
        let mark = try XCTUnwrap(list.first { $0["name"]?.string == "mark" })
        XCTAssertEqual(mark["annotations"]?["readOnlyHint"]?.bool, false)
        XCTAssertEqual(mark["annotations"]?["destructiveHint"]?.bool, false)
        let measure = try XCTUnwrap(list.first { $0["name"]?.string == "measure" })
        XCTAssertEqual(measure["annotations"]?["readOnlyHint"]?.bool, true)
        XCTAssertEqual(measure["inputSchema"]?["properties"]?["compare_to"]?["type"]?.string, "object")
        XCTAssertNotNil(MCPPrompts.find("measure_change"))
        XCTAssertTrue(MCPPrompts.find("measure_change")!.render(["command": "swift test"]).contains("compare_to"))
    }

    // MARK: Cost

    /// A full 24 h coarse tier on disk (8,640 frames of 25 processes, as the app writes it), measured through the
    /// standalone source, so decompression and decoding are included. Prints the time; the bound is generous for CI.
    func testMeasuring24HoursIsFast() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bb-24h-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let end = Date(), start = end.addingTimeInterval(-86_390)
        let procs0 = (0..<25).map { i in X.proc("p\(i)", pid: Int32(1000 + i), ppid: 1, start: start.addingTimeInterval(-60), cpuTime: 0) }
        var seg: [Snapshot] = []
        func flush() throws {
            guard let a = seg.first?.time, let b = seg.last?.time else { return }
            let name = "coarse-\(Int64(a.timeIntervalSince1970 * 1000))-\(Int64(b.timeIntervalSince1970 * 1000)).flightlog"
            try Trace(host: "T", model: "M", interval: 10, frames: seg).write(to: dir.appendingPathComponent(name)); seg = []
        }
        for k in 0..<8639 {
            let t = start.addingTimeInterval(Double(k) * 10)
            seg.append(X.frame(t, procs0.map { var p = $0; p.cpuTime = Double(k) * 0.5; return p }, cpu: 40, diskTotal: UInt64(k) * 1000))
            if seg.count == 60 { try flush() }
        }
        try flush()
        let src = StandaloneMCPSource(blackBoxDir: dir, incidentURL: dir.appendingPathComponent("none.json"), dailyDir: dir)
        var t = MCPTools(source: src); t.marks = tempMarks()
        let clock = Date()
        let r = await t.call("measure", arguments: ["from": "-1439m", "process": "p3"])
        let secs = Date().timeIntervalSince(clock)
        print("measure over 24 h (8,639 frames × 25 processes): \(String(format: "%.2f", secs)) s")
        XCTAssertFalse(r.isError, r.text)
        let j = try JSON.parse(Data(r.text.utf8))
        XCTAssertGreaterThan(j["filter"]?["cpu_seconds"]?.double ?? 0, 4000)
        XCTAssertLessThan(secs, 20)
    }
}
