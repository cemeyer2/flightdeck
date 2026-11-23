// MCP tool output on synthetic data: every tool's summary and details, argument validation, and the "never invent
// zeros" rule (unmeasured values are marked unavailable). Snapshots are cloned from one real sample
// (`BlackBoxTests.base`) with every field the tools read overridden; the inspector and stack sampler are faked.
import XCTest
@testable import FlightDeckCore

/// A data source with fixed, synthetic content.
final class FakeSource: MCPDataSource, @unchecked Sendable {
    var standalone = false
    var snap: Snapshot? = nil
    var findingList: [Finding] = []
    var incidentList: [Incident] = []
    var reportList: [DiagnosticReport] = []
    var frames: [Snapshot] = []
    var days: [DayRecord] = []
    var checks: [CheckResult] = []
    let blackBoxConfig = BlackBox.Config()
    func snapshot() async -> Snapshot? { snap }
    func findings() async -> [Finding] { findingList }
    func incidents() async -> [Incident] { incidentList }
    func reports(since: Date) async -> [DiagnosticReport] { reportList.filter { $0.time >= since } }
    func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace? {
        let f = frames.filter { $0.time >= from && $0.time <= to }
        return f.isEmpty ? nil : Trace(host: "Test", model: "Mac", interval: 1, frames: f)
    }
    func dailyHistory() async -> DailyLog.History? {
        days.isEmpty ? nil : DailyLog.History(days: days, baselines: [:], charge: ChargeStatus(current: nil, last: nil), minBaselineDays: 5)
    }
    func checkup() async -> [CheckResult] { checks }
}

final class MCPToolTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func proc(_ name: String, path: String, pid: Int32, cpu: Double, mem: UInt64, uid: UInt32 = getuid()) -> ProcessSample {
        var p = BlackBoxTests.base.processes[0]; p.restricted = false
        p.identity = ProcessIdentity(pid: pid, startTime: 1); p.name = name; p.path = path; p.uid = uid; p.user = uid == 0 ? "root" : "me"
        p.cpu = cpu; p.cpuTime = 10; p.memory = mem; p.wakeups = 1; p.diskReadBps = 0; p.diskWriteBps = 0; p.threads = 4
        p.network = nil; p.gpu = nil; p.energyWatts = nil; p.notResponding = nil; p.powerAssertions = nil; p.translated = nil
        return p
    }

    func snapshot() -> Snapshot {
        var s = BlackBoxTests.base
        s.time = now
        s.cpu.total = .unavailable("warming up"); s.cpu.user = .value(60); s.cpu.system = .value(30)
        s.memory.measured = true; s.memory.used = 8 << 30; s.memory.total = 16 << 30; s.memory.pressure = .value(35); s.memory.swapUsed = .value(0)
        s.disk.readBps = .value(0); s.disk.writeBps = .value(0); s.network.inBps = .value(0); s.network.outBps = .value(0)
        s.power.systemWatts = .unavailable("no sensor"); s.power.hottest = .value(70); s.power.thermalState = 2; s.power.battery = nil
        s.gpu = .value(5)
        var hog = proc("Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode", pid: 20, cpu: 700, mem: 4 << 30)
        hog.energyWatts = 12
        var helper = proc("SourceKitService", path: "/Applications/Xcode.app/Contents/SharedFrameworks/S.framework/SourceKitService", pid: 21, cpu: 100, mem: 1 << 30)
        helper.notResponding = nil
        var root = proc("kernel_task", path: "", pid: 0, cpu: 0, mem: 0, uid: 0)
        root.restricted = true; root.cpuTime = 0
        let safari = proc("Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", pid: 30, cpu: 3, mem: 2 << 30)
        s.processes = [hog, helper, root, safari, proc("me", path: "/usr/bin/me", pid: getpid(), cpu: 1, mem: 10 << 20)]
        return s
    }

    func tools(_ src: FakeSource) -> MCPTools {
        var t = MCPTools(source: src)
        t.now = { [now] in now }
        t.inspector = { pid, _ in
            ProcessDetails(arguments: .value(["/usr/bin/me", "--flag"]), environment: .unavailable("hidden"), cwd: .value("/tmp"),
                           files: .value([.init(fd: 0, kind: .file, description: "/dev/null"), .init(fd: 3, kind: .socket, description: "tcp")]),
                           sockets: [.init(fd: 3, proto: "TCP", local: "127.0.0.1:8080", remote: "", state: "LISTEN")],
                           threads: .unavailable("not permitted"), signature: nil, nice: 0, ancestry: [(pid, "me"), (1, "launchd")], counters: nil)
        }
        t.stackSampler = { _, _ in "Call graph:\n    5 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)\n    + 5 start  (in dyld) + 1  [0x1]\n    +   5 __psynch_mutexwait  (in libsystem_kernel.dylib) + 8  [0x2]\n\nTotal number in stack" }
        return t
    }

    /// Calls a tool and parses its JSON text.
    func call(_ t: MCPTools, _ name: String, _ args: JSON = [:]) async throws -> JSON {
        let r = await t.call(name, arguments: args)
        XCTAssertFalse(r.isError, r.text)
        return try JSON.parse(Data(r.text.utf8))
    }

    func testGetStatus() async throws {
        let src = FakeSource(); src.snap = snapshot()
        src.findingList = [Finding(id: "cpu:x", severity: .caution, icon: "cpu", title: "Xcode is using 800% CPU", detail: "Busy", since: now, destination: nil, pids: [20]),
                           Finding(id: "i", severity: .info, icon: "i", title: "Minor", detail: nil, since: now, destination: nil)]
        let j = try await call(tools(src), "get_status")
        XCTAssertEqual(j["source"]?.string, "FlightDeck app (live)")
        XCTAssertEqual(j["summary"]?.string, "2 findings; worst: Xcode is using 800% CPU")
        XCTAssertEqual(j["findings"]?.array?.first?["severity"]?.string, "caution")
        XCTAssertEqual(j["system"]?["cpu"]?["total_percent"]?.string, "unavailable (warming up)", "unmeasured, not 0")
        XCTAssertEqual(j["system"]?["cpu"]?["user_percent"]?.double, 60)
        XCTAssertEqual(j["system"]?["power"]?["system_watts"]?.string, "unavailable (no sensor)")
        XCTAssertEqual(j["system"]?["thermal"]?["state"]?.string, "serious")
        let top = try XCTUnwrap(j["top_apps"]?["by_cpu"]?.array?.first)
        XCTAssertEqual(top["app"]?.string, "Xcode", "helpers roll into their app")
        XCTAssertEqual(top["cpu_percent"]?.double, 800)
        XCTAssertEqual(top["main_pid"]?.int, 20)
        XCTAssertEqual(j["top_apps"]?["by_energy"]?.array?.count, 1, "only apps that report energy")
        XCTAssertEqual(j["stress_map"]?["subsystems"]?["CPU"]?.string, "unavailable (not measured)")
        XCTAssertNotNil(j["stress_map"]?["top_causes"])
    }

    func testStandaloneSaysSo() async throws {
        let src = FakeSource(); src.snap = snapshot(); src.standalone = true
        let j = try await call(tools(src), "get_status")
        XCTAssertEqual(j["source"]?.string, "standalone")
        XCTAssertNotNil(j["source_note"])
        XCTAssertEqual(j["summary"]?.string, "All systems normal: nothing is wrong right now.")
    }

    func testListProcesses() async throws {
        let src = FakeSource(); src.snap = snapshot()
        let t = tools(src)
        var j = try await call(t, "list_processes", ["limit": 2])
        XCTAssertEqual(j["shown"]?.int, 2)
        XCTAssertEqual(j["rows"]?.array?.first?.array?[1].string, "Xcode")
        j = try await call(t, "list_processes", ["sort": "memory", "filter": "user:root"])
        let row = try XCTUnwrap(j["rows"]?.array?.first?.array)
        XCTAssertEqual(j["matched"]?.int, 1)
        XCTAssertEqual(row[3], .null, "a restricted process's CPU is not a 0")
        XCTAssertEqual(row[10], .null, "nor its thread count")
        j = try await call(t, "list_processes", ["by_app": true])
        XCTAssertEqual(j["rows"]?.array?.first?.array?[0].string, "Xcode")
        XCTAssertEqual(j["rows"]?.array?.first?.array?[1].int, 2)
        let bad = await t.call("list_processes", arguments: ["sort": "bogus"])
        XCTAssertTrue(bad.isError); XCTAssertTrue(bad.text.contains("sort must be one of"))
        let big = await t.call("list_processes", arguments: ["limit": 1000])
        XCTAssertTrue(big.isError)
    }

    func testGetProcess() async throws {
        let src = FakeSource(); src.snap = snapshot()
        let t = tools(src)
        let j = try await call(t, "get_process", ["pid": .int(Int(getpid())), "include": ["arguments", "files"]])
        XCTAssertEqual(j["name"]?.string, "me")
        XCTAssertEqual(j["open_files"]?.int, 2)
        XCTAssertEqual(j["listening_ports"], ["TCP 127.0.0.1:8080"])
        XCTAssertEqual(j["ancestry"]?.string, "me(\(getpid())) < launchd(1)")
        XCTAssertEqual(j["code_signature"]?.string, "unavailable (executable not readable)")
        XCTAssertEqual(j["arguments"]?.array?.count, 2)
        XCTAssertNil(j["thread_list"], "sections only on request")
        XCTAssertNil(j["environment"], "the environment is never exposed")
        let gone = await t.call("get_process", arguments: ["pid": 99999])
        XCTAssertTrue(gone.isError)
        let missing = await t.call("get_process", arguments: [:])
        XCTAssertTrue(missing.isError); XCTAssertTrue(missing.text.contains("pid is required"))
    }

    func testSampleStacksOnlyOwnProcesses() async throws {
        let src = FakeSource(); src.snap = snapshot()
        let t = tools(src)
        let j = try await call(t, "sample_stacks", ["pid": 20, "seconds": 1])
        XCTAssertTrue(j["summary"]?.string?.contains("__psynch_mutexwait") ?? false)
        XCTAssertEqual(j["main_thread"]?.array?.count, 3)
        XCTAssertFalse(j["main_thread"]?.text.contains("0x1") ?? true, "addresses are trimmed")
        let root = await t.call("sample_stacks", arguments: ["pid": 0])
        XCTAssertTrue(root.isError); XCTAssertTrue(root.text.contains("only your own processes"))
        let long = await t.call("sample_stacks", arguments: ["pid": 20, "seconds": 30])
        XCTAssertTrue(long.isError, "duration is capped")
    }

    func testRecentIncidents() async throws {
        let src = FakeSource()
        func inc(_ title: String, _ sev: Finding.Severity, ago: Double, len: Double?) -> Incident {
            Incident(id: UUID(), key: title, severity: sev, icon: "x", title: title, detail: nil, destination: nil,
                     start: now.addingTimeInterval(-ago), end: len.map { now.addingTimeInterval(-ago + $0) }, evidenceSummary: title == "Hang" ? "Main thread waiting" : nil)
        }
        src.incidentList = [inc("Old", .warning, ago: 3 * 86_400, len: 60), inc("Hang", .warning, ago: 3600, len: 120),
                            inc("Info", .info, ago: 600, len: 30), inc("Now", .caution, ago: 300, len: nil)]
        let t = tools(src)
        var j = try await call(t, "recent_incidents")
        XCTAssertEqual(j["summary"]?.string, "3 incidents in the last 24 h, 1 ongoing.")
        XCTAssertEqual(j["incidents"]?.array?.first?["title"]?.string, "Now", "newest first")
        XCTAssertEqual(j["incidents"]?.array?.first?["ongoing"]?.bool, true)
        XCTAssertEqual(j["incidents"]?.array?.last?["stack_summary"]?.string, "Main thread waiting")
        XCTAssertEqual(j["incidents"]?.array?.last?["duration"]?.string, "2 min")
        j = try await call(t, "recent_incidents", ["hours": 168, "min_severity": "warning"])
        XCTAssertEqual(j["incidents"]?.array?.map { $0["title"]?.string ?? "" }, ["Hang", "Old"])
    }

    /// A network incident carries the saved network state, not call stacks: its summary is not called a stack summary and
    /// the file is offered, but only while it still exists (evidence is pruned after a week).
    func testRecentIncidentsNetworkEvidence() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fd-net-\(UUID().uuidString).txt")
        try "state".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let src = FakeSource()
        func inc(_ key: String, path: String) -> Incident {
            Incident(id: UUID(), key: key, severity: .warning, icon: "x", title: key, detail: nil, destination: nil,
                     start: now.addingTimeInterval(-600), end: nil, evidencePath: path, evidenceSummary: "en9: link active, no IPv4 address, no default route on en9")
        }
        src.incidentList = [inc("net-noip:en9", path: file.path), inc("net-rx-stall:en0", path: "/nonexistent/gone.txt")]
        let rows = try await call(tools(src), "recent_incidents")["incidents"]?.array ?? []
        let present = try XCTUnwrap(rows.first { $0["title"]?.string == "net-noip:en9" })
        XCTAssertEqual(present["evidence_summary"]?.string, "en9: link active, no IPv4 address, no default route on en9")
        XCTAssertNil(present["stack_summary"], "not stacks")
        XCTAssertEqual(present["evidence_file"]?.string, file.path)
        let gone = try XCTUnwrap(rows.first { $0["title"]?.string == "net-rx-stall:en0" })
        XCTAssertNil(gone["evidence_file"], "a pruned file is not offered")
    }

    func testDiagnosticReports() async throws {
        let src = FakeSource()
        src.reportList = [DiagnosticReport(path: "/x/Safari-1.ips", kind: .crash, process: "Safari", time: now.addingTimeInterval(-100), summary: "EXC_BAD_ACCESS"),
                          DiagnosticReport(path: "/x/Safari-2.ips", kind: .hang, process: "Safari", time: now.addingTimeInterval(-200), summary: nil),
                          DiagnosticReport(path: "/x/mds.ips", kind: .diskWrites, process: "mds", time: now.addingTimeInterval(-300), summary: nil),
                          DiagnosticReport(path: "/x/old.ips", kind: .crash, process: "Old", time: now.addingTimeInterval(-3 * 86_400), summary: nil)]
        let t = tools(src)
        var j = try await call(t, "diagnostic_reports")
        XCTAssertEqual(j["total"]?.int, 3)
        XCTAssertEqual(j["top_processes"]?["Safari"]?.int, 2)
        XCTAssertEqual(j["reports"]?.array?.first?["file"]?.string, "Safari-1.ips")
        XCTAssertEqual(j["reports"]?.array?.first?["summary"]?.string, "EXC_BAD_ACCESS")
        j = try await call(t, "diagnostic_reports", ["kind": "crash", "hours": 168])
        XCTAssertEqual(j["by_kind"], ["crash": 2])
        j = try await call(t, "diagnostic_reports", ["process": "MDS"])
        XCTAssertEqual(j["total"]?.int, 1)
    }

    func testHistory() async throws {
        let src = FakeSource()
        do {
            var frames: [Snapshot] = []
            for i in 0..<60 {
                var s = snapshot(); s.time = now.addingTimeInterval(Double(i - 60)); s.cpu.total = .value(Double(i))
                frames.append(s)
            }
            src.frames = frames
        }
        let t = tools(src)
        let j = try await call(t, "history", ["minutes": 5])
        XCTAssertEqual(j["samples"]?.int, 60)
        XCTAssertEqual(j["stats"]?["cpu_percent"]?["peak"]?.double, 59)
        XCTAssertEqual(j["stats"]?["system_watts"]?.string, "unavailable (not measured in this window)", "never a 0 W average")
        XCTAssertNotNil(j["coverage_note"], "60 s of samples in a 5-minute window")
        XCTAssertEqual(j["top_cpu_apps"]?.array?.first?["app"]?.string, "Xcode")
        let empty = try await call(tools(FakeSource()), "history")
        XCTAssertTrue(empty["summary"]?.string?.contains("no samples") ?? false)
    }

    func testCheckup() async throws {
        let src = FakeSource()
        src.checks = [CheckResult(id: "sip", group: "Security", title: "SIP", status: .pass, value: "On", detail: "Fine"),
                      CheckResult(id: "fw", group: "Security", title: "Firewall", status: .attention, value: "Off", detail: "Turn it on"),
                      CheckResult(id: "tm", group: "Backup", title: "Time Machine", status: .unknown, value: "?", detail: "")]
        let j = try await call(tools(src), "checkup")
        XCTAssertEqual(j["summary"]?.string, "1 OK, 1 need attention, 1 unknown")
        XCTAssertEqual(j["needs_attention"]?.array?.first?["title"]?.string, "Firewall")
        XCTAssertEqual(j["ok"], ["SIP: On"])
    }

    func testTrends() async throws {
        let src = FakeSource()
        let cal = Calendar.current
        src.days = (0..<10).map { i in
            let start = cal.startOfDay(for: now.addingTimeInterval(Double(i - 9) * 86_400))
            var d = DayRecord(day: "d\(i)", start: start)
            d.observedSeconds = 3600; d.cpuAverage = Double(10 + i); d.crashes = 0
            var a = AppDay(id: "/Applications/Safari.app", name: "Safari"); a.version = i < 5 ? "1" : "2"; a.cpuSeconds = 36; a.runningSeconds = 3600
            d.apps = [a]
            return d
        }
        let t = tools(src)
        var j = try await call(t, "trends", ["days": 7])
        XCTAssertEqual(j["shown"]?.int, 7)
        XCTAssertEqual(j["rows"]?.array?.last?.array?[2].double, 19)
        XCTAssertEqual(j["rows"]?.array?.last?.array?[5], .null, "swap not measured that day: null, not 0")
        XCTAssertEqual(j["updates"]?.array?.first?["update"]?.string, "Safari 2")
        XCTAssertTrue(j["updates"]?.array?.first?["comparison"]?.string?.hasPrefix("Since Safari 2") ?? false)
        j = try await call(t, "trends", ["app": "safari"])
        XCTAssertEqual(j["rows"]?.array?.first?.array?[2].double, 1, "36 CPU-seconds over an hour = 1%")
        let none = await t.call("trends", arguments: ["app": "Nope"])
        XCTAssertTrue(none.isError); XCTAssertTrue(none.text.contains("Safari"))
    }
}
