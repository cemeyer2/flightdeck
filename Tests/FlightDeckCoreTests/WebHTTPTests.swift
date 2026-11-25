// Web dashboard, part 3: the request head, the checks every request passes, the headers on every reply, and the
// connection limits. Uses WebAccessTests' interfaces (en0 192.168.1.23, utun4 100.101.102.103, "MacBook-Pro").
import XCTest
@testable import FlightDeckCore

final class WebHTTPTests: XCTestCase {
    let ctx = WebAccessTests.context()

    func head(_ method: String = "GET", _ path: String = "/", _ headers: [String: String] = [:]) -> WebRequestHead {
        WebRequestHead(method: method, path: path, headers: headers)
    }
    func gate(_ h: WebRequestHead, _ a: WebAdmission = .admit, _ c: WebNetworkContext? = nil) -> Result<WebRoute, WebRefusal> {
        WebHTTP.gate(h, admission: a, context: c ?? ctx)
    }
    func status(_ r: Result<WebRoute, WebRefusal>) -> Int? {
        if case .failure(let f) = r { return f.status }
        return nil
    }

    func testHeadParse() {
        let full = Data("GET /api/state?x=1 HTTP/1.1\r\nHost: 192.168.1.23:9466\r\nAccept: */*\r\nX-Thing: a: b\r\n\r\n".utf8)
        XCTAssertEqual(WebHTTP.parseHead(full),
                       .head(WebRequestHead(method: "GET", path: "/api/state",
                                            headers: ["host": "192.168.1.23:9466", "accept": "*/*", "x-thing": "a: b"])))
        XCTAssertEqual(WebHTTP.parseHead(full.prefix(30)), .incomplete)
        let big = Data(("GET / HTTP/1.1\r\n" + String(repeating: "X-Pad: \(String(repeating: "a", count: 100))\r\n", count: 90)).utf8)
        XCTAssertGreaterThan(big.count, 9000)
        XCTAssertEqual(WebHTTP.parseHead(big), .bad(431))
        XCTAssertEqual(WebHTTP.parseHead(Data("GARBAGE\r\n\r\n".utf8)), .bad(400))
        XCTAssertEqual(WebHTTP.parseHead(Data("GET / HTTP/1.1\r\nno colon here\r\n\r\n".utf8)), .bad(400))
        XCTAssertEqual(WebHTTP.parseHead(Data("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n".utf8)), .bad(400), "two Hosts are ambiguous")
    }

    func testHostCheck() {
        for h in ["192.168.1.23", "100.101.102.103", "localhost", "127.0.0.1", "[::1]", "MacBook-Pro.local"] {
            XCTAssertTrue(WebHTTP.acceptsHost(h, context: ctx), h)
        }
        for h in ["203.0.113.9", "other.local", "evil.example", "macbook-pro.tail1234.ts.net", "macbook-pro"] {
            XCTAssertFalse(WebHTTP.acceptsHost(h, context: ctx), h)
        }
        XCTAssertFalse(WebHTTP.acceptsHost(nil, context: ctx))
        XCTAssertFalse(WebHTTP.acceptsHost("203.0.113.9", context: WebAccessTests.context(advanced: true)))
    }

    /// Review focus: what real browsers put in Host.
    func testHostVariants() {
        for h in ["MACBOOK-PRO.LOCAL:9466", "macbook-pro.local.", "192.168.1.23:9466", "[2001:db8:1:2::23]:9466"] {
            XCTAssertTrue(WebHTTP.acceptsHost(h, context: ctx), h)
        }
        XCTAssertFalse(WebHTTP.acceptsHost("macbook-pro.local.evil.example", context: ctx))
        XCTAssertFalse(WebHTTP.acceptsHost("[2001:db8:1:2::99]:9466", context: ctx))
    }

    func testLoopbackNeedsLoopbackHost() {
        XCTAssertEqual(gate(head("GET", "/", ["host": "127.0.0.1"]), .admitIfLoopbackHost), .success(.page))
        XCTAssertEqual(gate(head("GET", "/", ["host": "localhost:9466"]), .admitIfLoopbackHost), .success(.page))
        XCTAssertEqual(status(gate(head("GET", "/", ["host": "192.168.1.23"]), .admitIfLoopbackHost)), 403)
        XCTAssertEqual(gate(head("GET", "/", ["host": "192.168.1.23"]), .admit), .success(.page))
    }

    func testSpoofedForwardHeadersIgnored() throws {
        let spoofed = head("GET", "/", ["host": "127.0.0.1", "x-forwarded-for": "127.0.0.1", "forwarded": "for=127.0.0.1", "x-real-ip": "127.0.0.1"])
        XCTAssertEqual(WebAccess.admit(remote: WebIP("203.0.113.9")!, arrivalAddress: WebAccessTests.en0, context: ctx, allowlist: .parse("")), .drop)
        // Even if such a request reached the gate as loopback, the headers change nothing.
        XCTAssertEqual(gate(spoofed, .admitIfLoopbackHost), gate(head("GET", "/", ["host": "127.0.0.1"]), .admitIfLoopbackHost))
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FlightDeckCore/WebHTTP.swift")
        let text = try String(contentsOf: src, encoding: .utf8).lowercased()
        XCTAssertFalse(text.contains("x-forwarded-for"))
        XCTAssertFalse(text.contains("x-real-ip"))
    }

    func testCrossSite() {
        XCTAssertEqual(status(gate(head("GET", "/", ["host": "192.168.1.23", "sec-fetch-site": "cross-site"]))), 403)
        XCTAssertEqual(status(gate(head("GET", "/", ["host": "192.168.1.23", "origin": "http://evil.example"]))), 403)
        XCTAssertEqual(gate(head("GET", "/api/state", ["host": "192.168.1.23:9466", "origin": "http://192.168.1.23:9466"])), .success(.state))
        XCTAssertEqual(status(gate(head("GET", "/", ["host": "192.168.1.23", "origin": "null"]))), 403)
    }

    func testMethodBodyRouteAccept() {
        let h = ["host": "192.168.1.23"]
        let r = gate(head("HEAD", "/", h))
        XCTAssertEqual(status(r), 405)
        if case .failure(let f) = r { XCTAssertTrue(f.extra.contains { $0.0 == "Allow" && $0.1 == "GET" }) }
        XCTAssertEqual(status(gate(head("POST", "/", h))), 405)
        XCTAssertEqual(status(gate(head("GET", "/", h.merging(["content-length": "5"]) { a, _ in a }))), 400)
        XCTAssertEqual(gate(head("GET", "/", h.merging(["content-length": "0"]) { a, _ in a })), .success(.page))
        XCTAssertEqual(status(gate(head("GET", "/", h.merging(["transfer-encoding": "chunked"]) { a, _ in a }))), 400)
        XCTAssertEqual(status(gate(head("GET", "/nope", h))), 404)
        XCTAssertEqual(gate(head("GET", "/favicon.svg", h)), .success(.favicon))
        XCTAssertEqual(status(gate(head("GET", "/api/stream", h))), 406)
        XCTAssertEqual(gate(head("GET", "/api/stream", h.merging(["accept": "text/event-stream"]) { a, _ in a })), .success(.stream))
    }

    func testResponseHeadHasNoCORS() {
        let s = String(decoding: WebHTTP.responseHead(status: 200, contentType: "text/html; charset=utf-8", contentLength: 5,
                                                       extra: [("Content-Security-Policy", "default-src 'none'")]), as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\n"))
        for want in ["nosniff", "no-referrer", "no-store", "Content-Length: 5", "Connection: close", "Content-Security-Policy: default-src 'none'"] {
            XCTAssertTrue(s.contains(want), want)
        }
        XCTAssertFalse(s.contains("Access-Control"))
    }

    func testSSEEventSingleLine() {
        XCTAssertEqual(String(decoding: WebHTTP.sseEvent("sample", Data(#"{"a":"x"}"#.utf8)), as: UTF8.self),
                       "event: sample\ndata: {\"a\":\"x\"}\n\n")
    }

    func testLimits() {
        var l = WebConnectionLimits()
        let a = WebIP("192.168.1.40")!
        XCTAssertEqual((0..<4).map { _ in l.acceptConnection(a) }, [true, true, true, false])
        l.closeConnection(a)
        XCTAssertTrue(l.acceptConnection(a), "closing frees a slot")

        var t = WebConnectionLimits()
        let many = (1...8).map { WebIP("192.168.1.\($0)")! }
        XCTAssertEqual(many.map { t.acceptConnection($0) }, [true, true, true, true, true, true, true, false])
        XCTAssertTrue(t.acceptConnection(.loopbackV4), "one slot is kept for this Mac")
        XCTAssertFalse(t.acceptConnection(.loopbackV6))

        var s = WebConnectionLimits()
        XCTAssertEqual((0..<3).map { _ in s.openStream(a) }, [true, true, false])
        for i in 1...4 { XCTAssertTrue(s.openStream(WebIP("10.0.0.\(i)")!)) }
        XCTAssertEqual(s.streamCount, 6)
        XCTAssertFalse(s.openStream(WebIP("10.0.0.9")!))
        s.closeStream(a)
        XCTAssertEqual(s.streamCount, 5)
        XCTAssertTrue(s.openStream(WebIP("10.0.0.9")!))
    }

    func testRefusalLogRateAndBound() {
        var log = WebRefusalLog()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000), a = WebIP("203.0.113.9")!
        XCTAssertEqual([log.shouldLog(a, now: t0), log.shouldLog(a, now: t0 + 30)], [true, false])
        XCTAssertTrue(log.shouldLog(a, now: t0 + 61))

        var small = WebRefusalLog(capacity: 2)
        let b = WebIP("203.0.113.10")!, c = WebIP("203.0.113.11")!
        XCTAssertTrue(small.shouldLog(a, now: t0))
        XCTAssertTrue(small.shouldLog(b, now: t0 + 1))
        XCTAssertTrue(small.shouldLog(c, now: t0 + 2))
        XCTAssertTrue(small.shouldLog(a, now: t0 + 3), "the oldest was evicted")
        XCTAssertFalse(small.shouldLog(c, now: t0 + 4))
    }
}
