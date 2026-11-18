// Tests for the Internet speed test: parsing networkQuality JSON across macOS versions, the plain-English verdicts,
// history retention and the schedule's gating. networkQuality itself is never run here (it moves real data and CI
// VMs have no reliable network); the fixtures are captured output.
import XCTest
@testable import FlightDeckCore

final class SpeedTestTests: XCTestCase {
    /// Real `networkQuality -c` output from macOS 27.2 (build 26B123), with the long per-probe latency arrays cut
    /// down to a few entries.
    static let macOS27 = """
    {
      "base_rtt" : 30.660074234008789, "cli_options" : ["-c"], "dl_bytes_transferred" : 872260535, "dl_flows" : 9,
      "dl_phase_duration" : 12.924425005912781, "dl_throughput" : 603042624, "draft_version" : 8,
      "end_date" : "2026-11-18 06:50:44.891", "il_h2_req_resp" : [25.19, 31.13, 24.03],
      "interface_name" : "en0", "lud_foreign_h2_req_resp" : [89, 92, 82],
      "os_version" : "Version 27.2 (Build 26B123)",
      "other" : { "ecn_values" : { "ecn_disabled" : 279 }, "interface-type" : { "wifi" : 279 }, "protocols_seen" : { "h2" : 279 } },
      "responsiveness" : 564.3526611328125, "start_date" : "2026-11-18 06:50:31.658",
      "test_endpoint" : "usdal2-edge-fx-003.aaplimg.com", "ul_bytes_transferred" : 57737215, "ul_flows" : 10,
      "ul_throughput" : 45259492
    }
    """

    /// The shape macOS 12 (Monterey) printed: no base_rtt, endpoint or byte counts, integer values.
    static let monterey = """
    {"dl_flows":12,"dl_throughput":93412345,"lud_foreign_h2_req_resp":[120,130],"responsiveness":1530,"ul_flows":12,"ul_throughput":11843211}
    """

    /// Sequential mode (-s) on macOS 13+: per-direction responsiveness, no combined figure; numbers as strings.
    static let sequential = """
    {"base_rtt":"18.5","dl_throughput":"250000000","dl_responsiveness":900,"ul_throughput":"20000000","ul_responsiveness":310,
     "other":{"interface-type":{"wiredethernet":40,"wifi":2}}}
    """

    func testParsesCurrentMacOSOutput() throws {
        let r = try SpeedTest.parse(Data(Self.macOS27.utf8))
        XCTAssertEqual(r.downloadMbps ?? 0, 603.04, accuracy: 0.01, "bits/s → Mbps")
        XCTAssertEqual(r.uploadMbps ?? 0, 45.26, accuracy: 0.01)
        XCTAssertEqual(r.responsivenessRPM ?? 0, 564.35, accuracy: 0.01)
        XCTAssertEqual(r.baseRTTms ?? 0, 30.66, accuracy: 0.01)
        XCTAssertEqual(r.interface, "en0"); XCTAssertEqual(r.interfaceType, "wifi")
        XCTAssertEqual(r.endpoint, "usdal2-edge-fx-003.aaplimg.com")
        XCTAssertEqual(r.downloadBytes, 872_260_535)
        XCTAssertEqual(r.loadedLatencyMs ?? 0, 60_000 / 564.35, accuracy: 0.1)
    }

    func testParsesOlderAndSequentialShapes() throws {
        let m = try SpeedTest.parse(Data(Self.monterey.utf8))
        XCTAssertEqual(m.downloadMbps ?? 0, 93.41, accuracy: 0.01)
        XCTAssertEqual(m.responsivenessRPM, 1530)
        XCTAssertNil(m.baseRTTms, "not reported → nil, not 0"); XCTAssertNil(m.latencyIncreaseMs); XCTAssertNil(m.endpoint)
        let s = try SpeedTest.parse(Data(Self.sequential.utf8))
        XCTAssertEqual(s.downloadMbps, 250); XCTAssertEqual(s.uploadMbps, 20); XCTAssertEqual(s.baseRTTms, 18.5)
        XCTAssertEqual(s.responsivenessRPM, 310, "the worse direction")
        XCTAssertEqual(s.interfaceType, "wiredethernet", "most common interface type")
    }

    func testParseFailures() {
        XCTAssertThrowsError(try SpeedTest.parse(Data("Error: no network connection\n".utf8))) { e in
            XCTAssertEqual(e as? SpeedTestError, .notJSON("Error: no network connection"))
        }
        XCTAssertThrowsError(try SpeedTest.parse(Data(#"{"error_code":-1009,"error_domain":"NSURLErrorDomain"}"#.utf8))) { e in
            XCTAssertEqual(e as? SpeedTestError, .reported("NSURLErrorDomain code -1009"))
        }
        XCTAssertThrowsError(try SpeedTest.parse(Data(#"{"dl_flows":1}"#.utf8))) { XCTAssertEqual($0 as? SpeedTestError, .noMeasurements) }
        XCTAssertThrowsError(try SpeedTest.parse(Data()))
        // Booleans are not numbers; a partial result keeps what was measured.
        let partial = try? SpeedTest.parse(Data(#"{"dl_throughput":true,"responsiveness":120}"#.utf8))
        XCTAssertNil(partial?.downloadMbps); XCTAssertEqual(partial?.responsivenessRPM, 120)
    }

    func result(down: Double?, up: Double?, rpm: Double?, base: Double? = 20, context: SpeedTestContext? = nil) -> SpeedTestResult {
        var r = SpeedTestResult(time: Date(timeIntervalSince1970: 0))
        r.downloadMbps = down; r.uploadMbps = up; r.responsivenessRPM = rpm; r.baseRTTms = base; r.context = context
        return r
    }

    func testHeadlineAndBands() {
        XCTAssertEqual(SpeedTestVerdict.headline(result(down: 412, up: nil, rpm: 150)),
                       "Download 412 Mbps; responsiveness Low: video calls may stutter under load (bufferbloat).")
        XCTAssertTrue(SpeedTestVerdict.headline(result(down: 1250, up: 40, rpm: 1500)).hasPrefix("Download 1.25 Gbps, upload 40.0 Mbps; responsiveness High"))
        XCTAssertEqual(SpeedTestVerdict.headline(result(down: nil, up: nil, rpm: nil)), "No measurements.")
        XCTAssertEqual(SpeedTestVerdict.responsiveness(199), .low)
        XCTAssertEqual(SpeedTestVerdict.responsiveness(200), .medium)
        XCTAssertEqual(SpeedTestVerdict.responsiveness(800), .high)
    }

    func testVerdictLines() {
        let slow = SpeedTestVerdict.lines(result(down: 3, up: 1, rpm: 100, base: 30))
        XCTAssertTrue(slow.contains { $0.kind == .caution && $0.text.contains("too slow for HD") })
        XCTAssertTrue(slow.contains { $0.text.contains("blurry") })
        XCTAssertTrue(slow.contains { $0.text.contains("bufferbloat") && $0.text.contains("570 ms") }, "600 ms loaded − 30 ms idle")
        XCTAssertTrue(slow.contains { $0.text.contains("Turn on latency probing") }, "no probe data → suggest it")
        // Fast test close to the Wi-Fi link rate: Wi-Fi is the limit.
        var wifi = SpeedTestContext(); wifi.wifiRSSI = -55; wifi.wifiTxRate = 600; wifi.routerMs = 3; wifi.internetMs = 14
        let near = SpeedTestVerdict.lines(result(down: 480, up: 40, rpm: 900, context: wifi))
        XCTAssertTrue(near.contains { $0.text.hasPrefix("Wi-Fi is likely the limit: the test reached 80%") })
        XCTAssertTrue(near.contains { $0.text.contains("local network is healthy") })
        XCTAssertFalse(near.contains { $0.text.contains("bufferbloat") })
        // Slow test on a fast link: the limit is elsewhere. Weak signal: blame Wi-Fi.
        XCTAssertTrue(SpeedTestVerdict.lines(result(down: 50, up: 10, rpm: 900, context: wifi)).contains { $0.text.hasPrefix("Wi-Fi isn't the bottleneck") })
        wifi.wifiRSSI = -78
        XCTAssertTrue(SpeedTestVerdict.lines(result(down: 50, up: 10, rpm: 900, context: wifi)).contains { $0.text.hasPrefix("Wi-Fi is weak") })
        // Slow router, internet loss without router loss.
        var bad = SpeedTestContext(); bad.routerMs = 45; bad.routerLoss = 0; bad.internetMs = 80; bad.internetLoss = 10
        let b = SpeedTestVerdict.lines(result(down: 100, up: 10, rpm: 500, context: bad))
        XCTAssertTrue(b.contains { $0.text.contains("router took 45 ms") })
        XCTAssertTrue(b.contains { $0.text.contains("at the provider") })
        var wired = result(down: 900, up: 900, rpm: 2000); wired.interfaceType = "wiredethernet"
        XCTAssertTrue(SpeedTestVerdict.lines(wired).contains { $0.text.contains("wired connection") })
    }

    func testHistoryRetentionAndRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = result(down: 1, up: 1, rpm: 1)
        var recent = result(down: 2, up: 2, rpm: 2); recent.time = now.addingTimeInterval(-3600)
        var newest = result(down: 3, up: 3, rpm: 3); newest.time = now
        let h = SpeedTestHistory.appending(newest, to: [recent, old], now: now)
        XCTAssertEqual(h.map(\.downloadMbps), [2, 3], "older than 90 days dropped, oldest first")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = SpeedTestHistory.url(in: dir)
        XCTAssertEqual(SpeedTestHistory.load(from: url), [], "missing file → empty")
        SpeedTestHistory.save(h, to: url)
        XCTAssertEqual(SpeedTestHistory.load(from: url), h)
    }

    func testScheduleGating() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func c(_ hours: Int = 3, last: Date? = nil, battery: Bool = false, pct: Double? = 80, expensive: Bool = false,
               constrained: Bool = false, online: Bool = true, demo: Bool = false, running: Bool = false) -> SpeedTestSchedule.Decision {
            SpeedTestSchedule.decide(.init(now: now, intervalHours: hours, lastRun: last, onBattery: battery, batteryPercent: pct,
                                           isExpensive: expensive, isConstrained: constrained, online: online, demo: demo, running: running))
        }
        XCTAssertEqual(c(0), .off, "off by default")
        XCTAssertEqual(c(demo: true), .off, "never in demo mode")
        XCTAssertEqual(c(), .run, "never run before")
        XCTAssertEqual(c(last: now.addingTimeInterval(-3600)), .notDue(now.addingTimeInterval(7200)))
        XCTAssertEqual(c(last: now.addingTimeInterval(-3 * 3600)), .run)
        XCTAssertEqual(c(last: now.addingTimeInterval(3600)), .run, "clock went backwards: don't wait forever")
        XCTAssertEqual(c(expensive: true), .skip("on a hotspot or metered connection"))
        XCTAssertEqual(c(constrained: true), .skip("Low Data Mode is on"))
        XCTAssertEqual(c(online: false), .skip("offline"))
        XCTAssertEqual(c(running: true), .skip("a test is already running"))
        XCTAssertEqual(c(battery: true, pct: 19), .skip("on battery at 19% (needs 20%)"))
        XCTAssertEqual(c(battery: true, pct: nil), .skip("on battery (charge unknown)"))
        XCTAssertEqual(c(battery: true, pct: 20), .run)
        XCTAssertEqual(c(battery: false, pct: 5), .run, "charge only matters on battery")
    }
}
