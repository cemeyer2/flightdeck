// Web dashboard, part 7: the server over real loopback sockets. Clients are plain BSD sockets so a test can send
// nothing, read nothing or read slowly, which a URL session can't. The context gives en0 a documentation address
// (192.0.2.10) so a Host naming it passes the interface-address check.
import XCTest
import Darwin
@testable import FlightDeckCore

/// A blocking TCP client on 127.0.0.1 with its own receive buffer.
final class RawClient: @unchecked Sendable {
    let fd: Int32
    private(set) var buffer = Data()
    private(set) var eof = false

    init?(port: UInt16, receiveBuffer: Int32? = nil) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if var rb = receiveBuffer { setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rb, socklen_t(MemoryLayout<Int32>.size)) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r != 0 { Darwin.close(fd); return nil }
    }
    deinit { Darwin.close(fd) }

    func send(_ s: String) { _ = s.withCString { Darwin.send(fd, $0, strlen($0), 0) } }

    /// Reads whatever arrives until `until` holds, EOF, or the timeout.
    @discardableResult
    func read(timeout: TimeInterval, until: (Data) -> Bool = { _ in false }) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 16384)
        while !eof, !until(buffer) {
            let left = end.timeIntervalSinceNow
            guard left > 0 else { return false }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(min(left, 0.2) * 1000)) > 0 else { continue }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { eof = true } else { buffer.append(contentsOf: chunk[0..<n]) }
        }
        return until(buffer) || eof
    }
    var text: String { String(decoding: buffer, as: UTF8.self) }
    func waitEOF(_ timeout: TimeInterval) -> Bool { read(timeout: timeout); return eof }
    /// The SSE event names received so far.
    var events: [String] { text.components(separatedBy: "\n").filter { $0.hasPrefix("event: ") }.map { String($0.dropFirst(7)) } }
}

final class WebDashboardServerTests: XCTestCase {
    static let fake = WebIP("192.0.2.10")!
    static func context(withFake: Bool = true) -> WebNetworkContext {
        WebNetworkContext(interfaces: [
            WebAccessTests.iface("lo0", "lo0", .loopback, ["127.0.0.1/8", "::1/128"]),
            WebAccessTests.iface("en0", "Wi-Fi", .lan, withFake ? ["192.0.2.10/24"] : ["192.0.2.11/24"]),
        ], localHostName: "Test-Mac", tailscaleProcessRunning: false, advanced: false)
    }
    static let doc = Data(#"{"v":1,"x":"doc"}"#.utf8)

    /// Records the latest stream count reported.
    final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ n: Int) { lock.lock(); values.append(n); lock.unlock() }
        var last: Int? { lock.lock(); defer { lock.unlock() }; return values.last }
    }

    func start(allow: String = "", headDeadline: TimeInterval = 10, maxBacklog: Int = 256 << 10, counts: Counts? = nil,
               provider: WebDashboardServer.Provider? = nil) throws -> WebDashboardServer {
        let p: WebDashboardServer.Provider = provider ?? { withHistory, reply in
            reply(withHistory ? Data(#"{"history":[],"v":1}"#.utf8) : Data(#"{"v":1}"#.utf8))
        }
        let s = WebDashboardServer(port: 0, loopbackOnly: true, context: Self.context(), allowlist: .parse(allow),
                                   headDeadline: headDeadline, maxBacklog: maxBacklog, provider: p,
                                   onStreamCount: { counts?.add($0) })
        let ready = expectation(description: "ready")
        let err = Box<String?>(nil)
        s.start { e in err.value = e; ready.fulfill() }
        wait(for: [ready], timeout: 5)
        if let e = err.value { throw XCTSkip("can't listen on localhost here: \(e)") }
        addTeardownBlock { s.stop() }
        return s
    }

    func request(_ path: String, host: String = "127.0.0.1", method: String = "GET", extra: String = "") -> String {
        "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n\(extra)\r\n"
    }

    /// Sends a request and reads until EOF or 2 s.
    func raw(_ port: UInt16, _ req: String) -> String {
        guard let c = RawClient(port: port) else { return "" }
        c.send(req)
        c.read(timeout: 2)
        return c.text
    }

    func stream(_ port: UInt16, host: String = "127.0.0.1") -> RawClient? {
        let c = RawClient(port: port)
        c?.send(request("/api/stream", host: host, extra: "Accept: text/event-stream\r\n"))
        return c
    }

    func eventually(_ timeout: TimeInterval = 2, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; usleep(20_000) }
        return cond()
    }

    func testRoutes() throws {
        let s = try start(), port = try XCTUnwrap(s.port)
        let page = raw(port, request("/"))
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200 OK\r\n"), page)
        XCTAssertTrue(page.contains("Content-Type: text/html; charset=utf-8"))
        XCTAssertTrue(page.contains("Content-Security-Policy: \(WebDashboardPage.csp)\r\n"))
        XCTAssertFalse(page.contains("Access-Control"))
        XCTAssertTrue(page.contains("<script>"))
        let state = raw(port, request("/api/state"))
        XCTAssertTrue(state.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(state.contains("application/json"))
        XCTAssertTrue(state.hasSuffix(#""v":1}"#), state)
        XCTAssertTrue(raw(port, request("/favicon.svg")).hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(raw(port, request("/x")).hasPrefix("HTTP/1.1 404"))
        let head = raw(port, request("/", method: "HEAD"))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 405"))
        XCTAssertTrue(head.contains("Allow: GET\r\n"))
        XCTAssertTrue(raw(port, request("/", method: "POST")).hasPrefix("HTTP/1.1 405"))
        XCTAssertTrue(raw(port, request("/", extra: "Content-Length: 3\r\n")).hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(raw(port, request("/api/stream")).hasPrefix("HTTP/1.1 406"))
    }

    func testLoopbackHostRules() throws {
        let s = try start(allow: "10.0.0.0/8"), port = try XCTUnwrap(s.port)
        XCTAssertTrue(raw(port, request("/", host: "localhost")).hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(raw(port, request("/", host: "192.0.2.10")).hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(raw(port, request("/", host: "evil.example")).hasPrefix("HTTP/1.1 403"))
    }

    func testStreamSnapshotThenSample() throws {
        let s = try start(), port = try XCTUnwrap(s.port)
        let c = try XCTUnwrap(stream(port))
        XCTAssertTrue(c.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: snapshot") })
        XCTAssertTrue(c.text.contains("Content-Type: text/event-stream"))
        let body = try XCTUnwrap(c.text.components(separatedBy: "\r\n\r\n").dropFirst().first)
        XCTAssertTrue(body.hasPrefix("retry: 3000\n\nevent: snapshot\ndata: "), body)
        XCTAssertTrue(body.contains(#""history""#))
        s.publish(Self.doc)
        XCTAssertTrue(c.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: sample") })
        XCTAssertEqual(c.events, ["snapshot", "sample"])
        XCTAssertTrue(c.text.contains("data: {\"v\":1,\"x\":\"doc\"}\n\n"))
        XCTAssertFalse(c.text.contains("\nid:"))
    }

    func testStreamCountAndStop() throws {
        let counts = Counts()
        let s = try start(counts: counts), port = try XCTUnwrap(s.port)
        let a = try XCTUnwrap(stream(port)), b = try XCTUnwrap(stream(port))
        XCTAssertTrue(a.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: snapshot") })
        XCTAssertTrue(b.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: snapshot") })
        XCTAssertEqual(counts.last, 2)
        s.stop()
        XCTAssertTrue(a.waitEOF(1))
        XCTAssertTrue(b.waitEOF(1))
        XCTAssertTrue(eventually { counts.last == 0 })
    }

    func testStreamLimits() throws {
        let s = try start(), port = try XCTUnwrap(s.port)
        let a = try XCTUnwrap(stream(port)), b = try XCTUnwrap(stream(port))
        XCTAssertTrue(a.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: snapshot") })
        XCTAssertTrue(b.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: snapshot") })
        let third = raw(port, request("/api/stream", extra: "Accept: text/event-stream\r\n"))
        XCTAssertTrue(third.hasPrefix("HTTP/1.1 429"), third)
        XCTAssertTrue(third.contains("Retry-After: 10\r\n"))
    }

    func testRevocationOnAllowlistEdit() throws {
        let counts = Counts()
        let s = try start(allow: "127.0.0.1", counts: counts), port = try XCTUnwrap(s.port)
        let viaAddress = try XCTUnwrap(stream(port, host: "192.0.2.10"))
        let viaLocalhost = try XCTUnwrap(stream(port, host: "localhost"))
        XCTAssertTrue(viaAddress.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: snapshot") })
        XCTAssertTrue(viaLocalhost.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: snapshot") })
        s.update(context: Self.context(), allowlist: .parse("10.0.0.0/8"))
        XCTAssertTrue(viaAddress.waitEOF(1))
        XCTAssertFalse(viaLocalhost.waitEOF(0.5), "a loopback Host still passes")
        XCTAssertTrue(eventually { counts.last == 1 })
    }

    /// Review focus: a client that connects and sends nothing loses its slot at the head deadline.
    func testSilentClientIsDroppedAtDeadline() throws {
        let s = try start(headDeadline: 0.5), port = try XCTUnwrap(s.port)
        let silent = (0..<3).compactMap { _ in RawClient(port: port) }
        XCTAssertEqual(silent.count, 3)
        usleep(100_000)
        let fourth = try XCTUnwrap(RawClient(port: port))
        XCTAssertTrue(fourth.waitEOF(0.4), "over the per-address cap: dropped before the deadline")
        for c in silent { XCTAssertTrue(c.waitEOF(1.5)) }
        XCTAssertTrue(raw(port, request("/")).hasPrefix("HTTP/1.1 200"))
    }

    func testSampleNeverPrecedesSnapshot() throws {
        let s = try start(provider: { withHistory, reply in
            if withHistory { DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { reply(Data(#"{"history":[],"v":1}"#.utf8)) } }
            else { reply(Data(#"{"v":1}"#.utf8)) }
        })
        let port = try XCTUnwrap(s.port)
        let c = try XCTUnwrap(stream(port))
        XCTAssertTrue(c.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("retry: 3000") })
        s.publish(Self.doc)
        usleep(500_000)
        s.publish(Self.doc)
        XCTAssertTrue(c.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: sample") })
        XCTAssertEqual(c.events.first, "snapshot")
        XCTAssertEqual(c.events, ["snapshot", "sample"], "the publish during the wait went to no one")
    }

    func testNilSnapshotClosesStream() throws {
        let counts = Counts()
        let s = try start(counts: counts, provider: { _, reply in reply(nil) })
        let port = try XCTUnwrap(s.port)
        let c = try XCTUnwrap(stream(port))
        XCTAssertTrue(c.waitEOF(2))
        XCTAssertFalse(c.text.contains("event:"))
        XCTAssertTrue(eventually { counts.last == 0 })
        XCTAssertTrue(raw(port, request("/api/state")).hasPrefix("HTTP/1.1 503"))
    }

    func testSlowReaderDisconnected() throws {
        let counts = Counts()
        let s = try start(maxBacklog: 4096, counts: counts), port = try XCTUnwrap(s.port)
        let stuck = try XCTUnwrap(RawClient(port: port, receiveBuffer: 4096))
        stuck.send(request("/api/stream", extra: "Accept: text/event-stream\r\n"))
        let reader = try XCTUnwrap(stream(port))
        XCTAssertTrue(reader.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: snapshot") })
        XCTAssertTrue(eventually { counts.last == 2 })
        let stop = Box(false)
        let done = expectation(description: "reader")
        DispatchQueue.global().async {
            while !stop.value && !reader.eof { reader.read(timeout: 0.05) }
            done.fulfill()
        }
        let big = Data(("{\"v\":1,\"pad\":\"" + String(repeating: "x", count: 8 << 10) + "\"}").utf8)
        for _ in 0..<200 { s.publish(big); usleep(20_000) }
        XCTAssertTrue(eventually(3) { counts.last == 1 }, "the stream that stopped reading is closed")
        stop.value = true
        wait(for: [done], timeout: 2)
        XCTAssertFalse(reader.eof, "the reading stream stays open")
    }

    /// Review focus: a port that is taken reports the listener's error instead of "Serving…".
    func testPortInUseReportsError() throws {
        let a = try start(), port = try XCTUnwrap(a.port)
        let b = WebDashboardServer(port: port, context: Self.context(), allowlist: .parse(""), provider: { _, r in r(nil) })
        let ready = expectation(description: "b")
        let err = Box<String?>(nil)
        b.start { e in err.value = e; ready.fulfill() }
        wait(for: [ready], timeout: 5)
        b.stop()
        XCTAssertNotNil(err.value)
    }

    func testRestartOnSamePortAfterTraffic() throws {
        let a = try start(), port = try XCTUnwrap(a.port)
        // Replies close from the server side, which leaves its end of each connection in TIME_WAIT.
        for _ in 0..<3 { XCTAssertTrue(raw(port, request("/")).hasPrefix("HTTP/1.1 200")) }
        a.stop()
        usleep(50_000)
        let b = WebDashboardServer(port: port, loopbackOnly: true, context: Self.context(), allowlist: .parse(""), provider: { _, r in r(nil) })
        let ready = expectation(description: "b")
        let err = Box<String?>(nil)
        b.start { e in err.value = e; ready.fulfill() }
        wait(for: [ready], timeout: 5)
        b.stop()
        XCTAssertNil(err.value, "turning the dashboard off and on again keeps its port")
    }

    func testRevocationOnNetworkChange() throws {
        let s = try start(allow: "127.0.0.1"), port = try XCTUnwrap(s.port)
        let c = try XCTUnwrap(stream(port, host: "192.0.2.10"))
        XCTAssertTrue(c.read(timeout: 2) { String(decoding: $0, as: UTF8.self).contains("event: snapshot") })
        s.update(context: Self.context(withFake: false), allowlist: .parse("127.0.0.1"))
        XCTAssertTrue(c.waitEOF(1))
    }

    func testInvalidAllowlistRefusesStart() {
        let s = WebDashboardServer(port: 0, loopbackOnly: true, context: Self.context(), allowlist: .parse("banana"), provider: { _, r in r(nil) })
        let ready = expectation(description: "ready")
        let err = Box<String?>(nil)
        s.start { e in err.value = e; ready.fulfill() }
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(err.value, "Fix the allowed addresses first")
        XCTAssertNil(s.port)
    }
}
