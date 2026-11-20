// The `fleet` MCP tool's output, triage routing for the 1.6 features' findings, and the guided prompts that use them.
import XCTest
@testable import FlightDeckCore

final class MCPFleetToolTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func peer(_ name: String) -> FleetPeer { FleetPeer(id: name.lowercased(), name: name, secret: Data(repeating: 1, count: 32), pairedAt: now) }

    func status(_ name: String, finding: FleetFinding?) -> FleetStatus {
        let v = FleetVitals(cpu: FleetValue(38), memoryPressure: FleetValue(86), memoryLevel: 4, memoryUsed: FleetValue(61 * 1_073_741_824),
                            memoryTotal: FleetValue(64 * 1_073_741_824), hottest: FleetValue(nil, reason: "no sensors"),
                            diskFree: FleetValue(212e9), diskTotal: FleetValue(1e12), battery: nil, batteryReason: "no battery",
                            uptime: FleetValue(7200), thermalState: 0, sampledAt: now)
        return FleetStatus(identity: FleetIdentity(id: name.lowercased(), name: name, model: "Mac14,13", kind: "desktop", macOS: "15.1", appVersion: "1.6.0"),
                           vitals: v, findings: finding.map { [$0] } ?? [], incidents: [], history: [])
    }

    func testNothingPaired() {
        let j = MCPTools.fleetJSON([], now: now)
        XCTAssertEqual(j["paired_macs"], .int(0))
        XCTAssertTrue(j["note"]?.string?.contains("Pair a Mac") ?? false)
    }

    func testOnlineAndOfflineMacs() throws {
        let bad = FleetFinding(kind: "mem", severity: 2, icon: "memorychip", title: "Memory pressure is critical", detail: nil, since: now)
        var offline = peer("Basement Mini"); offline.lastSeen = now.addingTimeInterval(-3600)
        let j = MCPTools.fleetJSON([FleetHostResult(peer: peer("Studio"), status: status("Studio", finding: bad), error: nil),
                                    FleetHostResult(peer: offline, status: nil, error: "timed out")], now: now)
        XCTAssertEqual(j["paired_macs"], .int(2))
        XCTAssertEqual(j["online"], .int(1))
        XCTAssertEqual(j["needs_attention"], .strings(["Studio"]))
        let macs = try XCTUnwrap(j["macs"]?.array)
        XCTAssertEqual(macs[0]["worst"], .str("Memory pressure is critical"))
        XCTAssertEqual(macs[0]["findings"]?.array?.first?["severity"], .str("warning"))
        let v = try XCTUnwrap(macs[0]["vitals"])
        XCTAssertEqual(v["memory_total_gb"], .double(64))
        XCTAssertTrue(v["hottest_c"]?.string?.hasPrefix("unavailable") ?? false, "unmeasured is unavailable, never 0")
        XCTAssertTrue(v["battery"]?.string?.hasPrefix("unavailable") ?? false)
        XCTAssertEqual(macs[1]["online"], .bool(false))
        XCTAssertNotNil(macs[1]["last_seen"])
        XCTAssertNil(macs[1]["vitals"], "nothing invented for an offline Mac")
    }

    func testToolIsListed() async throws {
        var tools = MCPTools(source: FakeSource())
        tools.fleetRunner = { [] }
        XCTAssertTrue(tools.specs.contains { $0.name == "fleet" })
    }

    /// Findings raised by the 1.6 pages send triage to the tool that explains them, not to get_status.
    func testTriageRoutesNewFindings() {
        func next(_ id: String) -> String {
            let f = Finding(id: id, severity: .caution, icon: "x", title: "t", detail: nil, since: Date(), destination: nil)
            return Triage.route(f).1
        }
        XCTAssertEqual(next("change:launch:com.example.helper"), "system_changes")
        XCTAssertEqual(next("backup-gap"), "backups")
        XCTAssertEqual(next("usb-slow:ssd1"), "peripherals")
        XCTAssertEqual(next("accessory-low:mouse"), "peripherals")
        XCTAssertEqual(next("fleet:studio:mem"), "fleet")
        XCTAssertEqual(next("privacy:dest:Photos"), "network_destinations")
        XCTAssertEqual(next("privacy:camera:zoom"), "camera_mic")
    }

    /// Every "call X" in every guided prompt names a real tool.
    func testPromptsCallRealTools() throws {
        let names = Set(MCPTools(source: FakeSource()).specs.map(\.name))
        let call = try NSRegularExpression(pattern: "[Cc]all ([a-z_]+)")
        for p in MCPPrompts.all {
            let body = p.render(["app": "X", "command": "make", "days": "7"])
            for m in call.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                let tool = (body as NSString).substring(with: m.range(at: 1))
                if ["the", "out", "it", "them", "each", "a"].contains(tool) { continue }   // English, not a tool name
                XCTAssertTrue(names.contains(tool), "\(p.name) calls unknown tool \(tool)")
            }
        }
        for name in ["what_changed", "backup_check", "display_check", "weekly_review", "fleet_check"] {
            XCTAssertNotNil(MCPPrompts.find(name), name)
        }
    }
}
