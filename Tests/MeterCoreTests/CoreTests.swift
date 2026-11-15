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

final class ProcessNetworkTests: XCTestCase {
    func testParse() {
        let out = """
        ,bytes_in,bytes_out,
        Google Chrome H.883,300,40,
        tcp4 10.0.0.2:5000<->1.2.3.4:443,100,10,
        tcp4 10.0.0.2:5001<->1.2.3.4:443,200,30,
        launchd.1,0,0,
        tcp4 *:22<->*:*,,,
        """
        let f = ProcessNetworkSampler.parse(out)
        XCTAssertEqual(f.count, 3)
        XCTAssertEqual(f.filter { $0.key.pid == 883 }.values.map(\.0).reduce(0, +), 300)
        XCTAssertEqual(f.filter { $0.key.pid == 1 }.values.map(\.0).reduce(0, +), 0)
    }

    func testSeesOwnDownload() throws {
        let s = ProcessNetworkSampler()
        XCTAssertNil(s.sample(), "first snapshot must be unavailable, not zero")
        let exp = expectation(description: "download")
        let url = URL(string: "https://www.apple.com/")!
        let task = URLSession.shared.dataTask(with: url) { _, _, _ in exp.fulfill() }
        task.resume()
        wait(for: [exp], timeout: 20)
        guard let net = s.sample() else { return XCTFail("nettop unavailable") }
        let mine = net[getpid()]
        print("NET self", mine as Any)
        XCTAssertNotNil(mine)
        XCTAssertGreaterThan(mine?.totalIn ?? 0, 1000)
    }
}

final class ProcessNetworkAccuracy: XCTestCase {
    /// ML_NET_ACCURACY=1: download 5 MB with curl and compare counted bytes.
    func testCountsKnownDownload() throws {
        guard ProcessInfo.processInfo.environment["ML_NET_ACCURACY"] != nil else { return }
        let s = ProcessNetworkSampler(); _ = s.sample()
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-o", "/dev/null", "--limit-rate", "1M", "https://speed.cloudflare.com/__down?bytes=5000000"]
        try p.run()
        var last: ProcessNetwork?
        while p.isRunning { Thread.sleep(forTimeInterval: 1); if let n = s.sample()?[p.processIdentifier] { last = n } }
        let counted = Double(last?.totalIn ?? 0)
        print(String(format: "ACCURACY counted %.2f MB of 5.00 MB payload (%.0f%%)", counted / 1e6, counted / 5e6 * 100))
        XCTAssertGreaterThan(counted, 3.5e6)
    }
}
