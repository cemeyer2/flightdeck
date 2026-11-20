// Subscriptions at the protocol level: capabilities, resources/list and read, legacy resources/subscribe with
// delivery to the session and unsubscribe (which stops the watcher), 2026-07-28 subscriptions/listen with its
// acknowledgment, subscription ids and cancellation, channel mode, both HTTP streams, and triage ranking.
import XCTest
@testable import FlightDeckCore

final class MCPSubscriptionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func server() -> (MCPServer, MCPEventHub) {
        let tools = MCPTools(source: FakeSource())
        return (MCPServer(version: "t", instructions: "", tools: tools), tools.events!)
    }
    func event(_ kind: MCPEvent.Kind = .incidentOpened) -> MCPEvent {
        MCPEvent(kind: kind, severity: .warning, title: "Xcode is using 400% CPU", app: "Xcode", since: t0, key: "cpu:x")
    }
    func send(_ s: MCPServer, _ text: String, session: MCPSession? = nil, notify: (@Sendable (JSON) -> Void)? = nil) async -> JSON? {
        await s.handle(Data(text.utf8), session: session, notify: notify).body
    }
    func until(_ cond: @escaping () -> Bool) async throws {
        for _ in 0..<1000 {
            if cond() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let met = cond()
        XCTAssertTrue(met, "timed out")
    }

    func testCapabilitiesAndResources() async throws {
        let (s, _) = server()
        let ini = await send(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        XCTAssertEqual(ini?["result"]?["capabilities"]?["resources"]?["subscribe"]?.bool, true)
        XCTAssertNil(ini?["result"]?["capabilities"]?["experimental"], "no channel capability outside channel mode")
        let echo = MCPServer(version: "t", instructions: "", tools: EchoTools())
        let plain = await send(echo, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        XCTAssertNil(plain?["result"]?["capabilities"]?["resources"], "tools without resources declare none")
        let list = await send(s, #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
        XCTAssertEqual(Set(list?["result"]?["resources"]?.array?.compactMap { $0["uri"]?.string } ?? []), Set(MCPResources.all.map(\.uri)))
        let read = await send(s, #"{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"flightdeck://incidents"}}"#)
        let text = try XCTUnwrap(read?["result"]?["contents"]?.array?.first?["text"]?.string)
        XCTAssertNotNil(try JSON.parse(Data(text.utf8))["incidents"], "reads as recent_incidents")
        let bad = await send(s, #"{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"flightdeck://nope"}}"#)
        XCTAssertEqual(bad?["error"]?["code"]?.int, -32002)
        let channel = await send(s, #"{"jsonrpc":"2.0","id":5,"method":"initialize","params":{}}"#, session: MCPSession(channel: true))
        XCTAssertNotNil(channel?["result"]?["capabilities"]?["experimental"]?["claude/channel"])
    }

    func testLegacySubscribeDeliversAndUnsubscribeStops() async throws {
        let (s, hub) = server()
        let none = await send(s, #"{"jsonrpc":"2.0","id":1,"method":"resources/subscribe","params":{"uri":"flightdeck://incidents"}}"#)
        XCTAssertEqual(none?["error"]?["code"]?.int, -32600, "no session, no subscription")
        let got = Locked<[JSON]>([])
        let session = MCPSession()
        session.attach { j in got.update { $0.append(j) } }
        let ok = await send(s, #"{"jsonrpc":"2.0","id":2,"method":"resources/subscribe","params":{"uri":"flightdeck://incidents"}}"#, session: session)
        XCTAssertNotNil(ok?["result"])
        XCTAssertEqual(hub.listenerCount, 1)
        hub.publish(event(.report))   // another resource: not delivered
        hub.publish(event())
        try await until { got.value.count == 1 }
        XCTAssertEqual(got.value[0]["method"]?.string, "notifications/resources/updated")
        XCTAssertEqual(got.value[0]["params"]?["uri"]?.string, MCPResources.incidents)
        XCTAssertEqual(MCPResources.event(in: got.value[0])?.app, "Xcode")
        _ = await send(s, #"{"jsonrpc":"2.0","id":3,"method":"resources/unsubscribe","params":{"uri":"flightdeck://incidents"}}"#, session: session)
        try await until { hub.listenerCount == 0 && !hub.isWatching }
    }

    func testModernListenAcknowledgesTagsAndCancels() async throws {
        let (s, hub) = server()
        let got = Locked<[JSON]>([])
        let listen = Task {
            await s.handle(Data(#"{"jsonrpc":"2.0","id":"sub","method":"subscriptions/listen","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"},"notifications":{"resourceSubscriptions":["flightdeck://events","file:///x"],"toolsListChanged":true}}}"#.utf8),
                           notify: { j in got.update { $0.append(j) } }).body
        }
        try await until { hub.listenerCount == 1 }
        let ack = got.value[0]
        XCTAssertEqual(ack["method"]?.string, "notifications/subscriptions/acknowledged")
        XCTAssertEqual(ack["params"]?["notifications"]?["resourceSubscriptions"], ["flightdeck://events"], "only what is supported is acknowledged")
        XCTAssertNil(ack["params"]?["notifications"]?["toolsListChanged"])
        hub.publish(event(.thermal))
        try await until { got.value.count == 2 }
        XCTAssertEqual(got.value[1]["params"]?["_meta"]?["io.modelcontextprotocol/subscriptionId"]?.string, "sub")
        XCTAssertEqual(got.value[1]["params"]?["uri"]?.string, MCPResources.events)
        listen.cancel()
        let reply = await listen.value
        XCTAssertNil(reply, "a cancelled request gets no response")
        try await until { hub.listenerCount == 0 }
    }

    /// An HTTP client that subscribed and never opened (or closed) its stream stops costing anything after the grace.
    func testSessionWithoutStreamStopsListeningAfterGrace() async throws {
        let (_, hub) = server()
        let session = MCPSession(streamGrace: 0.02)
        session.subscribe(MCPResources.events, hub: hub)
        XCTAssertTrue(session.isListening)
        try await until { !session.isListening && hub.listenerCount == 0 }
        let got = Locked<[JSON]>([])
        session.attach { j in got.update { $0.append(j) } }
        XCTAssertTrue(session.isListening, "opening the stream resumes")
        hub.publish(event())
        try await until { got.value.count == 1 }
        session.attach(nil)
        try await until { !session.isListening }
    }

    func testChannelSessionPushesEveryEvent() async throws {
        let (_, hub) = server()
        let got = Locked<[JSON]>([])
        let session = MCPSession(channel: true)
        session.attach { j in got.update { $0.append(j) } }
        session.startChannel(hub: hub)
        hub.publish(event(.batteryLow))
        try await until { got.value.count == 1 }
        XCTAssertEqual(got.value[0]["method"]?.string, "notifications/claude/channel")
        session.close()
        try await until { hub.listenerCount == 0 }
    }

    func testHTTPSessionStreamAndListenStream() async throws {
        let tools = MCPTools(source: FakeSource())
        let mcp = MCPServer(version: "t", instructions: "", tools: tools)
        let http = MCPHTTPServer(port: 0, token: "tok", server: mcp)
        let err = await withCheckedContinuation { c in http.start { c.resume(returning: $0) } }
        if let err { throw XCTSkip("can't listen on localhost here: \(err)") }
        defer { http.stop() }
        let url = URL(string: "http://127.0.0.1:\(http.port!)/mcp")!
        func request(_ method: String, _ body: String?, _ headers: [String: String] = [:]) -> URLRequest {
            var r = URLRequest(url: url); r.httpMethod = method; r.httpBody = body.map { Data($0.utf8) }
            r.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
            r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            return r
        }
        let (_, ir) = try await URLSession.shared.data(for: request("POST", #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#))
        let sid = try XCTUnwrap((ir as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let (_, sr) = try await URLSession.shared.data(for: request("POST", #"{"jsonrpc":"2.0","id":2,"method":"resources/subscribe","params":{"uri":"flightdeck://findings"}}"#, ["Mcp-Session-Id": sid]))
        XCTAssertEqual((sr as? HTTPURLResponse)?.statusCode, 200)
        let hub = tools.events!
        hub.publish(MCPEvent(kind: .finding, severity: .caution, title: "Buffered", since: t0, key: "f1"))   // before the stream opens
        let (bytes, gr) = try await URLSession.shared.bytes(for: request("GET", nil, ["Mcp-Session-Id": sid]))
        XCTAssertEqual((gr as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        var lines = bytes.lines.makeAsyncIterator()
        var first = try await lines.next()
        while let l = first, !l.hasPrefix("data:") { first = try await lines.next() }
        XCTAssertTrue(first?.contains("Buffered") == true, "notifications wait for the stream to open: \(first ?? "nil")")

        // The modern stream, as the stdio proxy uses it.
        let ep = MCPStdio.AppEndpoint(url: url, token: "tok")
        let opened = await MCPStdio.appEvents(ep)
        let stream = try XCTUnwrap(opened)
        try await until { hub.listenerCount == 2 }
        hub.publish(MCPEvent(kind: .report, severity: .caution, title: "Crash: Safari", app: "Safari", since: t0, key: "r1"))
        var it = stream.makeAsyncIterator()
        let relayed = await it.next()
        XCTAssertEqual(relayed?.app, "Safari")
        let (_, dr) = try await URLSession.shared.data(for: request("DELETE", nil, ["Mcp-Session-Id": sid]))
        XCTAssertEqual((dr as? HTTPURLResponse)?.statusCode, 200)
        let (_, gone) = try await URLSession.shared.data(for: request("POST", #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, ["Mcp-Session-Id": sid]))
        XCTAssertEqual((gone as? HTTPURLResponse)?.statusCode, 404, "an ended session is gone")
    }
}
