// MCP transports: the HTTP gate (token, Origin and Host checks), HTTP request parsing (Content-Length and chunked
// bodies, size limits), an end-to-end exchange with the localhost server on a random port, and a stdio round trip
// through the built `FlightDeck --mcp` binary.
import XCTest
@testable import FlightDeckCore

final class MCPTransportTests: XCTestCase {
    let token = "secret-token"
    func headers(_ extra: [String: String] = [:]) -> [String: String] {
        ["host": "127.0.0.1:9465", "authorization": "Bearer secret-token"].merging(extra) { _, b in b }
    }

    func testGateRejectsWrongTokenOriginHostAndMethod() {
        XCTAssertNil(MCPHTTPGate.check(method: "POST", path: "/mcp", headers: headers(), token: token))
        XCTAssertNil(MCPHTTPGate.check(method: "POST", path: "/mcp", headers: headers(["origin": "http://localhost:6274"]), token: token),
                     "a local tool's page (e.g. the MCP inspector) may connect")
        XCTAssertEqual(MCPHTTPGate.check(method: "POST", path: "/mcp", headers: headers(["authorization": "Bearer nope"]), token: token)?.status, 401)
        XCTAssertEqual(MCPHTTPGate.check(method: "POST", path: "/mcp", headers: headers(["authorization": ""]), token: token)?.status, 401)
        XCTAssertEqual(MCPHTTPGate.check(method: "POST", path: "/mcp", headers: ["host": "localhost"], token: token)?.status, 401)
        XCTAssertEqual(MCPHTTPGate.check(method: "POST", path: "/mcp", headers: headers(["origin": "https://evil.example"]), token: token)?.status, 403)
        XCTAssertEqual(MCPHTTPGate.check(method: "POST", path: "/mcp", headers: headers(["origin": "null"]), token: token)?.status, 403)
        XCTAssertEqual(MCPHTTPGate.check(method: "POST", path: "/mcp", headers: headers(["origin": "http://127.0.0.1.evil.example"]), token: token)?.status, 403)
        XCTAssertEqual(MCPHTTPGate.check(method: "POST", path: "/mcp", headers: headers(["host": "rebind.example:9465"]), token: token)?.status, 403,
                       "DNS rebinding: a foreign name resolving to 127.0.0.1")
        XCTAssertEqual(MCPHTTPGate.check(method: "GET", path: "/mcp", headers: headers(), token: token)?.status, 405)
        XCTAssertEqual(MCPHTTPGate.check(method: "POST", path: "/other", headers: headers(), token: token)?.status, 404)
        XCTAssertEqual(MCPHTTPGate.check(method: "POST", path: "/mcp", headers: headers(), token: "")?.status, 503, "no token, no service")
        XCTAssertEqual(MCPHTTPGate.host(of: "[::1]:9465"), "[::1]")
        XCTAssertNotEqual(MCPHTTPGate.newToken(), MCPHTTPGate.newToken())
        XCTAssertEqual(MCPHTTPGate.newToken().count, 43)
    }

    func testRequestParsing() {
        let body = #"{"a":1}"#
        guard case .request(let m, let p, let h, let b) = MCPHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)) else { return XCTFail() }
        XCTAssertEqual(m, "POST"); XCTAssertEqual(p, "/mcp"); XCTAssertEqual(h["host"], "x"); XCTAssertEqual(String(decoding: b, as: UTF8.self), body)
        guard case .incomplete = MCPHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)) else { return XCTFail("waits for the body") }
        guard case .request(_, _, _, let cb) = MCPHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".utf8)) else { return XCTFail("chunked") }
        XCTAssertEqual(String(decoding: cb, as: UTF8.self), "abcde")
        guard case .bad(413, _) = MCPHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) else { return XCTFail("too large") }
        guard case .bad(431, _) = MCPHTTPServer.parse(Data(String(repeating: "x", count: MCPHTTPServer.maxHeader + 1).utf8)) else { return XCTFail("headers too large") }
    }

    /// POSTs `body` to the running server and returns (status, parsed body).
    func post(_ port: UInt16, _ body: String, headers: [String: String]) throws -> (Int, JSON?) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"; req.httpBody = Data(body.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let done = expectation(description: body)
        let result = Box<(Int, JSON?)>((0, nil))
        URLSession.shared.dataTask(with: req) { d, r, _ in
            result.value = ((r as? HTTPURLResponse)?.statusCode ?? 0, d.flatMap { try? JSON.parse($0) })
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result.value
    }

    func testEndToEndOverLocalhost() throws {
        let src = FakeSource(); src.snap = BlackBoxTests.base
        let mcp = MCPServer(version: "test", instructions: "", tools: MCPTools(source: src))
        let server = MCPHTTPServer(port: 0, token: token, server: mcp)
        let ready = expectation(description: "ready")
        let err = Box<String?>(nil)
        server.start { e in err.value = e; ready.fulfill() }
        wait(for: [ready], timeout: 5)
        if let e = err.value { throw XCTSkip("can't listen on localhost here: \(e)") }
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let auth = ["Authorization": "Bearer \(token)"]
        var (code, j) = try post(port, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#, headers: auth)
        XCTAssertEqual(code, 200); XCTAssertEqual(j?["result"]?["protocolVersion"]?.string, "2025-11-25")
        (code, j) = try post(port, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, headers: auth)
        XCTAssertEqual(code, 202)
        (code, j) = try post(port, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_processes","arguments":{"limit":3}}}"#, headers: auth)
        XCTAssertEqual(code, 200)
        let text = try XCTUnwrap(j?["result"]?["content"]?.array?.first?["text"]?.string)
        XCTAssertEqual(try JSON.parse(Data(text.utf8))["shown"]?.int, min(3, BlackBoxTests.base.processes.count))
        (code, _) = try post(port, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, headers: [:])
        XCTAssertEqual(code, 401, "no token")
        (code, _) = try post(port, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, headers: auth.merging(["Origin": "https://evil.example"]) { a, _ in a })
        XCTAssertEqual(code, 403, "web page origin")

        // The stdio proxy: forwards with the token, and treats a refused token as "app not usable" (nil).
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let ping = Data(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#.utf8)
        let proxied = expectation(description: "proxy")
        let out = Box<(Data??, Data??)>((nil, nil))
        Task { [token] in
            out.value = (await MCPStdio.forward(ping, to: .init(url: url, token: token)), await MCPStdio.forward(ping, to: .init(url: url, token: "wrong")))
            proxied.fulfill()
        }
        wait(for: [proxied], timeout: 10)
        let good = try XCTUnwrap(out.value.0 ?? nil)
        XCTAssertEqual(try JSON.parse(good)["id"]?.int, 9)
        XCTAssertTrue(out.value.1 == nil, "a wrong token falls back to standalone")
    }

    /// Runs the built binary as an MCP client would: messages on stdin, one reply per line on stdout, and nothing else
    /// on stdout. Standalone (the app is skipped) so the result doesn't depend on whether FlightDeck is running.
    func testStdioRoundTrip() throws {
        let bin = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("FlightDeck")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else { throw XCTSkip("FlightDeck binary not built at \(bin.path)") }
        let p = Process()
        p.executableURL = bin; p.arguments = ["--mcp"]
        p.environment = ProcessInfo.processInfo.environment.merging(["FLIGHTDECK_MCP_STANDALONE": "1"]) { _, b in b }
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run()
        let msgs = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#,
                    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                    #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                    #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_processes","arguments":{"limit":2}}}"#]
        input.fileHandleForWriting.write(Data((msgs.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "one line per request, none for the notification, nothing else on stdout")
        let replies = try lines.map { try JSON.parse(Data($0.utf8)) }
        XCTAssertEqual(replies.map { $0["id"]?.int }, [1, 2, 3])
        XCTAssertEqual(replies[1]["result"]?["tools"]?.array?.count, 23)
        let text = try XCTUnwrap(replies[2]["result"]?["content"]?.array?.first?["text"]?.string)
        XCTAssertEqual(try JSON.parse(Data(text.utf8))["source"]?.string, "standalone")
    }
}
