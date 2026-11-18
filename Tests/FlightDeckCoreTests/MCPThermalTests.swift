// The `temperatures` MCP tool: grouped sensors with session statistics, fans with health, throttling, and the
// standalone fallback that marks statistics unavailable instead of repeating one reading as min and max.
import XCTest
@testable import FlightDeckCore

/// FakeSource plus a session ThermalWatch, as the running app provides.
final class ThermalFakeSource: MCPDataSource, @unchecked Sendable {
    let standalone = false
    var snap: Snapshot?
    let watch = ThermalWatch(chip: .m1Pro)
    let blackBoxConfig = BlackBox.Config()
    func snapshot() async -> Snapshot? { snap }
    func findings() async -> [Finding] { [] }
    func incidents() async -> [Incident] { [] }
    func reports(since: Date) async -> [DiagnosticReport] { [] }
    func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace? { nil }
    func dailyHistory() async -> DailyLog.History? { nil }
    func checkup() async -> [CheckResult] { [] }
    func thermal() async -> (status: ThermalStatus, history: SensorHistory)? { (watch.status(), watch.history) }
}

final class MCPThermalTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(cpu: Double, at t: Date) -> Snapshot {
        var s = BlackBoxTests.base
        s.time = t
        s.power.temperatures = [SensorReading(name: "PMU tdie1", celsius: 45), SensorReading(name: "PMU tcal", celsius: 52)]
        s.power.smcTemperatures = [SensorReading(name: "Tp01", celsius: cpu), SensorReading(name: "TB1T", celsius: 31)]
        s.power.sensorsReadAt = t
        s.power.thermalState = 0
        s.power.fans = [FanReading(index: 0, rpm: 2400, minRPM: 1200, maxRPM: 6000, targetRPM: 2400)]
        s.gpuDetail?.thermalLimited = 0
        return s
    }

    func call(_ src: MCPDataSource) async throws -> JSON {
        let r = await MCPTools(source: src).call("temperatures", arguments: [:])
        XCTAssertFalse(r.isError, r.text)
        return try JSON.parse(Data(r.text.utf8))
    }

    func testSessionStatistics() async throws {
        let src = ThermalFakeSource()
        for (i, v) in [60.0, 80, 70].enumerated() { _ = src.watch.ingest(snapshot(cpu: v, at: t0.addingTimeInterval(Double(i) * 4))) }
        src.snap = snapshot(cpu: 70, at: t0.addingTimeInterval(8))
        let j = try await call(src)
        let core = j["groups"]?["cpuPerformance"]?["sensors"]?.array?.first
        XCTAssertEqual(core?["name"]?.string, "P-core 1")
        XCTAssertEqual(core?["now_c"]?.double, 70); XCTAssertEqual(core?["min_c"]?.double, 60)
        XCTAssertEqual(core?["max_c"]?.double, 80); XCTAssertEqual(core?["avg_c"]?.double, 70)
        XCTAssertEqual(j["highest_by_group"]?["cpu"]?["session_max_c"]?.double, 80)
        XCTAssertEqual(j["fans"]?.array?.first?["percent_of_max"]?.double, 40)
        XCTAssertEqual(j["throttling"]?["throttled"]?.bool, false)
        XCTAssertTrue(j["throttling"]?["cpu_speed_limit_percent"]?.string?.hasPrefix("unavailable") == true, "pmset not read yet")
        XCTAssertEqual(j["groups"]?["other"]?["sensors"]?.array?.first?["calibration_reference"]?.bool, true)
    }

    func testStandaloneMarksStatisticsUnavailable() async throws {
        let src = FakeSource(); src.snap = snapshot(cpu: 70, at: t0)
        src.snap?.power.fans = []
        let j = try await call(src)
        // The standalone path catalogues with this Mac's chip, so check an HID sensor, whose name is chip-independent.
        let die = j["groups"]?["soc"]?["sensors"]?.array?.first
        XCTAssertEqual(die?["name"]?.string, "Die 1")
        XCTAssertEqual(die?["now_c"]?.double, 45)
        XCTAssertTrue(die?["max_c"]?.string?.hasPrefix("unavailable") == true)
        XCTAssertEqual(j["fans"]?.string, "This Mac has no fans.")
    }
}
