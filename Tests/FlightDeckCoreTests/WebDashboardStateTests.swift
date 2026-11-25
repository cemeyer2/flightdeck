// Web dashboard, part 5: the state document served to browsers. What it withholds (private kinds, muted findings,
// names, identifiers), its never-a-fake-zero readings, the 64 KB cap and the 30-minute history.
import XCTest
@testable import FlightDeckCore

final class WebDashboardStateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot() -> Snapshot {
        var s = BlackBoxTests.base
        s.time = t0
        s.cpu.total = .value(42.5)
        s.memory.measured = true; s.memory.used = 8_000_000_000; s.memory.total = 16_000_000_000
        s.memory.pressure = .value(35); s.memory.swapUsed = .value(0)
        s.disk.readBps = .value(1000); s.disk.writeBps = .value(2000)
        s.network.inBps = .value(10); s.network.outBps = .value(20)
        s.power.systemWatts = .value(12.25); s.power.hottest = .value(61); s.power.thermalState = 1
        s.power.fans = [FanReading(index: 0, rpm: 2400, minRPM: 1200, maxRPM: 6000, targetRPM: nil)]
        s.gpu = .value(7)
        s.processes = []
        return s
    }

    func proc(_ pid: Int32, _ name: String, path: String, cpu: Double = 1, memory: UInt64 = 1 << 20) -> ProcessSample {
        ProcessSample(identity: ProcessIdentity(pid: pid, startTime: 1), ppid: 1, name: name, path: path,
                      user: "me", uid: 501, cpu: cpu, cpuTime: 0, memory: memory, threads: 1, diskReadBps: 0, diskWriteBps: 0,
                      diskRead: 0, diskWritten: 0, energyWatts: nil, wakeups: 0, restricted: false)
    }

    func finding(_ id: String, _ s: Finding.Severity = .caution, title: String? = nil, detail: String? = nil, since: Date? = nil) -> Finding {
        Finding(id: id, severity: s, icon: "cpu", title: title ?? id, detail: detail, since: since ?? t0, destination: nil)
    }

    func inputs(snapshot: Snapshot?, findings: [Finding] = [], incidents: [Incident] = [], history: WebHistory = .none,
                displayName: String = "", redaction: FleetRedaction = FleetRedaction(names: []),
                paused: Bool = false) -> WebDashboardInputs {
        WebDashboardInputs(snapshot: snapshot, findings: findings, incidents: incidents, history: history,
                           displayName: displayName, modelName: "MacBook Pro", hardwareModel: "Mac16,7", macOS: "26.1",
                           appVersion: "1.6.0", uptime: 86400, paused: paused, intervalS: 1, redaction: redaction)
    }

    func json(_ d: WebDashboardDocument) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: WebDashboardState.encode(d)) as? [String: Any])
    }
    func text(_ d: WebDashboardDocument) -> String { String(decoding: WebDashboardState.encode(d), as: UTF8.self) }

    /// Review focus: the first seconds after launch give a valid document, never zeros.
    func testNoSnapshotYet() throws {
        let doc = WebDashboardState.build(inputs(snapshot: nil))
        let j = try json(doc)
        XCTAssertTrue(j["sampled_at"] == nil || j["sampled_at"] is NSNull)
        let readings = try XCTUnwrap(j["readings"] as? [String: Any])
        let cpu = try XCTUnwrap(readings["cpu_percent"] as? [String: Any])
        XCTAssertTrue(cpu["value"] is NSNull, "value is present and null")
        XCTAssertEqual(cpu["reason"] as? String, "No sample yet")
        XCTAssertEqual((readings["fan_rpm"] as? [String: Any])?["reason"] as? String, "No sample yet")
        let d = JSONDecoder.fleet; d.keyDecodingStrategy = .convertFromSnakeCase
        let back = try d.decode(WebDashboardDocument.self, from: WebDashboardState.encode(doc))
        XCTAssertEqual(back, doc)
    }

    func testUnavailableIsNullWithReason() {
        var s = snapshot(); s.gpu = .unavailable("no GPU stats")
        let t = text(WebDashboardState.build(inputs(snapshot: s)))
        XCTAssertTrue(t.contains(#""gpu_percent":{"reason":"no GPU stats","value":null}"#), t)
        XCTAssertFalse(t.contains(#""gpu_percent":{"value":0"#))
        XCTAssertTrue(t.contains(#""cpu_percent":{"value":42.5}"#))
        XCTAssertTrue(t.contains(#""fan_rpm":{"value":2400}"#))
        XCTAssertTrue(t.contains(#""thermal_state":"fair""#))
    }

    func testSnakeCaseAndV() {
        let t = text(WebDashboardState.build(inputs(snapshot: snapshot())))
        for key in [#""v":1"#, #""interval_s""#, #""top_apps""#, #""findings_truncated""#, #""uptime_s""#, #""sampled_at":"2027-01-15T08:00:00Z""#] {
            XCTAssertTrue(t.contains(key), key)
        }
        XCTAssertFalse(t.contains(#""demo""#), "absent outside the CLI demo")
    }

    func testRedaction() throws {
        var s = snapshot()
        s.processes = [proc(10, "charlie-tool", path: "/Users/charlie/bin/charlie-tool", cpu: 50)]
        let muted = finding("disk-low", .warning, title: "Disk low")
        let doc = WebDashboardState.build(WebDashboardInputs(
            snapshot: s, findings: [finding("privacy:camera", title: "Camera on"), muted, finding("cpu:x", title: "charlie's build")],
            incidents: [], displayName: "Charlie's MacBook", modelName: "MacBook Pro", hardwareModel: "Mac16,7", macOS: "26.1",
            appVersion: "1.6.0", uptime: nil, paused: false, intervalS: 1, redaction: FleetRedaction(names: ["charlie"]),
            isMuted: { $0.id == "disk-low" }))
        XCTAssertEqual(doc.findings.map(\.title), ["‹user›'s build"])
        XCTAssertEqual(doc.annunciator.first { $0.key == "storage" }?.level, "ok", "a muted finding doesn't light its lamp")
        XCTAssertEqual(doc.annunciator.first { $0.key == "cpu" }?.level, "caution")
        XCTAssertEqual(doc.topApps.map(\.name), ["‹user›-tool"])
        XCTAssertFalse(doc.mac.name.lowercased().contains("charlie"))
        XCTAssertFalse(text(doc).contains("Camera"))
    }

    func testNameDefaultsToModel() {
        let doc = WebDashboardState.build(inputs(snapshot: nil, displayName: "  "))
        XCTAssertEqual(doc.mac.name, "MacBook Pro")
        XCTAssertEqual(doc.mac.model, "Mac16,7")
        XCTAssertEqual(WebDashboardState.build(inputs(snapshot: nil, displayName: " Studio ")).mac.name, "Studio")
    }

    func testTopAppsHaveNoIdentifiers() throws {
        var s = snapshot()
        let chrome = "/Applications/Google Chrome.app"
        s.processes = [proc(1, "Google Chrome", path: "\(chrome)/Contents/MacOS/Google Chrome", cpu: 30),
                       proc(2, "Google Chrome Helper", path: "\(chrome)/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", cpu: 20),
                       proc(3, "Google Chrome Helper (Renderer)", path: "\(chrome)/Contents/Frameworks/Google Chrome Helper (Renderer).app/Contents/MacOS/x", cpu: 10)]
            + (0..<20).map { proc(100 + Int32($0), "tool\($0)", path: "/usr/bin/tool\($0)", cpu: Double($0)) }
        let doc = WebDashboardState.build(inputs(snapshot: s))
        XCTAssertEqual(doc.topApps.count, 10)
        XCTAssertEqual(doc.topApps.first?.name, "Google Chrome")
        XCTAssertEqual(doc.topApps.first?.count, 3)
        XCTAssertEqual(doc.topApps.first?.cpuPercent, 60)
        let apps = try XCTUnwrap(try json(doc)["top_apps"] as? [[String: Any]])
        let appsJSON = String(decoding: try JSONSerialization.data(withJSONObject: apps, options: [.withoutEscapingSlashes]), as: UTF8.self)
        for bad in [#""pid""#, #""path""#, #""user""#, "/"] { XCTAssertFalse(appsJSON.contains(bad), bad) }
    }

    func testHelperSeamExcludes() {
        var p = snapshot()
        p.processes = [proc(1, "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", cpu: 5)]
        var a = p
        let extra = [proc(9, "secret", path: "/usr/libexec/secret", cpu: 90), proc(8, "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", cpu: 50)]
        a.processes += extra
        let f = finding("hang:99-1", .warning, title: "Something root is hung")
        let keep = finding("cpu:x", .caution)
        let extraIDs = Set(extra.map(\.identity))
        let docA = WebDashboardState.build(WebDashboardInputs(
            snapshot: a, findings: [keep, f], incidents: [], displayName: "", modelName: "Mac", hardwareModel: "", macOS: "26",
            appVersion: "1", uptime: nil, paused: false, intervalS: 1, redaction: FleetRedaction(names: []),
            excludeProcess: { extraIDs.contains($0.identity) }, excludeFinding: { $0.id == f.id }))
        let docB = WebDashboardState.build(WebDashboardInputs(
            snapshot: p, findings: [keep], incidents: [], displayName: "", modelName: "Mac", hardwareModel: "", macOS: "26",
            appVersion: "1", uptime: nil, paused: false, intervalS: 1, redaction: FleetRedaction(names: [])))
        XCTAssertEqual(WebDashboardState.encode(docA), WebDashboardState.encode(docB))
    }

    func testCapTruncatesInOrder() throws {
        let long = String(repeating: "incident words ", count: 20)
        let incidents = (0..<300).map { i in
            Incident(id: UUID(), key: "cpu:\(i)", severity: .caution, icon: "cpu", title: "\(i) \(long)", detail: long,
                     destination: nil, start: t0.addingTimeInterval(Double(i)), end: t0.addingTimeInterval(Double(i) + 60))
        }
        let doc = WebDashboardState.build(inputs(snapshot: snapshot(), findings: [finding("cpu:a")], incidents: incidents))
        let data = WebDashboardState.encode(doc)
        XCTAssertLessThanOrEqual(data.count, WebDashboardState.maxBytes)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(j["incidents_truncated"] as? Bool, true)
        XCTAssertEqual(j["findings_truncated"] as? Bool, false)
        let kept = try XCTUnwrap(j["incidents"] as? [[String: Any]])
        XCTAssertTrue((kept.first?["title"] as? String)?.hasPrefix("299 ") == true, "the newest incidents stay")

        var s = snapshot()
        s.processes = (0..<10).map { proc(Int32($0), String(repeating: "n", count: 10_000) + "\($0)", path: "/usr/bin/x\($0)", cpu: Double($0)) }
        let doc2 = WebDashboardState.build(inputs(snapshot: s, incidents: incidents))
        XCTAssertTrue(doc2.topApps.allSatisfy { $0.name.count <= 64 })
        let j2 = try XCTUnwrap(JSONSerialization.jsonObject(with: WebDashboardState.encode(doc2)) as? [String: Any])
        XCTAssertEqual(j2["incidents_truncated"] as? Bool, true)
        XCTAssertEqual(j2["top_apps_truncated"] as? Bool, false, "incidents go first")
    }

    func testHistoryGapsAndBuckets() {
        let now = t0
        var frames: [Snapshot] = []
        var t = now.addingTimeInterval(-1790)
        while t <= now {
            // A 5-minute hole from now−900 s to now−600 s.
            if !(t > now.addingTimeInterval(-900) && t <= now.addingTimeInterval(-600)) {
                var s = snapshot(); s.time = t; frames.append(s)
            }
            t += 5
        }
        let h = WebDashboardState.history(frames: frames, now: now)
        XCTAssertEqual(h.count, 60)
        let gaps = h.filter { $0.gap == true }
        XCTAssertEqual(gaps.count, 10)
        XCTAssertTrue(gaps.allSatisfy { $0.cpuPercent == nil && $0.memoryPercent == nil && $0.hottestC == nil })
        XCTAssertTrue(h.filter { $0.gap != true }.allSatisfy { $0.cpuPercent == 42.5 && $0.memoryPercent == 50 }, "no value is interpolated")
        XCTAssertEqual(h.last?.t, now)
        XCTAssertTrue(zip(h, h.dropFirst()).allSatisfy { $0.t < $1.t })
    }

    func testHistoryUnavailable() throws {
        let doc = WebDashboardState.build(inputs(snapshot: snapshot(), history: .unavailable("The black box is turned off in Settings.")))
        XCTAssertEqual(doc.history, [])
        XCTAssertEqual(doc.historyUnavailable, "The black box is turned off in Settings.")
        XCTAssertNil(WebDashboardState.build(inputs(snapshot: snapshot())).history, "no history in a sample event")
        XCTAssertEqual(try json(doc)["history_unavailable"] as? String, "The black box is turned off in Settings.")
    }

    func testNoRawNewlines() {
        var s = snapshot()
        s.processes = [proc(1, "x\r\n\r\ndata: evil", path: "", cpu: 5)]
        let d = WebDashboardState.encode(WebDashboardState.build(inputs(snapshot: s, findings: [finding("cpu:x", detail: "line1\nline2\r\nline3")])))
        XCTAssertFalse(d.contains(0x0A))
        XCTAssertFalse(d.contains(0x0D))
    }

    func testXSSNameRoundTrips() throws {
        var s = snapshot()
        let evil = "<img src=x onerror=alert(1)>"
        s.processes = [proc(1, evil, path: "", cpu: 5)]
        let data = WebDashboardState.encode(WebDashboardState.build(inputs(snapshot: s)))
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((j["top_apps"] as? [[String: Any]])?.first?["name"] as? String, evil)
    }

    func testIntervalAndSampling() {
        XCTAssertEqual(WebDashboardState.interval(visible: false, interval: 1, background: 2), 5)
        XCTAssertEqual(WebDashboardState.interval(visible: false, interval: 1, background: 10), 10)
        XCTAssertEqual(WebDashboardState.interval(visible: true, interval: 1, background: 10), 1)
        XCTAssertEqual(WebDashboardState.build(inputs(snapshot: nil, paused: true)).sampling, "paused")
        XCTAssertEqual(WebDashboardState.build(inputs(snapshot: nil)).sampling, "live")
    }

    func testModelName() {
        let fixture = #"""
        {"SPHardwareDataType" : [{"_name" : "hardware_overview", "chip_type" : "Apple M4 Pro", "machine_model" : "Mac16,7", "machine_name" : "MacBook Pro"}]}
        """#
        XCTAssertEqual(WebMacModel.name(systemProfilerJSON: Data(fixture.utf8)), "MacBook Pro")
        XCTAssertNil(WebMacModel.name(systemProfilerJSON: Data("{}".utf8)))
    }
}
