// `triage`: ranking on fixtures (severity, ongoing, grouping of reports, dedupe against findings, metric checks) and
// the tool's output shape.
import XCTest
@testable import FlightDeckCore

final class MCPTriageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func finding(_ id: String, _ sev: Finding.Severity, _ title: String, pids: [Int32]? = nil) -> Finding {
        Finding(id: id, severity: sev, icon: "x", title: title, since: now.addingTimeInterval(-300), pids: pids)
    }
    func report(_ p: String, _ kind: DiagnosticReport.Kind, ago: TimeInterval) -> DiagnosticReport {
        DiagnosticReport(path: "/r/\(p)-\(ago).ips", kind: kind, process: p, time: now.addingTimeInterval(-ago), summary: nil)
    }
    func calmSnapshot() -> Snapshot {
        var s = BlackBoxTests.base
        s.time = now; s.memory.pressure = .value(30); s.power.thermalState = 0; s.power.battery = nil
        s.disk.volumes = []
        return s
    }

    func testRankingOnFixtures() throws {
        var x = TriageInput(snapshot: calmSnapshot(), now: now)
        x.findings = [finding("swap-used", .info, "Swap in use: 2 GB"),
                      finding("hang:42-1", .warning, "Mail is not responding", pids: [42]),
                      finding("cpu:xcode", .caution, "Xcode is using 400% CPU", pids: [7]),
                      finding("report:Crash:Safari", .caution, "Safari crashed")]
        x.reports = [report("Safari", .crash, ago: 600), report("Safari", .crash, ago: 1200), report("Safari", .crash, ago: 7200),
                     report("Notes", .hang, ago: 3000), report("bird", .cpuLimit, ago: 100), report("Old", .crash, ago: 200_000)]
        x.incidents = [Incident(id: UUID(), key: "mem-pressure", severity: .warning, icon: "m", title: "Memory pressure is high", detail: nil,
                                destination: nil, start: now.addingTimeInterval(-900), end: nil),
                       Incident(id: UUID(), key: "cpu:xcode", severity: .caution, icon: "c", title: "Xcode is using 400% CPU", detail: nil,
                                destination: nil, start: now.addingTimeInterval(-300), end: nil)]
        let items = Triage.rank(x)
        XCTAssertEqual(items.first?.title, "Mail is not responding", "an ongoing warning comes first")
        XCTAssertEqual(items.first?.nextTool, "sample_stacks"); XCTAssertEqual(items.first?.nextArgs["pid"]?.int, 42)
        XCTAssertEqual(items[1].title, "Memory pressure is high", "an ongoing incident the findings don't cover")
        let safari = try XCTUnwrap(items.first { $0.title.hasPrefix("Safari") })
        XCTAssertEqual(safari.title, "Safari: crash ×3 in 24 h"); XCTAssertEqual(safari.severity, .warning, "three crashes: warning")
        XCTAssertEqual(safari.nextArgs["process"]?.string, "Safari")
        XCTAssertFalse(items.contains { $0.title == "Safari crashed" }, "report findings are replaced by the grouped reports")
        XCTAssertFalse(items.contains { $0.title.contains("bird") || $0.title.contains("Old") }, "informational kinds and old reports are left out")
        XCTAssertEqual(items.filter { $0.title.contains("Xcode") }.count, 1, "an incident already covered by a finding isn't repeated")
        XCTAssertEqual(items.last?.title, "Swap in use: 2 GB")
        XCTAssertEqual(items.map(\.score), items.map(\.score).sorted(by: >))
    }

    func testMetricChecksAndQuietMac() {
        var s = calmSnapshot()
        XCTAssertEqual(Triage.rank(TriageInput(snapshot: s, now: now)), [], "nothing wrong, nothing listed")
        s.memory.pressure = .value(92); s.power.thermalState = 2
        s.disk.volumes = [VolumeInfo(name: "Macintosh HD", path: "/", capacity: 500_000_000_000, available: 4_000_000_000, fileSystem: "apfs", isInternal: true)]
        let items = Triage.rank(TriageInput(snapshot: s, now: now))
        XCTAssertEqual(Set(items.map(\.subsystem)), ["memory", "thermal", "disk"])
        XCTAssertTrue(items.allSatisfy { $0.severity == .warning })
        var x = TriageInput(snapshot: s, now: now)
        x.findings = [finding("mem-pressure", .warning, "Memory pressure is high")]
        XCTAssertEqual(Triage.rank(x).filter { $0.subsystem == "memory" }.count, 1, "a finding replaces the metric check")
    }

    func testTriageTool() async throws {
        let src = FakeSource(); src.snap = calmSnapshot()
        src.findingList = [finding("thermal", .warning, "The Mac is hot")]
        var t = MCPTools(source: src)
        t.now = { [now] in now }; t.bootReader = { [] }
        let r = await t.call("triage", arguments: ["limit": 5])
        XCTAssertFalse(r.isError, r.text)
        let j = try JSON.parse(Data(r.text.utf8))
        XCTAssertEqual(j["problems"]?.array?.count, 1)
        XCTAssertEqual(j["problems"]?.array?.first?["next"]?["tool"]?.string, "temperatures")
        XCTAssertTrue(j["summary"]?.string?.contains("The Mac is hot") == true)
        XCTAssertEqual(j["readings"]?["memory_pressure_percent"]?.double, 30)
    }
}
