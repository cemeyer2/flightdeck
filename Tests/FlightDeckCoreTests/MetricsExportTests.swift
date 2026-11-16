// Prometheus export tests: HELP/TYPE lines, label and help escaping, number formatting, omission of unmeasured values
// (never a 0 in their place), bounded process series, and a real scrape of the localhost server.
import XCTest
import Network
@testable import FlightDeckCore

final class MetricsExportTests: XCTestCase {
    /// A snapshot with known values, cloned from a real sample.
    func snapshot() -> Snapshot {
        var s = BlackBoxTests.base
        s.time = Date(timeIntervalSince1970: 1_700_000_000)
        s.cpu.total = .value(42.5); s.cpu.user = .value(30); s.cpu.system = .value(12.5)
        s.memory.measured = true; s.memory.used = 8_000_000_000; s.memory.total = 16_000_000_000
        s.memory.pressure = .value(35); s.memory.swapUsed = .value(0)
        s.disk.readBps = .value(1000); s.disk.writeBps = .value(2000)
        s.network.inBps = .value(10); s.network.outBps = .value(20)
        s.power.systemWatts = .value(12.25); s.power.hottest = .value(61); s.power.thermalState = 1
        s.power.fans = [FanReading(index: 0, rpm: 2400, minRPM: 1200, maxRPM: 6000, targetRPM: nil)]
        s.gpu = .value(7)
        return s
    }

    func line(_ text: String, _ prefix: String) -> String? { text.split(separator: "\n").map(String.init).first { $0.hasPrefix(prefix) } }

    func testFormatsHelpTypeAndValues() {
        let t = PrometheusText.render(snapshot())
        XCTAssertTrue(t.contains("# HELP flightdeck_cpu_usage_percent CPU usage"))
        XCTAssertTrue(t.contains("# TYPE flightdeck_cpu_usage_percent gauge\n"))
        XCTAssertTrue(t.contains("flightdeck_cpu_usage_percent{mode=\"total\"} 42.5\n"))
        XCTAssertTrue(t.contains("flightdeck_memory_used_bytes 8000000000\n"), "integral values have no exponent or fraction")
        XCTAssertTrue(t.contains("flightdeck_swap_used_bytes 0\n"), "a measured zero is still exported")
        XCTAssertTrue(t.contains("flightdeck_system_power_watts 12.25\n"))
        XCTAssertTrue(t.contains("flightdeck_fan_rpm{fan=\"0\"} 2400\n"))
        XCTAssertTrue(t.contains("flightdeck_snapshot_timestamp_seconds 1700000000\n"))
        XCTAssertTrue(t.hasSuffix("\n"))
        // Each family's HELP comes immediately before its TYPE, and each appears once.
        let lines = t.split(separator: "\n").map(String.init)
        for (i, l) in lines.enumerated() where l.hasPrefix("# HELP ") {
            let name = l.split(separator: " ")[2]
            XCTAssertTrue(lines[i + 1].hasPrefix("# TYPE \(name) "))
            XCTAssertEqual(lines.filter { $0.hasPrefix("# HELP \(name) ") }.count, 1)
        }
    }

    /// The core principle: unmeasured values are omitted entirely, family and all, never written as 0.
    func testUnmeasuredValuesAreOmitted() {
        var s = snapshot()
        s.power.systemWatts = .unavailable("not reported"); s.gpu = .unavailable("no GPU stats")
        s.cpu.user = .unavailable("warming up"); s.memory.measured = false
        s.power.fans = []; s.power.battery = nil
        let t = PrometheusText.render(s)
        XCTAssertFalse(t.contains("flightdeck_system_power_watts"))
        XCTAssertFalse(t.contains("flightdeck_gpu_usage_percent"))
        XCTAssertFalse(t.contains("flightdeck_fan_rpm"), "fanless: no fan series, not 0 rpm")
        XCTAssertFalse(t.contains("flightdeck_battery_percent"))
        XCTAssertFalse(t.contains("flightdeck_memory_used_bytes"), "placeholder byte counts aren't exported")
        XCTAssertFalse(t.contains("mode=\"user\""))
        XCTAssertTrue(t.contains("mode=\"total\""))
        // With CPU unavailable, per-core values (derived from the same counters) are omitted too.
        s.cpu.total = .unavailable("warming up")
        XCTAssertFalse(PrometheusText.render(s).contains("flightdeck_cpu_core_usage_percent"))
    }

    func testEscaping() {
        XCTAssertEqual(PrometheusText.escapeLabel("a\"b\\c\nd"), "a\\\"b\\\\c\\nd")
        XCTAssertEqual(PrometheusText.escapeHelp("x\\y\nz \"q\""), "x\\\\y\\nz \"q\"", "HELP doesn't escape quotes")
        var s = snapshot()
        var p = s.processes[0]; p.name = "Evil \"app\"\nname\\"; p.cpu = 999; p.restricted = false
        s.processes = [p]
        let t = PrometheusText.render(s)
        XCTAssertTrue(t.contains("flightdeck_process_cpu_percent{name=\"Evil \\\"app\\\"\\nname\\\\\",pid=\"\(p.pid)\"} 999\n"))
        XCTAssertEqual(PrometheusText.number(0.1), "0.1")
        XCTAssertEqual(PrometheusText.number(-3), "-3")
    }

    /// Only the top 20 processes by CPU are exported, names are truncated, and a restricted process's placeholder
    /// zeros are omitted.
    func testProcessSeriesAreBounded() {
        var s = snapshot()
        let base = s.processes[0]
        s.processes = (0..<50).map { i in
            var p = base; p.identity = ProcessIdentity(pid: Int32(1000 + i), startTime: 1); p.name = String(repeating: "n", count: 100)
            p.cpu = Double(i); p.restricted = false; p.memory = 1; p.energyWatts = nil; return p
        }
        s.processes[49].restricted = true; s.processes[49].cpuTime = 0; s.processes[49].memory = 0
        let t = PrometheusText.render(s)
        let cpuLines = t.split(separator: "\n").filter { $0.hasPrefix("flightdeck_process_cpu_percent{") }
        XCTAssertEqual(cpuLines.count, 19, "top 20, minus the restricted one with unreadable counters")
        XCTAssertFalse(t.contains("pid=\"1049\"} 0"), "no invented zero for the restricted process")
        XCTAssertFalse(t.contains("pid=\"1029\""), "the 21st process isn't exported")
        XCTAssertTrue(t.contains("name=\"\(String(repeating: "n", count: 64))\""))
        XCTAssertFalse(t.contains("flightdeck_process_energy_watts"), "no energy reported, none exported")
    }

    /// Starts the server on a free localhost port and scrapes it like Prometheus would.
    func testServerServesMetricsOnLocalhost() throws {
        let body = PrometheusText.render(snapshot())
        let server = MetricsServer(port: 0) { reply in reply(body) }
        let ready = expectation(description: "ready")
        let startError = Box<String?>(nil)
        server.start { err in startError.value = err; ready.fulfill() }
        wait(for: [ready], timeout: 5)
        if let startError = startError.value { throw XCTSkip("can't listen on localhost here: \(startError)") }
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        func get(_ path: String) throws -> (Int, String, String?) {
            let done = expectation(description: path)
            let result = Box<(Int, String, String?)>((0, "", nil))
            URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)\(path)")!) { d, r, _ in
                let h = r as? HTTPURLResponse
                result.value = (h?.statusCode ?? 0, d.map { String(decoding: $0, as: UTF8.self) } ?? "", h?.value(forHTTPHeaderField: "Content-Type"))
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: 5)
            return result.value
        }
        let (code, text, type) = try get("/metrics")
        XCTAssertEqual(code, 200)
        XCTAssertEqual(text, body)
        XCTAssertEqual(type, PrometheusText.contentType)
        XCTAssertEqual(try get("/").0, 404)
    }
}

/// A mutable cell for results set in callbacks; reads happen only after the test waited on the expectation.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
