import XCTest
@testable import MeterCore

final class CoreTests: XCTestCase {
    func testSeriesKeepsGaps() {
        var s = Series(capacity: 3)
        s.append(1.0); s.append(nil as Double?); s.append(3.0)
        XCTAssertEqual(s.values.count, 3)
        XCTAssertNil(s.values[1])
        XCTAssertEqual(s.latest, 3)
    }

    func testSamplerProducesMeasuredValuesAfterWarmup() throws {
        let sampler = Sampler()
        let first = sampler.sample()
        XCTAssertFalse(first.cpu.total.isAvailable, "first CPU sample must be unavailable, not zero")
        Thread.sleep(forTimeInterval: 0.5)
        let s = sampler.sample()
        XCTAssertNotNil(s.cpu.total.value)
        XCTAssertFalse(s.cpu.cores.isEmpty)
        XCTAssertGreaterThan(s.memory.total, 0)
        XCTAssertGreaterThan(s.processes.count, 10)
        XCTAssertTrue(s.processes.contains { $0.pid == getpid() })
    }

    func testIdentityGuard() {
        let me = ProcessSampler.identity(of: getpid())!
        var fake = me; fake.startTime += 1
        XCTAssertThrowsError(try ProcessSampler.send(0, to: fake))
        XCTAssertNoThrow(try ProcessSampler.send(0, to: me))
    }

    func testTraceRoundTrip() throws {
        let sampler = Sampler(); _ = sampler.sample(); Thread.sleep(forTimeInterval: 0.2)
        let t = Trace(host: "h", model: "m", interval: 1, frames: [Trace.trimmed(sampler.sample())])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t.\(Trace.fileExtension)")
        try t.write(to: url)
        let back = try Trace.read(from: url)
        XCTAssertEqual(back.frames.count, 1)
        XCTAssertEqual(back.frames[0].cpu.cores.count, t.frames[0].cpu.cores.count)
    }

    func testProviders() {
        XCTAssertFalse(SystemInfo.collect().isEmpty)
        XCTAssertFalse(Launchd.services().isEmpty)
        XCTAssertFalse(InstalledApps.scan().isEmpty)
        XCTAssertFalse(Connections.sessions().isEmpty)
        print("FREQ", Frequency.clusters().map { "\($0.name) \($0.minMHz)-\($0.maxMHz)" })
        let p = Sampler().sample().power
        print("POWER", p.powerSource, p.batteryWatts, p.systemWatts, p.temperatures.count, p.hottest)
    }
}

final class EnergyTests: XCTestCase {
    func testBusyProcessReportsEnergy() {
        let s = ProcessSampler(); _ = s.sample()
        let end = Date().addingTimeInterval(0.6); var x = 0.0
        while Date() < end { x += sin(x) }   // burn CPU in this process
        let me = s.sample().first { $0.pid == getpid() }!
        print("SELF", me.cpu, me.energyWatts ?? -1, x > 0)
        XCTAssertGreaterThan(me.cpu, 30)
        XCTAssertGreaterThan(me.energyWatts ?? 0, 0)
    }
}

final class TraceFixture: XCTestCase {
    /// Writes /tmp/meterline-sample.mltrace (set ML_WRITE_TRACE=1) with a sampling gap in the middle.
    func testWriteSampleTrace() throws {
        guard ProcessInfo.processInfo.environment["ML_WRITE_TRACE"] != nil else { return }
        let s = Sampler(); _ = s.sample()
        var frames: [Snapshot] = []
        for i in 0..<40 {
            Thread.sleep(forTimeInterval: i == 20 ? 1.5 : 0.25)
            frames.append(Trace.trimmed(s.sample()))
        }
        try Trace(host: "fixture", model: "test", interval: 0.25, frames: frames).write(to: URL(fileURLWithPath: "/tmp/meterline-sample.mltrace"))
    }
}
