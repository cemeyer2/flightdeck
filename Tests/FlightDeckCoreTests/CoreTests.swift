// Tests of the core sampling primitives against the real machine: Series gaps, sampler warm-up, the PID identity guard,
// trace file round trips, data providers, per-process energy and nettop parsing. Some tests need a live system and
// network (marked below); fixture and accuracy tests only run when their environment variable is set.
import XCTest
@testable import FlightDeckCore

final class CoreTests: XCTestCase {
    /// Graph history must keep nil entries as gaps, not drop or zero them.
    func testSeriesKeepsGaps() {
        var s = Series(capacity: 3)
        s.append(1.0); s.append(nil as Double?); s.append(3.0)
        XCTAssertEqual(s.values.count, 3)
        XCTAssertNil(s.values[1])
        XCTAssertEqual(s.latest, 3)
    }

    /// The first sample has no previous counters to diff against, so CPU must be reported unavailable rather than 0%;
    /// the second must be fully measured, including this test process itself.
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

    /// Signals are only delivered when PID and start time both match, so a recycled PID is never hit: a forged identity
    /// with a different start time must throw, the real one (signal 0, an existence check) must succeed.
    func testIdentityGuard() {
        let me = ProcessSampler.identity(of: getpid())!
        var fake = me; fake.startTime += 1
        XCTAssertThrowsError(try ProcessSampler.send(0, to: fake))
        XCTAssertNoThrow(try ProcessSampler.send(0, to: me))
    }

    /// A trimmed snapshot survives write/read through the .flightlog format (zlib-compressed JSON) intact.
    func testTraceRoundTrip() throws {
        let sampler = Sampler(); _ = sampler.sample(); Thread.sleep(forTimeInterval: 0.2)
        let t = Trace(host: "h", model: "m", interval: 1, frames: [Trace.trimmed(sampler.sample())])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t.\(Trace.fileExtension)")
        try t.write(to: url)
        let back = try Trace.read(from: url)
        XCTAssertEqual(back.frames.count, 1)
        XCTAssertEqual(back.frames[0].cpu.cores.count, t.frames[0].cpu.cores.count)
    }

    /// Smoke test that each on-demand provider (sysctl/IORegistry, launchctl, app scan, utmpx) returns something on a
    /// real Mac. Frequency and power are only printed, since they legitimately vary or are absent between Macs.
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

/// Per-process energy accounting.
final class EnergyTests: XCTestCase {
    /// A process burning CPU must show a positive measured energy (from the kernel's billed-energy counter), so
    /// energy readings aren't silently 0 or missing for busy processes.
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

/// Writes a sample recording for manual UI testing; skipped unless FD_WRITE_TRACE is set.
final class TraceFixture: XCTestCase {
    /// Writes /tmp/flightdeck-sample.flightlog (set FD_WRITE_TRACE=1) with a sampling gap in the middle.
    func testWriteSampleTrace() throws {
        guard ProcessInfo.processInfo.environment["FD_WRITE_TRACE"] != nil else { return }
        let s = Sampler(); _ = s.sample()
        var frames: [Snapshot] = []
        for i in 0..<40 {
            Thread.sleep(forTimeInterval: i == 20 ? 1.5 : 0.25)
            frames.append(Trace.trimmed(s.sample()))
        }
        try Trace(host: "fixture", model: "test", interval: 0.25, frames: frames).write(to: URL(fileURLWithPath: "/tmp/flightdeck-sample.flightlog"))
    }
}

/// Per-process network via nettop.
final class ProcessNetworkTests: XCTestCase {
    /// nettop's CSV lists a process line ("name.pid") followed by its connections; bytes must be attributed to the
    /// right PID, and connections with empty counters (listening sockets) count as 0 rather than breaking the parse.
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

    /// End-to-end against the real nettop (needs network access): the first snapshot is unavailable (no deltas yet),
    /// and after a real download this process must appear with the bytes it received.
    func testSeesOwnDownload() throws {
        let s = ProcessNetworkSampler()
        XCTAssertNil(s.sample(), "first snapshot must be unavailable, not zero")
        let exp = expectation(description: "download")
        // uncached session + unique URL: a cached response would never touch the network
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData; cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        let url = URL(string: "https://www.apple.com/?ml=\(UUID().uuidString)")!
        let task = session.dataTask(with: url) { _, _, _ in exp.fulfill() }
        task.resume()
        wait(for: [exp], timeout: 20)
        guard let net = s.sample() else { return XCTFail("nettop unavailable") }
        let mine = net[getpid()]
        print("NET self", mine as Any)
        XCTAssertNotNil(mine)
        XCTAssertGreaterThan(mine?.totalIn ?? 0, 1000)
    }
}

/// Accuracy check of nettop byte counts against a known payload; skipped unless FD_NET_ACCURACY is set.
final class ProcessNetworkAccuracy: XCTestCase {
    /// FD_NET_ACCURACY=1: download 5 MB with curl and compare counted bytes.
    func testCountsKnownDownload() throws {
        guard ProcessInfo.processInfo.environment["FD_NET_ACCURACY"] != nil else { return }
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
