import XCTest
@testable import FlightDeckCore
import FlightDeckHelperProtocol

/// A source with scriptable helper hooks (FakeSource is final and keeps the protocol defaults, i.e. helper off).
final class HelperFakeSource: MCPDataSource, @unchecked Sendable {
    var standalone = false
    var snap: Snapshot?
    var access = HelperMCPAccess.off
    var contents = HelperProcessContents(args: ["--flag"], env: ["K=V"], cwd: "/var/root", files: ["/etc/hosts"])
    var sampleResult: Result<String, HelperRefusal>?
    var contentsCalls = 0
    var sampleCalls = 0
    let blackBoxConfig = BlackBox.Config()
    func snapshot() async -> Snapshot? { snap }
    func findings() async -> [Finding] { [] }
    func incidents() async -> [Incident] { [] }
    func reports(since: Date) async -> [DiagnosticReport] { [] }
    func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace? { nil }
    func dailyHistory() async -> DailyLog.History? { nil }
    func checkup() async -> [CheckResult] { [] }
    func helperAccess() async -> HelperMCPAccess { access }
    func helperContents(_ id: ProcessIdentity, parts: Set<DetailPart>) async -> HelperProcessContents? {
        contentsCalls += 1
        return access.contentsAllowed ? contents : nil
    }
    func helperSample(_ id: ProcessIdentity, seconds: Int) async -> Result<String, HelperRefusal>? {
        sampleCalls += 1
        return sampleResult
    }
}

final class HelperMCPTests: XCTestCase {
    let rootUID: UInt32 = 0

    func proc(_ name: String, pid: Int32, uid: UInt32) -> ProcessSample {
        var p = BlackBoxTests.base.processes[0]
        p.identity = ProcessIdentity(pid: pid, startTime: 1); p.name = name; p.path = "/usr/sbin/\(name)"; p.uid = uid
        p.user = uid == 0 ? "root" : "me"; p.restricted = uid != getuid(); p.cpu = 2; p.cpuTime = 10; p.memory = 1 << 20
        p.network = nil; p.gpu = nil; p.energyWatts = nil; p.notResponding = nil; p.powerAssertions = nil; p.translated = nil
        return p
    }

    func source(_ access: HelperMCPAccess) -> HelperFakeSource {
        let src = HelperFakeSource()
        var s = BlackBoxTests.base
        s.processes = [proc("mine", pid: 40, uid: getuid()), proc("WindowServer", pid: 50, uid: rootUID), proc("syspolicyd", pid: 60, uid: rootUID)]
        src.snap = s
        src.access = access
        return src
    }

    func tools(_ src: MCPDataSource) -> MCPTools {
        var t = MCPTools(source: src)
        t.inspector = { pid, _ in
            ProcessDetails(arguments: .unavailable("not permitted"), environment: .unavailable("not permitted"), cwd: .unavailable("not permitted"),
                           files: .unavailable("not permitted"), sockets: [], threads: .unavailable("not permitted"), signature: nil,
                           nice: nil, ancestry: [], counters: nil)
        }
        t.stackSampler = { _, _ in "Call graph:\n    5 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)\n    + 5 start  (in dyld) + 1  [0x1]\n\nTotal number in stack" }
        return t
    }

    func call(_ t: MCPTools, _ name: String, _ args: JSON = [:]) async throws -> JSON {
        let r = await t.call(name, arguments: args)
        XCTAssertFalse(r.isError, r.text)
        return try JSON.parse(Data(r.text.utf8))
    }

    func testDefaultSourceReportsOff() async throws {
        let fake = FakeSource()
        fake.snap = source(.off).snap
        let j = try await call(tools(fake), "get_process", ["pid": 60])
        XCTAssertEqual(j["helper"]?.string, "off")
        XCTAssertEqual(j["helper_note"]?.string, MCPTools.unlockNote)
        XCTAssertEqual(j["cwd"]?.string, "unavailable (not permitted)")
    }

    func testLockedAddsUnlockNote() async throws {
        let j = try await call(tools(source(.init(state: .locked, agentContents: false))), "list_processes")
        XCTAssertEqual(j["helper"]?.string, "locked")
        XCTAssertEqual(j["helper_note"]?.string, MCPTools.unlockNote)
        let c = try await call(tools(source(.init(state: .locked, agentContents: false))), "checkup")
        XCTAssertEqual(c["helper"]?.string, "locked")
    }

    func testUnlockedNoNote() async throws {
        let j = try await call(tools(source(.init(state: .unlocked, agentContents: false))), "list_processes", ["by_app": true])
        XCTAssertEqual(j["helper"]?.string, "unlocked")
        XCTAssertNil(j["helper_note"])
    }

    func testContentsWithheldWhenSettingOff() async throws {
        let src = source(.init(state: .unlocked, agentContents: false))
        let j = try await call(tools(src), "get_process", ["pid": 60, "include": ["arguments", "files"]])
        XCTAssertEqual(j["arguments"]?.string, "unavailable (\(MCPTools.contentsOffNote))")
        XCTAssertEqual(j["cwd"]?.string, "unavailable (\(MCPTools.contentsOffNote))")
        XCTAssertEqual(j["files"]?.string, "unavailable (\(MCPTools.contentsOffNote))")
        XCTAssertEqual(src.contentsCalls, 0)
    }

    func testContentsServedWhenSettingOn() async throws {
        let src = source(.init(state: .unlocked, agentContents: true))
        let j = try await call(tools(src), "get_process", ["pid": 60, "include": ["arguments"]])
        XCTAssertEqual(j["arguments"]?.array?.compactMap(\.string), ["--flag"])
        XCTAssertEqual(j["cwd"]?.string, "/var/root")
        XCTAssertEqual(j["open_files"]?.int, 1)
        XCTAssertFalse(j.text.contains("K=V"), "the environment is never asked for over MCP")
        // The user's own processes never go through the helper.
        _ = try await call(tools(src), "get_process", ["pid": 40])
        XCTAssertEqual(src.contentsCalls, 1)
    }

    func testSampleStacksCriticalRefusalReported() async throws {
        let src = source(.init(state: .unlocked, agentContents: true))
        src.sampleResult = .failure(HelperValidation.criticalRefusal("WindowServer"))
        let r = await tools(src).call("sample_stacks", arguments: ["pid": 50, "seconds": 1])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("never samples WindowServer"), r.text)
    }

    func testSampleStacksViaHelper() async throws {
        let src = source(.init(state: .unlocked, agentContents: true))
        src.sampleResult = .success("Call graph:\n    3 Thread_9   DispatchQueue_1: com.apple.main-thread  (serial)\n    + 3 work  (in syspolicyd) + 1  [0x1]\n\nTotal number in stack")
        let j = try await call(tools(src), "sample_stacks", ["pid": 60, "seconds": 1])
        XCTAssertEqual(j["helper"]?.string, "unlocked")
        XCTAssertEqual(src.sampleCalls, 1)
    }

    func testSampleStacksWithheld() async throws {
        let off = source(.init(state: .unlocked, agentContents: false))
        let r = await tools(off).call("sample_stacks", arguments: ["pid": 60])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains(MCPTools.contentsOffNote))
        XCTAssertEqual(off.sampleCalls, 0)
        let locked = source(.init(state: .locked, agentContents: true))
        let r2 = await tools(locked).call("sample_stacks", arguments: ["pid": 60])
        XCTAssertTrue(r2.text.contains("only your own processes") && r2.text.contains(MCPTools.unlockNote))
        XCTAssertEqual(locked.sampleCalls, 0)
    }

    func testHelperFilledCountersShown() async throws {
        let src = source(.init(state: .unlocked, agentContents: false))
        var p = proc("syspolicyd", pid: 60, uid: rootUID)
        p.restricted = true; p.source = .helper; p.cpuTime = 12; p.cpu = 3
        src.snap?.processes = [p]
        let j = try await call(tools(src), "get_process", ["pid": 60])
        XCTAssertEqual(j["cpu_percent"]?.double, 3)
        XCTAssertEqual(j["counters_from"]?.string, "helper")
    }
}
