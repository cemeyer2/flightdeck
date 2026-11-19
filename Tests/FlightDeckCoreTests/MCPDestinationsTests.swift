// The `network_destinations` MCP tool: apps and their destinations from stored days, filtering by app and by
// destination, labelled name sources, the new flag, argument checks, and "unavailable" without the app's data.
import XCTest
@testable import FlightDeckCore

final class DestinationsFakeSource: MCPDataSource, @unchecked Sendable {
    let standalone = false
    let blackBoxConfig = BlackBox.Config()
    var data: (days: [DestinationDay], known: KnownDestinations)?
    func snapshot() async -> Snapshot? { nil }
    func findings() async -> [Finding] { [] }
    func incidents() async -> [Incident] { [] }
    func reports(since: Date) async -> [DiagnosticReport] { [] }
    func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace? { nil }
    func dailyHistory() async -> DailyLog.History? { nil }
    func checkup() async -> [CheckResult] { [] }
    func destinations() async -> (days: [DestinationDay], known: KnownDestinations)? { data }
}

final class MCPDestinationsTests: XCTestCase {
    let now = Date()

    func source() -> DestinationsFakeSource {
        let today = Calendar.current.startOfDay(for: now)
        let t = max(today, now.addingTimeInterval(-60))
        var slack = DestinationRow(app: "/Applications/Slack.app", appName: "Slack", ip: "203.0.113.5", scope: .publicInternet,
                                   host: "edge-1.slack.com", nameSource: .reverseDNS, first: t, last: t)
        slack.bytesIn = 5_000_000; slack.bytesOut = 200_000; slack.connections = 3; slack.ports = [443]; slack.protos = ["tcp"]
        var mystery = DestinationRow(app: "proc:Mystery Helper", appName: "Mystery Helper", ip: "198.51.100.77", scope: .publicInternet,
                                     nameSource: .none, first: t, last: t)
        mystery.bytesOut = 9_000_000; mystery.connections = 1; mystery.ports = [8443]; mystery.protos = ["tcp"]
        var known = KnownDestinations()
        known.note(app: "proc:Mystery Helper", name: "Mystery Helper", dest: "old.example", at: now.addingTimeInterval(-10 * 86_400))
        known.note(app: "proc:Mystery Helper", name: "Mystery Helper", dest: "198.51.100.77", at: t)
        let src = DestinationsFakeSource()
        src.data = ([DestinationDay(start: today, rows: [slack, mystery], firstCounted: today)], known)
        return src
    }

    func call(_ src: MCPDataSource, _ args: JSON = [:]) async throws -> JSON {
        let r = await MCPTools(source: src).call("network_destinations", arguments: args)
        XCTAssertFalse(r.isError, r.text)
        return try JSON.parse(Data(r.text.utf8))
    }

    func testListsAppsWithLabelledNames() async throws {
        let j = try await call(source())
        let apps = try XCTUnwrap(j["apps"]?.array)
        XCTAssertEqual(apps.map { $0["app"]?.string }, ["Mystery Helper", "Slack"], "busiest first")
        let m = try XCTUnwrap(apps[0]["destinations"]?.array?.first)
        XCTAssertEqual(m["destination"]?.string, "198.51.100.77")
        XCTAssertEqual(m["name_source"]?.string, "no name")
        XCTAssertEqual(m["new_for_this_app"]?.bool, true)
        XCTAssertEqual(m["services"]?.array?.first?.string, "HTTPS (alt) 8443")
        let s = try XCTUnwrap(apps[1]["destinations"]?.array?.first)
        XCTAssertEqual(s["destination"]?.string, "slack.com")
        XCTAssertEqual(s["name_source"]?.string, "reverse DNS")
        XCTAssertEqual(s["hosts"]?.array?.first?.string, "edge-1.slack.com")
        XCTAssertNil(s["new_for_this_app"])
        XCTAssertTrue(j["note"]?.string?.contains("missed") == true)
    }

    func testFilters() async throws {
        let byApp = try await call(source(), ["app": "slack"])
        XCTAssertEqual(byApp["apps"]?.array?.count, 1)
        let byDest = try await call(source(), ["destination": "198.51"])
        XCTAssertEqual(byDest["apps"]?.array?.map { $0["app"]?.string }, ["Mystery Helper"])
        let none = try await call(source(), ["app": "nope"])
        XCTAssertEqual(none["apps"]?.array?.count, 0)
        XCTAssertTrue(none["summary"]?.string?.hasPrefix("No destinations") == true)
    }

    func testArgumentsAndUnavailable() async throws {
        let bad = await MCPTools(source: source()).call("network_destinations", arguments: ["days": .int(31)])
        XCTAssertTrue(bad.isError)
        let j = try await call(DestinationsFakeSource())
        XCTAssertTrue(j["summary"]?.string?.hasPrefix("unavailable") == true)
    }
}
