import XCTest
@testable import FlightDeckCore

/// The `battery` MCP tool on a synthetic source: facts, a forecast from 120 days, the refusal with short history,
/// wear factors, and the desktop answer. The condition reader is replaced, so system_profiler never runs.
final class MCPBatteryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func source(days n: Int, battery: Bool = true) -> FakeSource {
        let src = FakeSource()
        var s = BlackBoxTests.base
        s.time = now
        s.power.battery = battery ? BatteryInfo(percent: 64, isCharging: false, externalConnected: true, cycleCount: 300,
                                                maxCapacity: 8900, designCapacity: 10_000, temperature: 31) : nil
        s.power.charging = battery ? ChargingDetails.parse(["DesignCycleCount9C": 1000, "BatteryData": ["DesignCapacity": 10_000]]) : nil
        src.snap = s
        var w = BatteryWearDay()
        w.observedSeconds = 8 * 3600; w.pluggedSeconds = 6 * 3600; w.pluggedHighSeconds = 5 * 3600
        src.days = (0..<n).map { i in
            let start = now.addingTimeInterval(Double(i - n + 1) * 86_400)
            var r = DayRecord(day: "day\(i)", start: start)
            r.observedSeconds = 3600
            r.batteryHealth = 95 - 0.05 * Double(i) + (i % 3 == 0 ? 0.4 : -0.3)
            r.cycleCount = 240 + i / 2
            r.batteryWear = w
            return r
        }
        return src
    }

    func call(_ src: FakeSource) async throws -> JSON {
        var t = MCPTools(source: src)
        t.batteryCondition = { "Good" }
        let r = await t.call("battery", arguments: [:])
        XCTAssertFalse(r.isError, r.text)
        return try JSON.parse(Data(r.text.utf8))
    }

    func testForecastAndWear() async throws {
        let j = try await call(source(days: 120))
        XCTAssertEqual(j["has_battery"]?.bool, true)
        XCTAssertEqual(j["facts"]?["cycles"]?.int, 300)
        XCTAssertEqual(j["facts"]?["design_cycles"]?.int, 1000)
        XCTAssertEqual(j["facts"]?["condition"]?.string, "Good")
        XCTAssertEqual(try XCTUnwrap(j["facts"]?["health_percent"]?.double), 89, accuracy: 0.05)
        let f = try XCTUnwrap(j["forecast"])
        XCTAssertEqual(f["status"]?.string, "forecast")
        XCTAssertEqual(try XCTUnwrap(f["trend_points_per_year"]?.double), -18.25, accuracy: 2)
        XCTAssertNotNil(f["reaches_80_percent"]?.string)
        XCTAssertEqual(f["reaches_80_percent_range_95"]?.array?.count, 2)
        XCTAssertEqual(f["cycles_remaining_to_design"]?.int, 700)
        let factors = try XCTUnwrap(j["wear_factors"]?.array)
        XCTAssertEqual(factors.count, 5)
        let high = try XCTUnwrap(factors.first { $0["factor"]?.string == "high_charge" })
        XCTAssertEqual(high["level"]?.string, "high")
        XCTAssertNotNil(high["tip"]?.string)
        XCTAssertNotNil(j["wear_note"]?.string)
        XCTAssertTrue(j["service_status"]?.string?.contains("Good") ?? false)
    }

    func testRefusesWithShortHistory() async throws {
        let j = try await call(source(days: 5))
        let f = try XCTUnwrap(j["forecast"])
        XCTAssertEqual(f["status"]?.string, "insufficient_data")
        XCTAssertEqual(f["weeks_needed"]?.int, 2)
        XCTAssertNil(f["reaches_80_percent"])
        XCTAssertTrue(f["summary"]?.string?.contains("more week") ?? false)
    }

    func testDesktop() async throws {
        let j = try await call(source(days: 30, battery: false))
        XCTAssertEqual(j["has_battery"]?.bool, false)
        XCTAssertEqual(j["summary"]?.string, "This Mac has no battery.")
        XCTAssertNil(j["forecast"])
    }
}
