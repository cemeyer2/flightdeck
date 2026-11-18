// Thermal logic tests: `pmset -g therm` parsing, throttle detection and its finding, fan health rules, and the
// temperature alert thresholds (sustain, hysteresis, gaps, storage).
import XCTest
@testable import FlightDeckCore

final class ThermalLogicTests: XCTestCase {
    override func setUp() { UserDefaults.standard.set("celsius", forKey: TemperatureUnit.defaultsKey) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: TemperatureUnit.defaultsKey) }
    let t0 = Date(timeIntervalSince1970: 10_000)

    // MARK: pmset

    /// This Mac's real output: nothing has ever been recorded.
    func testParseNothingRecorded() {
        let l = ThermalLimits.parse("""
        Note: No thermal warning level has been recorded
        Note: No performance warning level has been recorded
        Note: No CPU power status has been recorded

        """)
        XCTAssertNil(l.cpuSpeedLimit); XCTAssertNil(l.cpuSchedulerLimit)
        XCTAssertFalse(l.thermalWarningRecorded); XCTAssertNil(l.thermalWarningLevel); XCTAssertNil(l.performanceWarningLevel)
        XCTAssertFalse(l.limited)
    }

    func testParseCPUPowerBlock() {
        let l = ThermalLimits.parse("""
        Note: No thermal warning level has been recorded
        Note: No performance warning level has been recorded
        2024-05-01 10:12:13 +0200 CPU Power notify
        \tCPU_Scheduler_Limit \t= 100
        \tCPU_Available_CPUs \t= 10
        \tCPU_Speed_Limit \t= 100
        2024-05-01 10:20:00 +0200 CPU Power notify
        \tCPU_Scheduler_Limit \t= 90
        \tCPU_Available_CPUs \t= 10
        \tCPU_Speed_Limit \t= 72
        """)
        XCTAssertEqual(l.cpuSpeedLimit, 72, "the last block wins")
        XCTAssertEqual(l.cpuSchedulerLimit, 90)
        XCTAssertEqual(l.availableCPUs, 10)
        XCTAssertTrue(l.limited)
    }

    func testParseRecordedWarningLevels() {
        let l = ThermalLimits.parse("""
        2024-05-01 10:12:13 +0200 Thermal Warning Level Set To 2
        Performance warning level: 1
        """)
        XCTAssertTrue(l.thermalWarningRecorded)
        XCTAssertEqual(l.thermalWarningLevel, 2, "the timestamp's digits are not the level")
        XCTAssertEqual(l.performanceWarningLevel, 1)
    }

    func testLiveRead() throws {
        guard let l = ThermalLimits.read() else { throw XCTSkip("pmset couldn't run here") }
        // Whatever this Mac says, limits are percentages.
        if let v = l.cpuSpeedLimit { XCTAssert((0...100).contains(v)) }
    }

    // MARK: Throttle

    func testThrottleVerdictAndTime() {
        let t = ThrottleTracker()
        var st = t.ingest(thermalState: 0, gpuThermalLimited: 0, at: t0)
        XCTAssertEqual(st.throttled, false)
        st = t.ingest(thermalState: 2, gpuThermalLimited: 0, at: t0.addingTimeInterval(10))
        XCTAssertEqual(st.throttled, true)
        XCTAssertEqual(st.throttledSeconds, 10)
        st = t.ingest(thermalState: 0, gpuThermalLimited: 25, at: t0.addingTimeInterval(20))
        XCTAssertEqual(st.throttled, true, "a GPU capped for heat counts")
        XCTAssertTrue(st.reasons[0].contains("GPU"))
        // A sleep-sized gap isn't counted as observed (or throttled) time.
        st = t.ingest(thermalState: 0, gpuThermalLimited: 0, at: t0.addingTimeInterval(1000))
        XCTAssertEqual(st.observedSeconds, 20); XCTAssertEqual(st.throttledSeconds, 20)
        XCTAssertEqual(st.throttled, false)
    }

    func testSpeedLimitFindingNeedsAMinuteAndFreshReadings() throws {
        let t = ThrottleTracker()
        let limited = ThermalLimits(cpuSpeedLimit: 80, cpuSchedulerLimit: 100)
        t.note(limited, at: t0)
        t.ingest(thermalState: 0, gpuThermalLimited: nil, at: t0.addingTimeInterval(1))
        XCTAssertNil(t.finding(at: t0.addingTimeInterval(30)), "not yet a minute")
        XCTAssertTrue(t.status.reasons.contains { $0.contains("80%") })
        t.note(limited, at: t0.addingTimeInterval(30)); t.note(limited, at: t0.addingTimeInterval(60))
        let f = try XCTUnwrap(t.finding(at: t0.addingTimeInterval(61)))
        XCTAssertEqual(f.id, "cpu-speed-limit"); XCTAssertEqual(f.since, t0); XCTAssertTrue(f.title.contains("80%"))
        // Polling stopped (tab closed): a stale reading claims nothing.
        XCTAssertNil(t.finding(at: t0.addingTimeInterval(60 + ThrottleTracker.limitsStale + 1)))
        // The limit lifted: gone.
        t.note(ThermalLimits(cpuSpeedLimit: 100), at: t0.addingTimeInterval(90))
        XCTAssertNil(t.finding(at: t0.addingTimeInterval(91)))
    }

    // MARK: Fans

    func fan(_ i: Int, _ rpm: Double, target: Double?, max: Double? = 5800) -> FanReading {
        FanReading(index: i, rpm: rpm, minRPM: 1200, maxRPM: max, targetRPM: target)
    }

    func testFanStalledWhenHot() throws {
        let m = FanHealthMonitor()
        m.ingest(fans: [fan(0, 0, target: 3000)], hottest: 85, at: t0)
        XCTAssertEqual(m.statuses[0].issues, [], "spinning up takes a moment")
        m.ingest(fans: [fan(0, 0, target: 3000)], hottest: 85, at: t0.addingTimeInterval(25))
        XCTAssertEqual(m.statuses[0].issues, [.stalled])
        let f = try XCTUnwrap(m.findings(at: t0.addingTimeInterval(25)).first)
        XCTAssertEqual(f.severity, .warning); XCTAssertEqual(f.since, t0)
        // Cool, or no speed requested (Apple silicon stops fans when cool): not a problem.
        let cool = FanHealthMonitor()
        cool.ingest(fans: [fan(0, 0, target: 3000)], hottest: 50, at: t0)
        cool.ingest(fans: [fan(0, 0, target: 3000)], hottest: 50, at: t0.addingTimeInterval(60))
        XCTAssertEqual(cool.statuses[0].issues, [])
        let idle = FanHealthMonitor()
        idle.ingest(fans: [fan(0, 0, target: 0)], hottest: 90, at: t0)
        idle.ingest(fans: [fan(0, 0, target: 0)], hottest: 90, at: t0.addingTimeInterval(60))
        XCTAssertEqual(idle.statuses[0].issues, [])
    }

    func testFanLaggingNeedsSustainedShortfall() {
        let m = FanHealthMonitor()
        m.ingest(fans: [fan(0, 2000, target: 4000)], hottest: 80, at: t0)
        m.ingest(fans: [fan(0, 2000, target: 4000)], hottest: 80, at: t0.addingTimeInterval(30))
        XCTAssertEqual(m.statuses[0].issues, [])
        m.ingest(fans: [fan(0, 2000, target: 4000)], hottest: 80, at: t0.addingTimeInterval(61))
        XCTAssertEqual(m.statuses[0].issues, [.lagging])
        // Catching up resets the clock.
        m.ingest(fans: [fan(0, 3900, target: 4000)], hottest: 80, at: t0.addingTimeInterval(62))
        XCTAssertEqual(m.statuses[0].issues, [])
        XCTAssertEqual(m.statuses[0].percentOfMax ?? 0, 3900 / 5800 * 100, accuracy: 1e-9)
    }

    func testFansDisagree() {
        let m = FanHealthMonitor()
        let pair = [fan(0, 4000, target: 4000), fan(1, 1800, target: 3900)]
        m.ingest(fans: pair, hottest: 80, at: t0)
        m.ingest(fans: pair, hottest: 80, at: t0.addingTimeInterval(61))
        XCTAssertEqual(m.statuses[0].issues, [])
        XCTAssertTrue(m.statuses[1].issues.contains(.disagree), "the slower fan is flagged")
        // Asked for different speeds: they're meant to differ.
        XCTAssertEqual(FanHealthMonitor.disagree([fan(0, 4000, target: 4000), fan(1, 1800, target: 1800)]), [])
    }

    func testFanlessAndUnknown() {
        let m = FanHealthMonitor()
        m.ingest(fans: [], hottest: 80, at: t0)
        XCTAssertEqual(m.fanless, true)
        m.ingest(fans: nil, hottest: 80, at: t0.addingTimeInterval(1))
        XCTAssertNil(m.fanless, "unknown is not fanless")
    }

    // MARK: Alerts

    func cpu(_ v: Double) -> [GroupReading] { [GroupReading(family: .cpu, max: v, average: v, hottest: "P-core 3", count: 8)] }

    func testAlertNeedsSustainedHeatAndUsesHysteresis() throws {
        let m = TemperatureAlertMonitor()
        m.rules = [TemperatureAlertRule(family: .cpu, enabled: true, thresholdC: 95, minutes: 2)]
        XCTAssertEqual(m.ingest(cpu(97), at: t0), [])
        XCTAssertEqual(m.ingest(cpu(98), at: t0.addingTimeInterval(60)), [])
        let f = try XCTUnwrap(m.ingest(cpu(97), at: t0.addingTimeInterval(120)).first)
        XCTAssertEqual(f.id, "temp-alert:cpu"); XCTAssertEqual(f.since, t0)
        XCTAssertEqual(f.title, "CPU is above 95 °C: 97 °C")
        XCTAssertTrue(f.detail?.contains("P-core 3") == true)
        // Dipping just under the line keeps it firing; dropping past the hysteresis clears it.
        XCTAssertEqual(m.ingest(cpu(94), at: t0.addingTimeInterval(124)).count, 1)
        XCTAssertEqual(m.ingest(cpu(92), at: t0.addingTimeInterval(128)), [])
        XCTAssertEqual(m.ingest(cpu(97), at: t0.addingTimeInterval(132)), [], "starts over")
    }

    func testAlertOffOrGapDoesNotFire() {
        let m = TemperatureAlertMonitor()
        m.rules = [TemperatureAlertRule(family: .cpu, enabled: false, thresholdC: 50, minutes: 1)]
        XCTAssertEqual(m.ingest(cpu(97), at: t0), [])
        XCTAssertEqual(m.ingest(cpu(97), at: t0.addingTimeInterval(120)), [])
        m.rules[0].enabled = true
        _ = m.ingest(cpu(97), at: t0.addingTimeInterval(130))
        XCTAssertEqual(m.ingest(cpu(97), at: t0.addingTimeInterval(400)), [], "a gap (sleep) restarts the clock")
    }

    func testAlertRulesStorage() {
        XCTAssertTrue(TemperatureAlertRule.defaults.allSatisfy { !$0.enabled }, "every alert starts off")
        var r = TemperatureAlertRule.defaults; r[0].enabled = true; r[0].thresholdC = 88
        let loaded = TemperatureAlertRule.load(TemperatureAlertRule.save([r[0]]))
        XCTAssertEqual(loaded.count, TemperatureAlertRule.defaults.count, "missing families fall back to defaults")
        XCTAssertEqual(loaded[0], r[0])
        XCTAssertEqual(TemperatureAlertRule.load(Data("junk".utf8)), TemperatureAlertRule.defaults)
    }

    // MARK: ThermalWatch

    func testWatchCountsEachSensorReadOnce() {
        let w = ThermalWatch(chip: .m1Pro)
        var s = BlackBoxTests.base
        s.power.temperatures = [SensorReading(name: "PMU tdie1", celsius: 50)]
        s.power.smcTemperatures = [SensorReading(name: "Tp01", celsius: 70)]
        s.power.sensorsReadAt = t0
        for i in 0..<4 { s.time = t0.addingTimeInterval(Double(i)); _ = w.ingest(s) }
        XCTAssertEqual(w.history.stats("smc:Tp01")?.count, 1)
        XCTAssertEqual(w.status().catalog?.reading(for: .cpu)?.max, 70)
    }
}
