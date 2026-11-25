import XCTest
@testable import FlightDeckCore
import FlightDeckHelperProtocol

final class HelperRoutingTests: XCTestCase {
    func helperRow(pid: Int32 = 77) -> ProcessSample {
        var p = BlackBoxTests.base.processes[0]
        p.identity = ProcessIdentity(pid: pid, startTime: 5); p.uid = 0; p.user = "root"; p.name = "syspolicyd"
        p.restricted = true; p.source = .helper; p.cpuTime = 4; p.cpu = 1
        return p
    }

    /// Every stored ProcessSample field ends up in recordings, the black box, incidents and exports. Adding a field
    /// here means deciding whether it may be persisted, and the helper's process contents may not.
    func testProcessSampleFieldSetIsFixed() {
        let labels = Set(Mirror(reflecting: BlackBoxTests.base.processes[0]).children.compactMap(\.label))
        XCTAssertEqual(labels, ["identity", "ppid", "name", "path", "user", "uid", "cpu", "cpuTime", "memory", "threads",
                                "diskReadBps", "diskWriteBps", "diskRead", "diskWritten", "energyWatts", "energyTotal", "wakeups",
                                "restricted", "network", "notResponding", "gpu", "translated", "powerAssertions", "source"])
    }

    func testHelperContentsNotInSnapshotType() throws {
        var s = BlackBoxTests.base
        s.processes.append(helperRow())
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        for key in ["\"args\"", "\"env\"", "\"cwd\"", "\"files\"", "\"sockets\"", "\"stacks\""] {
            XCTAssertFalse(json.contains(key), key)
        }
        XCTAssertTrue(json.contains("\"source\":\"helper\""), "counters keep their provenance in recordings")
    }

    func testWithoutHelperValuesDropsHelperRows() {
        var s = BlackBoxTests.base
        let own = s.processes[0]
        s.processes = [own, helperRow()]
        let out = s.withoutHelperValues()
        XCTAssertEqual(out.processes.map(\.identity), [own.identity])
    }

    func testCopySummaryCarriesNoContents() {
        let contents = HelperProcessContents(args: ["--token=hunter2"], env: ["SECRET=xyzzy"], cwd: "/private/var/secret")
        let text = ProcessSummaryText.make(helperRow(), details: nil)
        for s in (contents.args ?? []) + (contents.env ?? []) + [contents.cwd ?? ""] { XCTAssertFalse(text.contains(s)) }
        XCTAssertTrue(text.contains("syspolicyd (PID 77"))
    }

    func testDiagnosticTargetsStayOwnProcesses() {
        var mine = BlackBoxTests.base.processes[0]
        mine.identity = ProcessIdentity(pid: 500, startTime: 1); mine.uid = getuid(); mine.restricted = false; mine.cpu = 1
        var busy = helperRow(pid: 600)
        busy.cpu = 900
        let t = DiagnosticCapture.targets([mine, busy], uid: getuid(), exclude: -1)
        XCTAssertFalse(t.contains { $0.identity.pid == 600 })
        XCTAssertTrue(t.contains { $0.identity.pid == 500 })
    }
}
