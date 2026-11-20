// Events: the detector's diffs, the hub's listener-driven watcher (no work without listeners), `wait_for_event`
// (matches, kept events, timeouts, CPU settling) and triage ranking on fixtures. Protocol-level subscription tests are
// in MCPSubscriptionTests.swift.
import XCTest
@testable import FlightDeckCore

/// A feed whose state tests change between polls, counting how often it is read.
final class FakeFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var state = MCPWatchState()
    private(set) var reads = 0
    func set(_ f: (inout MCPWatchState) -> Void) { lock.withLock { f(&state) } }
    func read() -> MCPWatchState { lock.withLock { reads += 1; return state } }
    var readCount: Int { lock.withLock { reads } }
}

/// A value shared between tasks.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

final class MCPEventTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func incident(_ key: String, _ title: String, start: Date, end: Date? = nil, id: UUID = UUID()) -> Incident {
        Incident(id: id, key: key, severity: .caution, icon: "cpu", title: title, detail: nil, destination: nil, start: start, end: end)
    }

    func testDetectorBaselineThenDiffs() {
        var d = MCPEventDetector()
        var s = MCPWatchState()
        let id = UUID()
        s.incidents = [incident("cpu:old", "Old is using 300% CPU", start: t0)]
        s.thermalState = 0; s.batteryPercent = 50; s.charging = false
        XCTAssertEqual(d.update(s, now: t0), [], "the first reading is only the baseline")

        s.incidents.append(incident("cpu:com.apple.dt.Xcode", "Xcode (12 processes) is using 412% CPU", start: t0, id: id))
        s.findings = [Finding(id: "hang:42-1", severity: .warning, icon: "hourglass", title: "Mail is not responding", since: t0, pids: [42])]
        s.appOf = [42: "Mail"]
        s.reports = [DiagnosticReport(path: "/r/Safari.ips", kind: .crash, process: "Safari", time: t0, summary: "EXC_BAD_ACCESS")]
        s.thermalState = 2
        let e = d.update(s, now: t0)
        XCTAssertEqual(e.map(\.kind), [.incidentOpened, .finding, .report, .thermal])
        XCTAssertEqual(e[0].app, "Xcode", "the app is taken from the incident title")
        XCTAssertEqual(e[1].app, "Mail"); XCTAssertEqual(e[1].pid, 42); XCTAssertEqual(e[1].nextTool, "get_process")
        XCTAssertEqual(e[2].uri, MCPResources.reports)
        XCTAssertEqual(e[3].severity, .warning)
        XCTAssertEqual(d.update(s, now: t0), [], "nothing new, nothing reported")

        s.incidents[1].end = t0.addingTimeInterval(90)
        s.findings[0].severity = .warning
        let closed = d.update(s, now: t0)
        XCTAssertEqual(closed.map(\.kind), [.incidentClosed])
        XCTAssertTrue(closed[0].detail?.hasPrefix("Lasted 90 s") == true)

        s.batteryPercent = 19
        XCTAssertEqual(d.update(s, now: t0).map(\.kind), [.batteryLow])
        s.batteryPercent = 15
        XCTAssertEqual(d.update(s, now: t0), [], "low battery is reported once per discharge")
        s.charging = true; _ = d.update(s, now: t0)
        s.charging = false
        XCTAssertEqual(d.update(s, now: t0).map(\.kind), [.batteryLow], "again after charging")
    }

    func testEventJSONRoundTrip() throws {
        var e = MCPEvent(kind: .incidentOpened, severity: .warning, title: "X", detail: "d", app: "Xcode", pid: 7, since: t0, key: "cpu:x")
        e.seq = 3
        XCTAssertEqual(MCPEvent(json: e.json), e)
        let n = MCPResources.updated(e, uri: MCPResources.incidents, subscription: "s1")
        XCTAssertEqual(MCPResources.event(in: n), e)
        XCTAssertEqual(n["params"]?["_meta"]?["io.modelcontextprotocol/subscriptionId"]?.string, "s1")
        let c = MCPResources.channel(e)
        XCTAssertEqual(c["method"]?.string, "notifications/claude/channel")
        XCTAssertEqual(c["params"]?["meta"]?["app"]?.string, "Xcode")
        XCTAssertEqual(c["params"]?["meta"]?["pid"]?.string, "7", "channel meta values are strings")
        XCTAssertTrue(c["params"]?["content"]?.string?.contains("recent_incidents") == true)
    }

    /// A hub over `feed` that polls every 10 ms.
    func hub(_ feed: FakeFeed) -> MCPEventHub {
        MCPEventHub(interval: 0.01, sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) { feed.read() }
    }

    func testHubWatchesOnlyWhileSomeoneListens() async throws {
        let feed = FakeFeed()
        let h = hub(feed)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(h.isWatching); XCTAssertEqual(feed.readCount, 0, "no listener, no reads")
        let task = Task { () -> MCPEvent? in for await e in h.listen() { return e }; return nil }
        while feed.readCount < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(h.isWatching)
        feed.set { $0.thermalState = 0 }
        while feed.readCount < 4 { try await Task.sleep(nanoseconds: 5_000_000) }
        feed.set { $0.thermalState = 3 }
        let e = await task.value
        XCTAssertEqual(e?.kind, .thermal); XCTAssertEqual(e?.seq, 1)
        while h.isWatching { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(h.listenerCount, 0)
        let reads = feed.readCount
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(feed.readCount, reads, "the watcher stopped with the last listener")
    }

    func testWaitMatchesKeptEventsAndTimesOut() async {
        let asked = Locked<[TimeInterval]>([])
        let h = MCPEventHub(interval: 1000, sleep: { d in
            asked.update { $0.append(d) }
            if d < 1000 { try await Task.sleep(nanoseconds: 20_000_000) } else { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }) { nil }
        let e = h.publish(MCPEvent(kind: .report, severity: .caution, title: "Crash: Safari", app: "Safari", since: t0, key: "a"))
        let kept = await h.wait(timeout: 600, afterSeq: 0) { $0.app == "Safari" }
        XCTAssertEqual(kept?.seq, e.seq, "an event newer than after_seq is returned at once")
        let none = await h.wait(timeout: 600, afterSeq: e.seq) { _ in true }
        XCTAssertNil(none, "the injected sleep ends the 600 s timeout at once")
        XCTAssertTrue(asked.value.contains(600))
        XCTAssertEqual(h.listenerCount, 0, "a finished wait stops listening")
    }

    func tools(_ src: FakeSource) -> MCPTools {
        var t = MCPTools(source: src)
        t.now = { [t0] in t0 }
        t.sleeper = { _ in }
        t.bootReader = { [] }
        return t
    }

    func call(_ t: MCPTools, _ name: String, _ args: JSON) async throws -> JSON {
        let r = await t.call(name, arguments: args)
        XCTAssertFalse(r.isError, r.text)
        return try JSON.parse(Data(r.text.utf8))
    }

    func testWaitForEventTool() async throws {
        let t = tools(FakeSource())
        let hub = try XCTUnwrap(t.events)
        let pending = Task { await t.call("wait_for_event", arguments: ["app": "xcode", "kinds": ["incident_opened"], "timeout_seconds": 30]) }
        while hub.listenerCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        hub.publish(MCPEvent(kind: .incidentOpened, severity: .caution, title: "Safari is using 200% CPU", app: "Safari", since: t0, key: "s"))
        hub.publish(MCPEvent(kind: .incidentOpened, severity: .caution, title: "Xcode is using 400% CPU", app: "Xcode", since: t0, key: "x"))
        let j = try JSON.parse(Data(await pending.value.text.utf8))
        XCTAssertEqual(j["matched"]?.bool, true)
        XCTAssertEqual(j["event"]?["app"]?.string, "Xcode", "the Safari event didn't match the filter")
        XCTAssertEqual(j["last_seq"]?.int, 2)
        let bad = await t.call("wait_for_event", arguments: ["kinds": ["nope"]])
        XCTAssertTrue(bad.isError)
    }

    func testWaitForCPUToSettle() async throws {
        let src = FakeSource()
        var s = BlackBoxTests.base; s.cpu.total = .value(95); src.snap = s
        let t = tools(src)
        var j = try await call(t, "wait_for_event", ["until_cpu_below": 20, "settle_seconds": 4, "timeout_seconds": 10])
        XCTAssertEqual(j["matched"]?.bool, false, "CPU stayed high for the whole (fake-clock) timeout")
        s.cpu.total = .value(8); src.snap = s
        j = try await call(t, "wait_for_event", ["until_cpu_below": 20, "settle_seconds": 4, "timeout_seconds": 10])
        XCTAssertEqual(j["matched"]?.bool, true)
        XCTAssertEqual(j["cpu_percent"]?.double, 8)
    }
}
