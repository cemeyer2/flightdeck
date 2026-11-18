// "Why is the fan loud?" tests: when the card appears, the headline wording, blame by energy vs CPU, the fanless
// (throttling) explanation, and that unmeasured inputs are left out instead of guessed.
import XCTest
@testable import FlightDeckCore

final class FanExplainerTests: XCTestCase {
    // The expected sentences are in °C; the default unit follows the Mac's region, so pin it.
    override func setUp() { UserDefaults.standard.set("celsius", forKey: TemperatureUnit.defaultsKey) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: TemperatureUnit.defaultsKey) }

    func proc(_ name: String, _ path: String, pid: Int32, cpu: Double, watts: Double?) -> ProcessSample {
        var p = BlackBoxTests.base.processes[0]; p.restricted = false   // copied from a real process, which may be a restricted system one
        p.identity = ProcessIdentity(pid: pid, startTime: 1); p.name = name; p.path = path; p.cpu = cpu; p.energyWatts = watts
        p.restricted = false
        return p
    }

    /// A calm machine: fans at idle, nominal thermal state, no GPU heat limit.
    func calm() -> Snapshot {
        var s = BlackBoxTests.base
        s.power.thermalState = 0
        s.power.fans = [FanReading(index: 0, rpm: 1200, minRPM: 1200, maxRPM: 5800, targetRPM: nil)]
        s.power.temperatures = [SensorReading(name: "PMU tdie1", celsius: 45), SensorReading(name: "PMU tcal", celsius: 52)]
        s.power.hottest = .value(52)
        s.gpuDetail?.thermalLimited = 0
        s.processes = [proc("Photos", "/System/Applications/Photos.app/Contents/MacOS/Photos", pid: 10, cpu: 150, watts: 6),
                       proc("Safari", "/Applications/Safari.app/Contents/MacOS/Safari", pid: 11, cpu: 50, watts: 3),
                       proc("tiny", "/usr/bin/tiny", pid: 12, cpu: 1, watts: 1)]
        return s
    }

    func testNothingToExplainWhenCalm() {
        XCTAssertNil(FanExplainer.explain(calm()))
        var s = calm(); s.power.fans = [FanReading(index: 0, rpm: 0, minRPM: 1499, maxRPM: 5348, targetRPM: 0)]
        XCTAssertNil(FanExplainer.explain(s), "a stopped fan is idle, not a reason to show the card")
    }

    /// The example sentence from the spec: fan speed against idle, the hottest component, and the app to blame.
    func testHeadlineConnectsFanHeatAndApp() throws {
        var s = calm()
        s.power.fans = [FanReading(index: 0, rpm: 4200, minRPM: 1200, maxRPM: 6000, targetRPM: nil)]
        s.power.temperatures.append(SensorReading(name: "CPU performance cores", celsius: 92))
        let x = try XCTUnwrap(FanExplainer.explain(s))
        XCTAssertEqual(x.headline, "Fan at 4,200 rpm (idle ~1,200) because the CPU is at 92 °C; Photos is responsible for ~60% of the power draw.")
        XCTAssertTrue(x.byEnergy)
        XCTAssertEqual(x.culprits.map(\.name), ["Photos", "Safari"], "apps under 15% aren't named")
        XCTAssertTrue(x.details.contains("Fan 1: 4,200 rpm, 70% of its 6,000 rpm maximum (minimum 1,200)"))
        XCTAssertTrue(x.details.contains { $0.contains("nominal") })
        XCTAssertTrue(x.details.contains("The GPU is not being limited by heat."))
        XCTAssertEqual(x.severity, .caution, "fans above 70% of maximum")
    }

    /// Calibration sensors ("tcal") read hotter than any component and are never named as the hot part.
    func testIgnoresCalibrationSensor() throws {
        var s = calm(); s.power.fans![0].rpm = 3000
        let x = try XCTUnwrap(FanExplainer.explain(s))
        XCTAssertTrue(x.headline.contains("because the chip is at 45 °C"), x.headline)
    }

    /// Without energy figures, blame falls back to CPU share and says so.
    func testFallsBackToCPUShare() throws {
        var s = calm(); s.power.fans![0].rpm = 3000
        for i in s.processes.indices { s.processes[i].energyWatts = nil }
        let x = try XCTUnwrap(FanExplainer.explain(s))
        XCTAssertFalse(x.byEnergy)
        XCTAssertTrue(x.headline.hasSuffix("Photos is responsible for ~75% of the CPU load."), x.headline)
    }

    /// Fanless Macs: the explanation is about throttling, including the GPU heat limit and kernel_task.
    func testFanlessExplainsThrottling() throws {
        var s = calm()
        s.power.fans = []; s.power.thermalState = 2; s.gpuDetail?.thermalLimited = 40
        s.processes.append(proc("kernel_task", "", pid: 0, cpu: 300, watts: nil))
        let x = try XCTUnwrap(FanExplainer.explain(s))
        XCTAssertFalse(x.hasFans)
        XCTAssertTrue(x.headline.hasPrefix("This Mac has no fans, so it cools down by slowing the CPU and GPU; the chip is at 45 °C"), x.headline)
        XCTAssertTrue(x.details.contains { $0.contains("serious") })
        XCTAssertTrue(x.details.contains("The GPU was clock-limited by temperature 40% of the time."))
        XCTAssertTrue(x.details.contains { $0.hasPrefix("kernel_task is at 300% CPU") })
        XCTAssertFalse(x.culprits.contains { $0.name == "kernel_task" }, "kernel_task is the cure, not the cause")
        XCTAssertEqual(x.severity, .warning)
    }

    /// Unknown inputs stay unknown: no temperatures, no fan data, no GPU statistics means no claims about them.
    func testOmitsUnmeasuredInputs() throws {
        var s = calm()
        s.power.fans = nil; s.power.temperatures = []; s.power.hottest = .unavailable("no sensors")
        s.gpuDetail?.thermalLimited = nil; s.power.thermalState = 1
        for i in s.processes.indices { s.processes[i].energyWatts = nil; s.processes[i].cpu = 0 }
        let x = try XCTUnwrap(FanExplainer.explain(s))
        XCTAssertEqual(x.headline, "Thermal pressure is fair.")
        XCTAssertFalse(x.details.contains { $0.contains("GPU") })
        XCTAssertTrue(x.culprits.isEmpty)
    }

    func testGrouping() {
        XCTAssertEqual(FanExplainer.group(999), "999")
        XCTAssertEqual(FanExplainer.group(1234.6), "1,235")
        XCTAssertEqual(FanExplainer.group(1_234_567), "1,234,567")
    }
}
